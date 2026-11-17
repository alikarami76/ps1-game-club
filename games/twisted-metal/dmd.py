"""Parse Twisted Metal DMD model files (scene graphs of PS1 GPU packet templates).

A DMD file is a memory image loaded at LOAD_BASE; every pointer inside it is
an absolute PS1 address. The header lists top-level objects. Each object is a
small scene graph: group, level-of-detail, translate, rotate+translate and
switch nodes, ending in mesh bodies. Mesh bodies hold pointers to a vertex
array, a normal array and a polygon list. Walking the graph and applying the
transforms on the way down gives every mesh in world space.

Node types (low byte of the node's first word; the high half is an object id):
  0x00 mesh body (word 0x????FF00)     0x04 translate
  0x01 group with bounding sphere      0x05 rotate + translate
  0x02 level-of-detail selector        0x09 switch (alternative versions)
  0x03 animation (one mesh per frame)  0x0B spatial split (inside / outside a region)
Words 0x????FF07 and 0x????FF08 are leaf boxes (likely collision) and are skipped.

The game's renderer (node dispatch at 0x800FDC80 in the executable) draws one child of a
switch (its current state, byte +7) and one frame of an animation (byte +0xC); objects()
returns that default state in Object.meshes and every other state in Object.switches /
Object.animations, so an engine can swap them later (damage, wheel frames).
Spatial splits draw one of two children depending on the camera; both are in Object.meshes
and Object.splits says which is which.
"""
import math
import struct
import sys

LOAD_BASE = 0x800188B8

# Top-level object ids (high half of the object's first word).
LEVEL_ID, SKY_ID, FLOOR_ID = 1, 2, 3
LEVEL_IDS = (LEVEL_ID, FLOOR_ID)  # the arena itself; FLOOR_ID only exists in the Arena level

# Polygon kind, from bits 16-18 of the polygon's lighting word.
KIND_SPRITE, KIND_TRIANGLE, KIND_QUAD = "sprite", "triangle", "quad"

IDENTITY = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))

# Screen clear colour per arena (manifest arena id), set by each level's start-up code in the
# executable (stored at 0x801B2B34 as three int32) and drawn as a full-screen fill before the
# models. Whatever no polygon covers shows this colour: the centres of SUBURB (a drivable lot)
# and XFWY (behind the trench walls) have no geometry at all and are this colour in the game.
# The PS1 shows it at 5 bits per channel, e.g. SUBURB (110, 110, 100) appears as (104, 104, 96).
BACKGROUND = {
    "XARENA": (40, 40, 40), "WH": (75, 70, 55), "XFWY": (60, 45, 20),
    "PARK": (75, 60, 30), "SUBURB": (110, 110, 100), "ROOF": (0, 20, 0),
}

# Switch tags (node id) the game registers as destructible targets (code at 0x80142690 and
# 0x80149700): hit points, and whether destruction switches to state 1 ("wreck") rather than
# hiding the node. Others not listed here have 1 hit point. See README "Switch and animation".
DESTRUCTIBLE = {
    0x258: (8, True), 0x259: (3, True), 0x262: (5, True), 0x263: (15, True), 0x264: (10, True),
    0x265: (20, True), 0x302: (1, True), 0x386: (25, True), 0x3E8: (100, True), 0x3E9: (1, True),
    0x3EA: (4, True), 0x3F1: (4, True), 0x3F2: (4, True), 0x3F9: (8, True),
}


class Polygon:
    """One polygon record. Fields:

    indices  vertex indices (3 or 4); for a sprite: (centre, half width, half height, corner)
    code     PS1 GPU command byte of the first colour word (0x20-0x3F)
    colors   (r, g, b) per colour word (1, 3 or 4 of them)
    uvs      (u, v) per vertex, or None when untextured
    clut     palette word, tpage texture page word (None when untextured)
    flags    byte 0 of the record: low 7 bits = number of UV words, bit 7 = has a 0xE2 word
    kind     KIND_TRIANGLE, KIND_QUAD or KIND_SPRITE
    light    the raw lighting word (see README)
    normals  indices into Mesh.normals: () = pre-lit, 1 = flat lit, 3/4 = one per vertex
    texwin   (mask_u, mask_v, offset_u, offset_v) in texels from the 0xE2 command, or None
    sprite_kind  for sprites: 0 = stays upright (turns about z only), 1 = faces the camera
    size     for sprites: (half width, half height) in world units
    corner   for sprites: world position of the reference corner (centre + right * w, z - h)
    """
    __slots__ = ("indices", "code", "colors", "uvs", "clut", "tpage", "flags", "kind",
                 "light", "normals", "texwin", "sprite_kind", "size", "corner")


