class_name DiscDmd
extends RefCounted
## Parses DMD model files. A line-by-line port of games/twisted-metal/dmd.py: keep the two in step.
## Each function names the Python function it mirrors, so fixes there can be copied here.
## Transforms and lighting use 64-bit floats (PackedFloat64Array, not Basis) so results match
## Python to the integer; only final positions are stored as Vector3.
##
## A DMD file is a memory image loaded at LOAD_BASE; every pointer inside it is an absolute
## PS1 address. The header lists top-level objects; each object is a scene graph of group,
## level-of-detail, translate, rotate+translate and switch nodes ending in mesh bodies.
## Walking the graph and applying the transforms on the way down gives world-space meshes
## (z-up, game units). See README.md "File formats".
##
## One difference from dmd.py, for memory only: DmdMesh.vertices holds just the vertices the
## polygons use (polygon indices are remapped to it). DmdMesh.vertex_count is dmd.py's
## len(mesh.vertices), so counts can be compared directly.

const LOAD_BASE := 0x800188B8

const LEVEL_ID := 1
const SKY_ID := 2
const FLOOR_ID := 3
const LEVEL_IDS := [LEVEL_ID, FLOOR_ID]

enum Kind { SPRITE, TRIANGLE, QUAD }

# In-game lights (dmd.py AMBIENT / LIGHTS): world-space (z-up) unit directions towards the
# light, colours and ambient as multipliers (1.0 = 4096 in the GTE).
const AMBIENT := [0.125, 0.125, 0.125]
const LIGHTS := [
	[[617 / 4096.0, -3494 / 4096.0, 2046 / 4096.0], [200 / 256.0, 200 / 256.0, 200 / 256.0]],
	[[-3425 / 4096.0, 1982 / 4096.0, 1056 / 4096.0], [128 / 256.0, 75 / 256.0, 75 / 256.0]],
	[[3332 / 4096.0, 1928 / 4096.0, 1398 / 4096.0], [60 / 256.0, 128 / 256.0, 60 / 256.0]],
]

const IDENTITY := [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]   # row-major 3x3

# dmd.py BACKGROUND: screen clear colour per arena (manifest arena id). Areas no polygon
# covers (the centres of SUBURB and XFWY) show this colour in the game; use it as the
# camera's clear colour. The PS1 shows it at 5 bits per channel.
const BACKGROUND := {
	"XARENA": Color8(40, 40, 40), "WH": Color8(75, 70, 55), "XFWY": Color8(60, 45, 20),
	"PARK": Color8(75, 60, 30), "SUBURB": Color8(110, 110, 100), "ROOF": Color8(0, 20, 0),
}

# dmd.py DESTRUCTIBLE: switch tag -> [hit points, destruction shows state 1 (else the node is
# hidden)]. Tags not listed have 1 hit point.
const DESTRUCTIBLE := {
	0x258: [8, true], 0x259: [3, true], 0x262: [5, true], 0x263: [15, true], 0x264: [10, true],
	0x265: [20, true], 0x302: [1, true], 0x386: [25, true], 0x3E8: [100, true], 0x3E9: [1, true],
	0x3EA: [4, true], 0x3F1: [4, true], 0x3F2: [4, true], 0x3F9: [8, true],
}

class Polygon:
	var indices := PackedInt32Array()   # into DmdMesh.vertices (remapped); sprites: raw values
	var code := 0                       # GPU command byte of the first colour word (0x20-0x3F)
	var colors := PackedInt32Array()    # 0xBBGGRR per colour word (1, 3 or 4)
	var uvs := PackedInt32Array()       # u | v << 8 per vertex; empty when untextured
	var clut := -1
	var tpage := -1
	var flags := 0                      # byte 0: low 7 bits = UV word count, bit 7 = 0xE2 word
	var kind := Kind.TRIANGLE
	var light := 0                      # the raw lighting word
	var normals := PackedInt32Array()   # indices into DmdMesh.normals; empty = pre-lit
	var texwin := PackedInt32Array()    # (mask_u, mask_v, offset_u, offset_v) or empty
	var sprite_kind := -1               # sprites: 0 = upright (turns about z), 1 = faces camera
	var size := Vector2i.ZERO           # sprites: half width, half height (world units)
	var center := Vector3.ZERO          # sprites: world centre
	var corner := Vector3.ZERO          # sprites: world reference corner

	func is_textured() -> bool:
		return not uvs.is_empty()