class Mesh:
    """One placed mesh body. The context fields say which variant it belongs to:

    switch_node  offset of the innermost switch node above it (-1 = none); switch_id its tag
    state        which child (state) of that switch this mesh is in
    anim_node    offset of the innermost animation node above it (-1 = none)
    frame        which frame of that animation this mesh is
    tag, tag_node  the nearest tagged node above it (id != 0, below the object's root), e.g.
                 0x191-0x1AE a pickup, 0x264 a destructible van; 0 / -1 when none
    split_node   offset of the innermost spatial split above it (-1 = none)
    split_side   0 = drawn while the camera is outside the split's regions, 1 = inside
    """

    def __init__(self, offset):
        self.offset = offset
        self.id = 0
        self.center = (0, 0, 0)
        self.radius = 0
        self.vertices = []  # world space when the mesh came from load() or objects()
        self.normals = []   # unit normals (floats) in world space; [] when not in the file
        self.polygons = []  # triangles and quads; indices point into vertices
        self.sprites = []   # (world centre, polygon) billboards; see Polygon.size/corner
        self.switch_node, self.switch_id, self.state = -1, 0, 0
        self.anim_node, self.frame = -1, 0
        self.tag, self.tag_node = 0, -1
        self.split_node, self.split_side = -1, -1


class Switch:
    """A switch node (type 0x09): the game draws child `default` (byte +7) of `count`.

    id    the node's tag (high half of word 0), e.g. 0x264; vehicle body = vehicle id + 1
    slot  byte +4: the instance number the game uses to find it (1, 2, ...; 0 = single)
    states  one list of world-space Mesh per child; states[default] holds the same Mesh
            objects as Object.meshes. Nested switches inside a state are listed separately.
    parent  (index in Object.switches, state) of the switch this one sits in, or None
    """

    def __init__(self, offset, id_, slot, count, default, parent):
        self.offset, self.id, self.slot, self.count = offset, id_, slot, count
        self.default, self.parent = default, parent
        self.states = [[] for _ in range(count)]


class Animation:
    """An animation node (type 0x03): one child per frame, shown in turn.

    delay  u16 +6: a frame lasts delay + 1 renders (the game renders at 20 per second)
    first, last  bytes +8/+9: frame range; mode byte +0xA: 0 = loop, 1 = ping-pong
    default  byte +0xC: the frame shown first (0 in every file)
    frames   one list of world-space Mesh per frame; frames[default] are in Object.meshes
    """

    def __init__(self, offset, id_, delay, first, last, mode, count, default, parent):
        self.offset, self.id, self.delay, self.first, self.last = offset, id_, delay, first, last
        self.mode, self.count, self.default, self.parent = mode, count, default, parent
        self.frames = [[] for _ in range(count)]


class Split:
    """A spatial split node (type 0x0B): the game draws `inside` while the camera is in any
    region, else `outside` (code at 0x800FE608). Both are in Object.meshes.

    origin   world position of the node (no split in the files has a rotation above it)
    regions  (matrix, low, size): matrix = 9 int16 row by row (4096 = 1.0), low and size =
             3 int16 each; see contains()
    outside, inside  the meshes of child +0xC / child +0x10
    """

    def __init__(self, offset, origin, regions, parent):
        self.offset, self.origin, self.regions, self.parent = offset, origin, regions, parent
        self.outside, self.inside = [], []

    def contains(self, camera):
        """True when a world-space camera position is inside one of the regions (draw inside)."""
        c = [camera[k] - self.origin[k] for k in range(3)]
        for m, low, size in self.regions:
            p = [(m[3 * r] * c[0] + m[3 * r + 1] * c[1] + m[3 * r + 2] * c[2]) / 4096 for r in range(3)]
            if all(0 < low[k] + p[k] < size[k] for k in range(3)):
                return True
        return False


def split_regions(data, off):
    """The region blocks of the split node at `off`: [(matrix, low, size)].

    Block: 9 int16 matrix (+0, row by row; the game multiplies it with the camera offset),
    int32 x,y,z (+0x14, unused by the test), int16 x,y,z low (+0x20), int16 x,y,z size
    (+0x28). Inside means 0 < low + matrix * (camera - node) < size on every axis.
    """
    out = []
    for i in range(data[off + 0x0A]):
        rb = _ptr_at(data, off + 0x14 + 4 * i)
        if rb is None:
            continue
        out.append((struct.unpack_from("<9h", data, rb), struct.unpack_from("<3h", data, rb + 0x20),
                    struct.unpack_from("<3h", data, rb + 0x28)))
    return out


class Object:
    def __init__(self, offset, id_, center, radius):
        self.offset = offset
        self.id = id_
        self.center = center
        self.radius = radius
        self.meshes = []      # the default state, world space
        self.switches = []    # Switch, in the order found
        self.animations = []  # Animation, in the order found
        self.splits = []      # Split, in the order found


def _u32(data, off):
    return struct.unpack_from("<I", data, off)[0]


def _ptr(data, value):
    off = value - LOAD_BASE
    return off if 0 <= off < len(data) else None


def _ptr_at(data, off):
    return _ptr(data, _u32(data, off))


def _mat_mul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def _apply(m, t, v):
    return tuple(m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] + t[i] for i in range(3))


def texture_window(word):
    """Decode a GPU 0xE2 texture-window word to (mask_u, mask_v, offset_u, offset_v) in texels.

    The GPU samples u' = (u & ~mask_u) | (offset_u & mask_u), and the same for v.
    """
    return ((word & 31) * 8, ((word >> 5) & 31) * 8, ((word >> 10) & 31) * 8, ((word >> 15) & 31) * 8)


def parse_polygon(data, p):
    """Decode one polygon record at `p`; return (Polygon, size in bytes).

    Record: byte0 = UV word count (bit 7: a 0xE2 word follows the UVs), byte1 = colour
    word count, byte2 = record size in words, byte3 = GPU packet size. Then two words of
    u16 vertex indices, the lighting word, the colour words, the UV words, the optional
    0xE2 word and the u16 normal indices (count in bits 19-21 of the lighting word).
    """
    nv_flags, ncolors, nwords, _gpu_words = data[p], data[p + 1], data[p + 2], data[p + 3]
    if nwords == 0:
        return None, 0
    words = struct.unpack_from(f"<{nwords}I", data, p)
    light = words[3]
    pos = 4  # header + 2 index words + 1 lighting word
    colors = [words[pos + i] for i in range(ncolors)]
    code = colors[0] >> 24 if colors else 0
    nverts = 4 if code & 0x08 else 3
    idx = struct.unpack_from("<4H", data, p + 4)[:nverts]
    mode = (light >> 16) & 7
    pos += ncolors
    poly = Polygon()
    poly.indices, poly.code, poly.flags, poly.light = idx, code, nv_flags, light
    poly.kind = KIND_QUAD if mode == 4 else KIND_TRIANGLE if mode == 3 else KIND_SPRITE
    poly.sprite_kind = mode if poly.kind == KIND_SPRITE else None
    poly.size = poly.corner = None
    poly.colors = [(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF) for c in colors]
    poly.uvs, poly.clut, poly.tpage, poly.texwin = None, None, None, None
    nuv = nv_flags & 0x7F
    if code & 0x04 and nuv and pos + nverts <= nwords:
        uv = words[pos:pos + nverts]
        poly.uvs = [(u & 0xFF, (u >> 8) & 0xFF) for u in uv]
        poly.clut = uv[0] >> 16
        poly.tpage = uv[1] >> 16
    pos += nuv
    if nv_flags & 0x80:
        if pos < nwords and words[pos] >> 24 == 0xE2:
            poly.texwin = texture_window(words[pos])
        pos += 1
    nnorm = (light >> 19) & 7
    poly.normals = struct.unpack_from(f"<{nnorm}H", data, p + 4 * pos) if nnorm else ()
    return poly, nwords * 4