class DmdMesh:
	var offset := 0
	var id := 0
	# Variant context (dmd.py Mesh): innermost switch / animation above this mesh and which
	# child it is in, and the nearest tagged node (id != 0 below the root, e.g. a pickup).
	var switch_node := -1
	var switch_id := 0
	var state := 0
	var anim_node := -1
	var frame := 0
	var tag := 0
	var tag_node := -1
	var split_node := -1     # innermost spatial split above it, or -1
	var split_side := -1     # 0 = drawn while the camera is outside its regions, 1 = inside
	var center := Vector3.ZERO          # world space
	var radius := 0
	var vertices := PackedVector3Array()  # world space, only the vertices polygons use
	var vertex_count := 0                 # dmd.py's len(mesh.vertices)
	var normals := PackedFloat64Array()   # unit normals, 3 per normal, world space
	var polygons: Array = []              # triangles and quads
	var sprites: Array = []               # [world centre: Vector3, Polygon]
	var raw_face_normals := {}            # sprite polygon -> face normal (see parse_mesh)

	func normal_count() -> int:
		return normals.size() / 3

## A switch node (dmd.py Switch): the game draws child `default` (byte +7) of `count`.
## states[i] = the DmdMesh list of child i; states[default] holds meshes from DmdObject.meshes.
class DmdSwitch:
	var offset := 0
	var id := 0          # node tag, e.g. 0x264; vehicle body = vehicle id + 1
	var slot := 0        # byte +4, instance number (1, 2, ...)
	var count := 0
	var default := 0
	var parent := []     # [switch index, state] this switch sits in, or empty
	var states: Array = []

## An animation node (dmd.py Animation): a frame lasts delay + 1 renders at 20 per second.
class DmdAnimation:
	var offset := 0
	var id := 0
	var delay := 0
	var first := 0
	var last := 0
	var mode := 0        # 0 = loop, 1 = ping-pong
	var count := 0
	var default := 0
	var parent := []
	var frames: Array = []

## A spatial split node (dmd.py Split): the game draws `inside` while the camera is in any
## region, else `outside`. Both are in DmdObject.meshes; toggle them with contains(camera).
class DmdSplit:
	var offset := 0
	var origin := PackedFloat64Array()   # world position of the node
	var regions: Array = []              # [matrix (9 int16 row by row), low (3), size (3)]
	var parent := []
	var outside: Array = []
	var inside: Array = []

	# Camera in world units (z up). Inside: 0 < low + matrix * (camera - origin) / 4096 < size.
	func contains(camera: Vector3) -> bool:
		var c := [camera.x - origin[0], camera.y - origin[1], camera.z - origin[2]]
		for reg in regions:
			var mat: PackedInt32Array = reg[0]
			var low: PackedInt32Array = reg[1]
			var size: PackedInt32Array = reg[2]
			var ok := true
			for r in 3:
				var p: float = (mat[3 * r] * c[0] + mat[3 * r + 1] * c[1] + mat[3 * r + 2] * c[2]) / 4096.0
				if not (0.0 < low[r] + p and low[r] + p < size[r]):
					ok = false
					break
			if ok:
				return true
		return false

class DmdObject:
	var offset := 0
	var id := 0
	var center := Vector3.ZERO
	var radius := 0
	var meshes: Array = []       # the default state
	var switches: Array = []     # DmdSwitch, in the order found
	var animations: Array = []   # DmdAnimation, in the order found
	var splits: Array = []       # DmdSplit, in the order found

var data := PackedByteArray()

static func from_bytes(bytes: PackedByteArray) -> DiscDmd:
	if bytes.size() < 0x18 or bytes.slice(0, 5).get_string_from_ascii() != "DXSPC":
		return null
	var d := DiscDmd.new()
	d.data = bytes
	return d

# _ptr / _ptr_at: an absolute address to a file offset, or -1 when outside the file.
func _ptr(value: int) -> int:
	var off := value - LOAD_BASE
	return off if off >= 0 and off < data.size() else -1

func _ptr_at(off: int) -> int:
	return _ptr(data.decode_u32(off))