def parse_mesh(data, off, matrix=IDENTITY, offset=(0, 0, 0)):
    """Decode the mesh body at `off` and place its vertices with matrix/offset.

    Body layout: +0 id<<16 | 0xFF00, +4 vertices, +8 normals (may point outside
    the file, to a run-time buffer), +0xC polygons, +0x10 polygon count,
    +0x14/+0x18 flags, +0x1C bounding sphere (int32 x, y, z, radius). When bit 31
    of +0x18 is set, a 3x3 int16 matrix (+0x2C), int32 vector (+0x40) and
    4 more words follow and the polygons start at +0x5C, else at +0x2C. That
    matrix does not place the mesh (its vertices are already in the parent's
    space), so it is not applied here.
    """
    mesh = Mesh(off)
    mesh.id = _u32(data, off) >> 16
    vp, pp, count = _ptr_at(data, off + 4), _ptr_at(data, off + 12), _u32(data, off + 16)
    *center, mesh.radius = struct.unpack_from("<4i", data, off + 0x1C)
    mesh.center = _apply(matrix, offset, center)
    if vp is None or pp is None:
        return mesh
    p, max_idx, max_n, sprites = pp, -1, -1, []
    for _ in range(count):
        if p + 4 > len(data):
            break
        poly, size = parse_polygon(data, p)
        if poly is None:
            break
        p += size
        if not 0x20 <= poly.code < 0x40:
            continue
        if poly.normals:
            max_n = max(max_n, *poly.normals)
        if poly.kind == KIND_SPRITE:
            # (centre, half width, half height, corner): centre and corner are
            # vertex indices, the other two are sizes in world units.
            sprites.append(poly)
            continue
        mesh.polygons.append(poly)
        max_idx = max(max_idx, *poly.indices)
    for poly in sprites:
        max_idx = max(max_idx, poly.indices[0], poly.indices[3])
    nv = max_idx + 1
    if vp + nv * 8 > len(data):
        mesh.polygons, sprites, nv = [], [], 0
    local = [struct.unpack_from("<3h", data, vp + i * 8) for i in range(nv)]
    mesh.vertices = [_apply(matrix, offset, v) for v in local]
    np_ = _ptr_at(data, off + 8)
    if np_ is not None and max_n >= 0 and np_ + (max_n + 1) * 8 <= len(data):
        for i in range(max_n + 1):
            n = _apply(matrix, (0, 0, 0), struct.unpack_from("<3h", data, np_ + i * 8))
            length = math.sqrt(sum(c * c for c in n)) or 1.0
            mesh.normals.append(tuple(c / length for c in n))
    for poly in sprites:
        poly.size = (poly.indices[1], poly.indices[2])
        poly.corner = mesh.vertices[poly.indices[3]]
        mesh.sprites.append((mesh.vertices[poly.indices[0]], poly))
    return mesh


# In-game lights (the same for every arena; set by the game's light set-up code and read
# from video RAM state at a match start). Directions are world space (z up) unit vectors
# pointing towards the light; colours and ambient are multipliers (1.0 = 4096 in the GTE).
AMBIENT = (0.125, 0.125, 0.125)
LIGHTS = (
    ((617 / 4096, -3494 / 4096, 2046 / 4096), (200 / 256, 200 / 256, 200 / 256)),
    ((-3425 / 4096, 1982 / 4096, 1056 / 4096), (128 / 256, 75 / 256, 75 / 256)),
    ((3332 / 4096, 1928 / 4096, 1398 / 4096), (60 / 256, 128 / 256, 60 / 256)),
)


def light_normal(n, base, lights=LIGHTS, ambient=AMBIENT):
    """GTE normal-colour lighting: base * (ambient + sum(colour * max(0, dir . n))), clamped."""
    f = list(ambient)
    for d, col in lights:
        k = d[0] * n[0] + d[1] * n[1] + d[2] * n[2]
        if k > 0:
            for c in range(3):
                f[c] += col[c] * k
    return tuple(min(255, int(base[c] * f[c])) for c in range(3))


def vertex_colors(mesh, poly, lights=LIGHTS, ambient=AMBIENT):
    """Return one (r, g, b) per vertex as the game draws it.

    Polygons without normal indices are pre-lit: their colour words are used as
    stored (one flat colour, or one per vertex). With one normal index the base
    colour is lit once (flat); with 3 or 4 each vertex is lit with its own normal.
    When the mesh's normals are not in the file, the face normal is used instead.
    """
    nv = len(poly.indices) if poly.kind != KIND_SPRITE else 4
    cols = poly.colors if len(poly.colors) >= nv else [poly.colors[0]] * nv
    if not poly.normals:
        return [tuple(c) for c in cols[:nv]]
    if all(i < len(mesh.normals) for i in poly.normals):
        ns = [mesh.normals[i] for i in poly.normals]
    else:
        ns = [face_normal(mesh, poly)]
    if len(ns) == 1:
        return [light_normal(ns[0], cols[i], lights, ambient) for i in range(nv)]
    return [light_normal(ns[i % len(ns)], cols[i], lights, ambient) for i in range(nv)]


def face_normal(mesh, poly):
    """Unit face normal in world space, same direction as the file's normals."""
    a, b, c = (mesh.vertices[i] for i in poly.indices[:3])
    u = [b[k] - a[k] for k in range(3)]
    v = [c[k] - a[k] for k in range(3)]
    n = (u[2] * v[1] - u[1] * v[2], u[0] * v[2] - u[2] * v[0], u[1] * v[0] - u[0] * v[1])
    length = math.sqrt(sum(x * x for x in n)) or 1.0
    return tuple(x / length for x in n)


def node_children(data, off):
    """Return (kind, child offsets) for the scene-graph node at `off`."""
    w = _u32(data, off)
    kind = w & 0xFF
    if w & 0xFFFF == 0xFF00:
        return "mesh", []
    if (w >> 8) & 0xFF == 0xFF:
        return "box", []  # 0xFF07/0xFF08 leaf boxes
    if kind == 0x01:  # +4 x,y,z,radius (int32), +0x14 count (byte), +0x18 children
        return "group", [_ptr_at(data, off + 0x18 + 4 * i) for i in range(data[off + 0x14])]
    if kind == 0x02:  # +4 x,y,z, +0x10 count, +0x14 entries (far dist^2, near dist^2, node)
        entries = [_ptr_at(data, off + 0x14 + 4 * i) for i in range(data[off + 0x10])]
        return "lod", [e for e in entries if e is not None]  # entries, not nodes; see walk()
    if kind == 0x04:  # +4 x,y,z (int32), +0x12 count, +0x14 children
        return "translate", [_ptr_at(data, off + 0x14 + 4 * i) for i in range(data[off + 0x12])]
    if kind == 0x05:  # +4 3x3 int16 matrix, +0x18 x,y,z (int32), +0x26 count, +0x28 children
        return "transform", [_ptr_at(data, off + 0x28 + 4 * i) for i in range(data[off + 0x26])]
    if kind == 0x03:
        # Animation: +6 u16 delay, +8 first frame, +9 last frame, +0xA mode (1 = ping-pong),
        # +0xB frame count, +0xC current frame, +0xD direction, +0xE u16 timer, +0x10 frames
        return "animation", [_ptr_at(data, off + 0x10 + 4 * i) for i in range(data[off + 0x0B])]
    if kind == 0x09:  # +4 slot (byte), +6 count, +7 current state, +8 children
        return "switch", [_ptr_at(data, off + 8 + 4 * i) for i in range(data[off + 6])]
    if kind == 0x0B:
        # Spatial split: +4 flags, +0xA region count n, +0xC child drawn when the camera is
        # outside every region, +0x10 child drawn when it is inside one, +0x14 n pointers to
        # region blocks (see split_regions). Both children are walked; Split.contains() says
        # which one the game would draw for a camera position.
        return "split", [_ptr_at(data, off + 0x0C), _ptr_at(data, off + 0x10)]
    return "unknown", []