# _mat_mul(a, b) on row-major 3x3 float64 arrays.
static func _mat_mul(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var r := PackedFloat64Array()
	r.resize(9)
	for i in 3:
		for j in 3:
			r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
	return r

# _apply(m, t, v) = m * v + t, all float64.
static func _apply(m: PackedFloat64Array, t: PackedFloat64Array, x: float, y: float, z: float) -> PackedFloat64Array:
	return PackedFloat64Array([
		m[0] * x + m[1] * y + m[2] * z + t[0],
		m[3] * x + m[4] * y + m[5] * z + t[1],
		m[6] * x + m[7] * y + m[8] * z + t[2]])

static func _v3(a: PackedFloat64Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

func _vertex(m: PackedFloat64Array, t: PackedFloat64Array, vp: int, i: int) -> PackedFloat64Array:
	var a := vp + i * 8
	return _apply(m, t, data.decode_s16(a), data.decode_s16(a + 2), data.decode_s16(a + 4))

# texture_window(): 0xE2 word -> (mask_u, mask_v, offset_u, offset_v) in texels.
static func texture_window(word: int) -> PackedInt32Array:
	return PackedInt32Array([(word & 31) * 8, ((word >> 5) & 31) * 8, ((word >> 10) & 31) * 8, ((word >> 15) & 31) * 8])

# parse_polygon(): returns [Polygon or null, size in bytes].
func parse_polygon(p: int) -> Array:
	var nv_flags := data[p]
	var ncolors := data[p + 1]
	var nwords := data[p + 2]
	if nwords == 0 or p + nwords * 4 > data.size():
		return [null, 0]
	var poly := Polygon.new()
	poly.light = data.decode_u32(p + 12)
	var pos := 4  # header + 2 index words + 1 lighting word
	poly.colors.resize(ncolors)
	for i in ncolors:
		var c := data.decode_u32(p + (pos + i) * 4)
		poly.colors[i] = c & 0xFFFFFF
		if i == 0:
			poly.code = c >> 24
	var nverts := 4 if poly.code & 0x08 else 3
	poly.indices.resize(nverts)
	for i in nverts:
		poly.indices[i] = data.decode_u16(p + 4 + i * 2)
	var mode := (poly.light >> 16) & 7
	pos += ncolors
	poly.flags = nv_flags
	poly.kind = Kind.QUAD if mode == 4 else (Kind.TRIANGLE if mode == 3 else Kind.SPRITE)
	poly.sprite_kind = mode if poly.kind == Kind.SPRITE else -1
	var nuv := nv_flags & 0x7F
	if poly.code & 0x04 and nuv and pos + nverts <= nwords:
		poly.uvs.resize(nverts)
		for i in nverts:
			var w := data.decode_u32(p + (pos + i) * 4)
			poly.uvs[i] = w & 0xFFFF
			if i == 0:
				poly.clut = w >> 16
			elif i == 1:
				poly.tpage = w >> 16
	pos += nuv
	if nv_flags & 0x80:
		if pos < nwords and data.decode_u32(p + pos * 4) >> 24 == 0xE2:
			poly.texwin = texture_window(data.decode_u32(p + pos * 4))
		pos += 1
	var nnorm := (poly.light >> 19) & 7
	for i in nnorm:
		if p + 4 * pos + i * 2 + 2 <= data.size():
			poly.normals.append(data.decode_u16(p + 4 * pos + i * 2))
	return [poly, nwords * 4]

# parse_mesh(): decode the mesh body at off and place its vertices with matrix m / offset t.
func parse_mesh(off: int, m: PackedFloat64Array = PackedFloat64Array(IDENTITY), t: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0])) -> DmdMesh:
	var mesh := DmdMesh.new()
	mesh.offset = off
	mesh.id = data.decode_u32(off) >> 16
	var vp := _ptr_at(off + 4)
	var pp := _ptr_at(off + 12)
	var count := data.decode_u32(off + 16)
	mesh.center = _v3(_apply(m, t, data.decode_s32(off + 0x1C), data.decode_s32(off + 0x20), data.decode_s32(off + 0x24)))
	mesh.radius = data.decode_s32(off + 0x28)
	if vp < 0 or pp < 0:
		return mesh
	var p := pp
	var max_idx := -1
	var max_n := -1
	var sprites: Array = []
	for _i in count:
		if p + 4 > data.size():
			break
		var res := parse_polygon(p)
		var poly: Polygon = res[0]
		if poly == null:
			break
		p += res[1]
		if not (poly.code >= 0x20 and poly.code < 0x40):
			continue
		for n in poly.normals:
			max_n = maxi(max_n, n)
		if poly.kind == Kind.SPRITE:
			# (centre, half width, half height, corner): centre and corner are vertex
			# indices, the other two are sizes in world units.
			sprites.append(poly)
			continue
		mesh.polygons.append(poly)
		for idx in poly.indices:
			max_idx = maxi(max_idx, idx)
	for poly in sprites:
		max_idx = maxi(max_idx, maxi(poly.indices[0], poly.indices[3]))
	var nv := max_idx + 1
	if vp + nv * 8 > data.size():
		mesh.polygons = []
		sprites = []
		nv = 0
	mesh.vertex_count = nv
	# Keep only the vertices the polygons use, and remap indices to them.
	var remap := PackedInt32Array()
	remap.resize(nv)
	remap.fill(-1)
	for poly in mesh.polygons:
		var idx: PackedInt32Array = poly.indices
		for i in idx.size():
			var src := idx[i]
			if remap[src] < 0:
				remap[src] = mesh.vertices.size()
				mesh.vertices.append(_v3(_vertex(m, t, vp, src)))
			idx[i] = remap[src]
		poly.indices = idx
	var np_ := _ptr_at(off + 8)
	if np_ >= 0 and max_n >= 0 and np_ + (max_n + 1) * 8 <= data.size():
		var zero := PackedFloat64Array([0.0, 0.0, 0.0])
		for i in max_n + 1:
			var a := np_ + i * 8
			var n := _apply(m, zero, data.decode_s16(a), data.decode_s16(a + 2), data.decode_s16(a + 4))
			var length := sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
			if length == 0.0:
				length = 1.0
			mesh.normals.append_array(PackedFloat64Array([n[0] / length, n[1] / length, n[2] / length]))
	for poly in sprites:
		poly.size = Vector2i(poly.indices[1], poly.indices[2])
		var c := _vertex(m, t, vp, poly.indices[0])
		poly.center = _v3(c)
		poly.corner = _v3(_vertex(m, t, vp, poly.indices[3]))
		# face_normal() of a sprite reads raw vertices 0-2; keep it for vertex_colors().
		var tri: Array = []
		for k in 3:
			tri.append(_vertex(m, t, vp, poly.indices[k]) if poly.indices[k] < nv else c)
		mesh.raw_face_normals[poly] = _face_normal_of(tri[0], tri[1], tri[2])
		mesh.sprites.append([poly.center, poly])
	return mesh