def node_hidden(data, off, kind):
    """True when the node's hidden flag (bit 1) is set; the game skips it and its subtree.

    Flag byte: group +0x15, translate +0x13, transform +0x27, split word +4. In the files
    only empty (collision-only) groups have it; the game sets the count bytes to 0 to remove
    destroyed objects and taken pickups instead.
    """
    if kind == "group":
        return bool(data[off + 0x15] & 2)
    if kind == "translate":
        return bool(data[off + 0x13] & 2)
    if kind == "transform":
        return bool(data[off + 0x27] & 2)
    if kind == "split":
        return bool(_u32(data, off + 4) & 2)
    return False


# Walk context: (switch chain, animation chain, tag, tag node, split chain). A chain is a
# tuple of (index into Object.switches / .animations / .splits, chosen child or side),
# outermost first.
_ROOT_CTX = ((), (), 0, -1, ())


def _walk(data, off, matrix, offset, out, path, dist2, ctx, obj, pending):
    """walk() with variant tracking: appends (mesh offset, matrix, offset, ctx) to out.

    Each switch / animation reached is added to obj.switches / obj.animations, and queued
    in pending as (kind, index, matrix, offset, path, ctx) so its other children can be
    walked later. Only the current child (switch +7, animation +0xC) is walked here.
    Each split reached is added to obj.splits and both its children are walked.
    """
    if off is None or off in path or len(path) > 64:
        return out
    kind, kids = node_children(data, off)
    if kind == "mesh":
        out.append((off, matrix, offset, ctx))
        return out
    if node_hidden(data, off, kind):
        return out
    tag = _u32(data, off) >> 16
    if path and tag and kind != "box":
        ctx = (ctx[0], ctx[1], tag, off, ctx[4])
    kid_ctx = None
    if kind == "translate":
        offset = _apply(matrix, offset, struct.unpack_from("<3i", data, off + 4))
    elif kind == "transform":
        h = struct.unpack_from("<9h", data, off + 4)
        local = tuple(tuple(h[c * 3 + r] / 4096 for c in range(3)) for r in range(3))  # stored column by column
        offset = _apply(matrix, offset, struct.unpack_from("<3i", data, off + 0x18))
        matrix = _mat_mul(matrix, local)
    elif kind == "lod":
        kids = [_ptr_at(data, e + 8) for e in kids if _u32(data, e + 4) <= dist2 < _u32(data, e)]
    elif kind in ("switch", "animation"):
        sel = data[off + (7 if kind == "switch" else 0x0C)]
        if sel >= len(kids):
            sel = 0
        parent = ctx[0][-1] if ctx[0] else None
        if kind == "switch":
            obj.switches.append(Switch(off, tag, data[off + 4], len(kids), sel, parent))
            index = len(obj.switches) - 1
        else:
            delay = struct.unpack_from("<H", data, off + 6)[0]
            obj.animations.append(Animation(off, tag, delay, data[off + 8], data[off + 9],
                                            data[off + 0x0A], len(kids), sel, parent))
            index = len(obj.animations) - 1
        pending.append((kind, index, matrix, offset, path + (off,), ctx))
        ctx = _child_ctx(ctx, kind, index, sel)
        kids = kids[sel:sel + 1]
    elif kind == "split":
        parent = ctx[0][-1] if ctx[0] else None
        obj.splits.append(Split(off, offset, split_regions(data, off), parent))
        index = len(obj.splits) - 1
        kid_ctx = [_child_ctx(ctx, kind, index, side) for side in range(len(kids))]
    for i, kid in enumerate(kids):
        _walk(data, kid, matrix, offset, out, path + (off,), dist2,
              ctx if kid_ctx is None else kid_ctx[i], obj, pending)
    return out


def _child_ctx(ctx, kind, index, child):
    if kind == "switch":
        return (ctx[0] + ((index, child),), ctx[1], ctx[2], ctx[3], ctx[4])
    if kind == "split":
        return (ctx[0], ctx[1], ctx[2], ctx[3], ctx[4] + ((index, child),))
    return (ctx[0], ctx[1] + ((index, child),), ctx[2], ctx[3], ctx[4])