# light_normal(): GTE normal-colour lighting, base * (ambient + sum(colour * max(0, dir . n))).
static func light_normal(n: PackedFloat64Array, base: int) -> int:
	var f := [AMBIENT[0], AMBIENT[1], AMBIENT[2]]
	for l in LIGHTS:
		var d: Array = l[0]
		var k: float = d[0] * n[0] + d[1] * n[1] + d[2] * n[2]
		if k > 0:
			for c in 3:
				f[c] += l[1][c] * k
	var out := 0
	for c in 3:
		var b := (base >> (8 * c)) & 0xFF
		out |= mini(255, int(b * f[c])) << (8 * c)
	return out

# vertex_colors(): one 0xBBGGRR per vertex as the game draws it. Pre-lit polygons (no
# normal indices) use the colour words as stored; 1 normal = flat lit; 3/4 = per vertex.
# When the mesh's normals are not in the file, the face normal is used.
static func vertex_colors(mesh: DmdMesh, poly: Polygon) -> PackedInt32Array:
	var nv := poly.indices.size() if poly.kind != Kind.SPRITE else 4
	var cols := PackedInt32Array()
	for i in nv:
		cols.append(poly.colors[i] if poly.colors.size() >= nv else poly.colors[0])
	if poly.normals.is_empty():
		return cols
	var ns: Array = []
	var have := true
	for i in poly.normals:
		if i >= mesh.normal_count():
			have = false
	if have:
		for i in poly.normals:
			ns.append(mesh.normals.slice(i * 3, i * 3 + 3))
	elif poly.kind == Kind.SPRITE:
		ns.append(mesh.raw_face_normals[poly])
	else:
		ns.append(face_normal(mesh, poly))
	var out := PackedInt32Array()
	for i in nv:
		out.append(light_normal(ns[0] if ns.size() == 1 else ns[i % ns.size()], cols[i]))
	return out

# face_normal(): unit face normal in world space, same direction as the file's normals.
static func face_normal(mesh: DmdMesh, poly: Polygon) -> PackedFloat64Array:
	var v := []
	for k in 3:
		var p := mesh.vertices[poly.indices[k]]
		v.append(PackedFloat64Array([p.x, p.y, p.z]))
	return _face_normal_of(v[0], v[1], v[2])

static func _face_normal_of(a: PackedFloat64Array, b: PackedFloat64Array, c: PackedFloat64Array) -> PackedFloat64Array:
	var u := [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
	var w := [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
	var n := [u[2] * w[1] - u[1] * w[2], u[0] * w[2] - u[2] * w[0], u[1] * w[0] - u[0] * w[1]]
	var length := sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
	if length == 0.0:
		length = 1.0
	return PackedFloat64Array([n[0] / length, n[1] / length, n[2] / length])

# node_children(): returns [kind name, child offsets (-1 = pointer outside the file)].
func node_children(off: int) -> Array:
	var w := data.decode_u32(off)
	var kind := w & 0xFF
	var kids := PackedInt32Array()
	if w & 0xFFFF == 0xFF00:
		return ["mesh", kids]
	if (w >> 8) & 0xFF == 0xFF:
		return ["box", kids]  # 0xFF07/0xFF08 leaf boxes
	match kind:
		0x01:  # group: +4 x,y,z,radius (int32), +0x14 count (byte), +0x18 children
			for i in data[off + 0x14]:
				kids.append(_ptr_at(off + 0x18 + 4 * i))
			return ["group", kids]
		0x02:  # lod: +4 x,y,z, +0x10 count, +0x14 entries (far dist^2, near dist^2, node)
			for i in data[off + 0x10]:
				var e := _ptr_at(off + 0x14 + 4 * i)
				if e >= 0:
					kids.append(e)
			return ["lod", kids]  # entries, not nodes; see walk()
		0x04:  # translate: +4 x,y,z (int32), +0x12 count, +0x14 children
			for i in data[off + 0x12]:
				kids.append(_ptr_at(off + 0x14 + 4 * i))
			return ["translate", kids]
		0x05:  # rotate+translate: +4 3x3 int16 matrix, +0x18 x,y,z (int32), +0x26 count, +0x28 children
			for i in data[off + 0x26]:
				kids.append(_ptr_at(off + 0x28 + 4 * i))
			return ["transform", kids]
		0x03:  # animation: +6 delay, +8 first, +9 last, +0xA mode, +0xB count, +0xC current, +0x10 frames
			for i in data[off + 0x0B]:
				kids.append(_ptr_at(off + 0x10 + 4 * i))
			return ["animation", kids]
		0x09:  # switch: +4 slot, +6 count, +7 current state, +8 children
			for i in data[off + 6]:
				kids.append(_ptr_at(off + 8 + 4 * i))
			return ["switch", kids]
		0x0B:  # spatial split: +0xC child drawn outside every region, +0x10 inside one (both returned)
			kids.append(_ptr_at(off + 0x0C))
			kids.append(_ptr_at(off + 0x10))
			return ["split", kids]
	return ["unknown", kids]

# node_hidden(): the hidden flag (bit 1) of group +0x15, translate +0x13, transform +0x27, split +4.
func node_hidden(off: int, kind: String) -> bool:
	match kind:
		"group":
			return data[off + 0x15] & 2 != 0
		"translate":
			return data[off + 0x13] & 2 != 0
		"transform":
			return data[off + 0x27] & 2 != 0
		"split":
			return data.decode_u32(off + 4) & 2 != 0
	return false

# Walk context (dmd.py _ROOT_CTX): [switch chain, animation chain, tag, tag node, split chain];
# a chain is an Array of [index into DmdObject.switches / .animations / .splits, chosen child
# or side], outermost first.
static func _root_ctx() -> Array:
	return [[], [], 0, -1, []]

static func _child_ctx(ctx: Array, kind: String, index: int, child: int) -> Array:
	var sw: Array = ctx[0].duplicate()
	var an: Array = ctx[1].duplicate()
	var sp: Array = ctx[4].duplicate()
	if kind == "switch":
		sw.append([index, child])
	elif kind == "split":
		sp.append([index, child])
	else:
		an.append([index, child])
	return [sw, an, ctx[2], ctx[3], sp]

# split_regions(): the region blocks of a split node, [[matrix (9 int16, row by row), low (3), size (3)]].
func split_regions(off: int) -> Array:
	var out: Array = []
	for i in data[off + 0x0A]:
		var rb := _ptr_at(off + 0x14 + 4 * i)
		if rb < 0:
			continue
		var mat := PackedInt32Array()
		for k in 9:
			mat.append(data.decode_s16(rb + 2 * k))
		var low := PackedInt32Array()
		var size := PackedInt32Array()
		for k in 3:
			low.append(data.decode_s16(rb + 0x20 + 2 * k))
			size.append(data.decode_s16(rb + 0x28 + 2 * k))
		out.append([mat, low, size])
	return out

# _walk(): walk() with variant tracking; appends [mesh offset, matrix, offset, ctx] to out and
# registers each switch / animation in obj, queueing [kind, index, m, t, path, ctx] in pending.
func _walk(off: int, m: PackedFloat64Array, t: PackedFloat64Array, out: Array, on_path: Dictionary, dist2: int, ctx: Array, obj: DmdObject, pending: Array) -> Array:
	if off < 0 or on_path.has(off) or on_path.size() > 64:
		return out
	var res := node_children(off)
	var kind: String = res[0]
	var kids: PackedInt32Array = res[1]
	if kind == "mesh":
		out.append([off, m, t, ctx])
		return out
	if node_hidden(off, kind):
		return out
	var tag := data.decode_u32(off) >> 16
	if not on_path.is_empty() and tag != 0 and kind != "box":
		ctx = [ctx[0], ctx[1], tag, off, ctx[4]]
	var kid_ctx: Array = []
	if kind == "translate":
		t = _apply(m, t, data.decode_s32(off + 4), data.decode_s32(off + 8), data.decode_s32(off + 12))
	elif kind == "transform":
		# stored column by column: local[r][c] = h[c * 3 + r] / 4096
		var local := PackedFloat64Array()
		local.resize(9)
		for r in 3:
			for c in 3:
				local[r * 3 + c] = data.decode_s16(off + 4 + 2 * (c * 3 + r)) / 4096.0
		t = _apply(m, t, data.decode_s32(off + 0x18), data.decode_s32(off + 0x1C), data.decode_s32(off + 0x20))
		m = _mat_mul(m, local)
	elif kind == "lod":
		var picked := PackedInt32Array()
		for e in kids:
			if data.decode_u32(e + 4) <= dist2 and dist2 < data.decode_u32(e):
				picked.append(_ptr_at(e + 8))
		kids = picked
	elif kind == "switch" or kind == "animation":
		var sel: int = data[off + (7 if kind == "switch" else 0x0C)]
		if sel >= kids.size():
			sel = 0
		var parent: Array = ctx[0][-1].duplicate() if not ctx[0].is_empty() else []
		var index := 0
		if kind == "switch":
			var s := DmdSwitch.new()
			s.offset = off
			s.id = tag
			s.slot = data[off + 4]
			s.count = kids.size()
			s.default = sel
			s.parent = parent
			for i in s.count:
				s.states.append([])
			obj.switches.append(s)
			index = obj.switches.size() - 1
		else:
			var a := DmdAnimation.new()
			a.offset = off
			a.id = tag
			a.delay = data.decode_u16(off + 6)
			a.first = data[off + 8]
			a.last = data[off + 9]
			a.mode = data[off + 0x0A]
			a.count = kids.size()
			a.default = sel
			a.parent = parent
			for i in a.count:
				a.frames.append([])
			obj.animations.append(a)
			index = obj.animations.size() - 1
		var path := on_path.duplicate()
		path[off] = true
		pending.append([kind, index, m, t, path, ctx])
		ctx = _child_ctx(ctx, kind, index, sel)
		kids = kids.slice(sel, sel + 1)
	elif kind == "split":
		var sp := DmdSplit.new()
		sp.offset = off
		sp.origin = t.duplicate()
		sp.regions = split_regions(off)
		sp.parent = ctx[0][-1].duplicate() if not ctx[0].is_empty() else []
		obj.splits.append(sp)
		for side in kids.size():
			kid_ctx.append(_child_ctx(ctx, kind, obj.splits.size() - 1, side))
	on_path[off] = true
	for i in kids.size():
		_walk(kids[i], m, t, out, on_path, dist2, ctx if kid_ctx.is_empty() else kid_ctx[i], obj, pending)
	on_path.erase(off)
	return out

# walk(): collect [mesh offset, matrix, offset] for every mesh under the node at off.
# A LOD entry is drawn when near <= dist2 < far; dist2 = 0 picks the most detailed version.
# Switch and animation nodes take their current child (the default state); hidden nodes are skipped.
func walk(off: int, m: PackedFloat64Array = PackedFloat64Array(IDENTITY), t: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0]), out: Array = [], on_path: Dictionary = {}, dist2 := 0) -> Array:
	for e in _walk(off, m, t, [], on_path, dist2, _root_ctx(), DmdObject.new(), []):
		out.append([e[0], e[1], e[2]])
	return out