def walk(data, off, matrix=IDENTITY, offset=(0, 0, 0), out=None, path=(), dist2=0):
    """Collect (mesh offset, matrix, offset) for every mesh under the node at `off`.

    A child's world position is matrix * local + offset. A level-of-detail
    entry is (far dist^2, near dist^2, node) and is drawn when near <= dist2 <
    far; one model's levels may be spread over sibling LOD nodes. dist2=0 gives
    the most detailed version. Switch and animation nodes take their current child
    (the default state); hidden nodes are skipped.
    """
    out = [] if out is None else out
    found = _walk(data, off, matrix, offset, [], path, dist2, _ROOT_CTX, Object(off, 0, (0, 0, 0), 0), [])
    out.extend(e[:3] for e in found)
    return out


def _place(data, obj, entry):
    """Parse one walk entry into a Mesh, set its context, and file it under its variants."""
    off, matrix, offset, (swc, anc, tag, tag_node, spc) = entry
    mesh = parse_mesh(data, off, matrix, offset)
    mesh.tag, mesh.tag_node = tag, tag_node
    if swc:
        mesh.switch_node = obj.switches[swc[-1][0]].offset
        mesh.switch_id = obj.switches[swc[-1][0]].id
        mesh.state = swc[-1][1]
    if anc:
        mesh.anim_node, mesh.frame = obj.animations[anc[-1][0]].offset, anc[-1][1]
    if spc:
        mesh.split_node, mesh.split_side = obj.splits[spc[-1][0]].offset, spc[-1][1]
    for index, side in spc:  # every split above it, nested ones included
        (obj.splits[index].inside if side else obj.splits[index].outside).append(mesh)
    # A mesh belongs to its innermost switch's state, and to the enclosing switches' states
    # as long as every switch below them is in its default state.
    for chain, items, attr in ((swc, obj.switches, "states"), (anc, obj.animations, "frames")):
        for index, child in reversed(chain):
            getattr(items[index], attr)[child].append(mesh)
            if child != items[index].default:
                break
    return mesh


def objects(data):
    """Return the file's top-level objects, each with its meshes in world space.

    Object.meshes is what the game draws by default. Object.switches and
    Object.animations hold every switch / animation reached, with the meshes of each
    of their states / frames (the other states are walked after the default walk,
    in the order the switches were found; switches nested in them are added too).
    """
    result = []
    for i in range(_u32(data, 0x14)):
        off = _ptr_at(data, 0x18 + 4 * i)
        if off is None:
            continue
        *center, radius = struct.unpack_from("<4i", data, off + 4)
        obj = Object(off, _u32(data, off) >> 16, tuple(center), radius)
        pending = []
        entries = _walk(data, off, IDENTITY, (0, 0, 0), [], (), 0, _ROOT_CTX, obj, pending)
        obj.meshes = [_place(data, obj, e) for e in entries]
        k = 0
        while k < len(pending):
            kind, index, matrix, offset, path, ctx = pending[k]
            k += 1
            node = (obj.switches if kind == "switch" else obj.animations)[index]
            _, kids = node_children(data, node.offset)
            for child, kid in enumerate(kids):
                if child == node.default:
                    continue
                for e in _walk(data, kid, matrix, offset, [], path, 0, _child_ctx(ctx, kind, index, child), obj, pending):
                    _place(data, obj, e)
        result.append(obj)
    return result


def load(path, ids=None):
    """Return world-space meshes.

    ids=None returns the arena (objects LEVEL_IDS) when the file has one, else
    every object (e.g. CARS.DMD). Pass a tuple of object ids to choose, e.g.
    (SKY_ID,) for the sky dome.
    """
    data = open(path, "rb").read()
    if data[:5] != b"DXSPC":
        raise ValueError("not a DMD file")
    objs = objects(data)
    if ids is None:
        ids = LEVEL_IDS if any(o.id in LEVEL_IDS for o in objs) else None
    return [m for o in objs if ids is None or o.id in ids for m in o.meshes]


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    for i, o in enumerate(objects(data)):
        polys = sum(len(m.polygons) for m in o.meshes)
        print(f"object {i} @{o.offset:#x} id {o.id:#x}: centre {o.center} radius {o.radius}, "
              f"{len(o.meshes)} meshes, {polys} polygons")