# _place(): parse one walk entry, set its context and file it under its switch states /
# animation frames (innermost always; outer ones while every inner one is at its default).
func _place(obj: DmdObject, e: Array) -> DmdMesh:
	var mesh := parse_mesh(e[0], e[1], e[2])
	var ctx: Array = e[3]
	var swc: Array = ctx[0]
	var anc: Array = ctx[1]
	mesh.tag = ctx[2]
	mesh.tag_node = ctx[3]
	if not swc.is_empty():
		var s: DmdSwitch = obj.switches[swc[-1][0]]
		mesh.switch_node = s.offset
		mesh.switch_id = s.id
		mesh.state = swc[-1][1]
	if not anc.is_empty():
		mesh.anim_node = obj.animations[anc[-1][0]].offset
		mesh.frame = anc[-1][1]
	var spc: Array = ctx[4]
	if not spc.is_empty():
		mesh.split_node = obj.splits[spc[-1][0]].offset
		mesh.split_side = spc[-1][1]
	for e2 in spc:  # every split above it, nested ones included
		var sp: DmdSplit = obj.splits[e2[0]]
		if e2[1] == 1:
			sp.inside.append(mesh)
		else:
			sp.outside.append(mesh)
	for k in range(swc.size() - 1, -1, -1):
		var s: DmdSwitch = obj.switches[swc[k][0]]
		s.states[swc[k][1]].append(mesh)
		if swc[k][1] != s.default:
			break
	for k in range(anc.size() - 1, -1, -1):
		var a: DmdAnimation = obj.animations[anc[k][0]]
		a.frames[anc[k][1]].append(mesh)
		if anc[k][1] != a.default:
			break
	return mesh

# objects(): the file's top-level objects. DmdObject.meshes is the default state; switches and
# animations hold every state / frame (other states walked after the default walk, in the order
# the switches were found).
func objects() -> Array:
	var result: Array = []
	for i in data.decode_u32(0x14):
		var off := _ptr_at(0x18 + 4 * i)
		if off < 0:
			continue
		var obj := DmdObject.new()
		obj.offset = off
		obj.id = data.decode_u32(off) >> 16
		obj.center = Vector3(data.decode_s32(off + 4), data.decode_s32(off + 8), data.decode_s32(off + 12))
		obj.radius = data.decode_s32(off + 16)
		var pending: Array = []
		var identity := PackedFloat64Array(IDENTITY)
		var zero := PackedFloat64Array([0.0, 0.0, 0.0])
		for e in _walk(off, identity, zero, [], {}, 0, _root_ctx(), obj, pending):
			obj.meshes.append(_place(obj, e))
		var k := 0
		while k < pending.size():
			var p: Array = pending[k]
			k += 1
			var kind: String = p[0]
			var node = obj.switches[p[1]] if kind == "switch" else obj.animations[p[1]]
			var kids: PackedInt32Array = node_children(node.offset)[1]
			for child in kids.size():
				if child == node.default:
					continue
				for e in _walk(kids[child], p[2], p[3], [], p[4].duplicate(), 0, _child_ctx(p[5], kind, p[1], child), obj, pending):
					_place(obj, e)
		result.append(obj)
	return result

# load(): world-space meshes of the given object ids. ids empty = the arena (LEVEL_IDS)
# when the file has one, else every object.
static func meshes_of(objs: Array, ids: Array = []) -> Array:
	if ids.is_empty():
		for o in objs:
			if o.id in LEVEL_IDS:
				ids = LEVEL_IDS
				break
	var out: Array = []
	for o in objs:
		if ids.is_empty() or o.id in ids:
			out.append_array(o.meshes)
	return out
