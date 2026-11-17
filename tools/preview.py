"""Render a quick software preview of DMD meshes for checking the decoder.

Usage: python3 -I tools/preview.py <file.DMD> <file.TMS> <out.png> [object_index]
       python3 -I tools/preview.py <file.DMD> <file.TMS> <out.png> --eye x,y,z --at x,y,z [--fov 60] [--size 320x240]
       add --bg r,g,b to set the background (default: the arena's clear colour, dmd.BACKGROUND)

Without object_index an arena file renders the whole arena in world space
(a car file renders every car on top of each other). The world is z-up; the
default camera looks down at it from above (orthographic). --eye/--at give a
perspective camera in world units, e.g. a driver's view to compare with an
emulator frame.

What it draws like the PS1: lighting from normals (dmd.vertex_colors), Gouraud
colours, texture modulation (texel * colour / 128, or the raw texel when bit 0 of
the GPU code is set), texture windows (0xE2), 4/8/15-bit textures, colour 0x0000
as transparent, semi-transparency (blend mode from the texture page; texels with
bit 15 clear stay opaque) and sprites as billboards. Texture mapping is affine.
"""
import math
import os
import sys

import numpy as np
from PIL import Image

# The DMD model decoder is game-specific; it lives in the Twisted Metal worked example.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "games", "twisted-metal"))
import dmd  # noqa: E402
from vram import VRAM, blend_mode, window

NEAR = 8.0


def _camera(pts, yaw, pitch, eye, target, size, fov):
    """Return (to_camera, project, camera axes in world space, perspective?). size = (w, h)."""
    W, H = size
    if eye is None:
        center = (pts.max(0) + pts.min(0)) / 2
        cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
        flip = np.diag([1.0, -1.0, -1.0])  # z-up world, camera above
        rot = np.array([[cy, 0, -sy], [0, 1, 0], [sy, 0, cy]]) @ np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]]).T @ flip
        scale = 0.9 * min(W, H) / max(np.ptp((pts - center) @ rot.T, axis=0)[:2].max(), 1e-6)
        to_cam = lambda p: (p - center) @ rot.T
        project = lambda c: (c[:, 0] * scale + W / 2, c[:, 1] * scale + H / 2, c[:, 2])
        return to_cam, project, rot, False  # rot rows: screen right, screen down, depth
    eye, target = np.asarray(eye, float), np.asarray(target, float)
    fwd = target - eye
    fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, (0, 0, 1.0))
    if np.linalg.norm(right) < 1e-6:
        right = np.array([1.0, 0, 0])
    right /= np.linalg.norm(right)
    down = np.cross(fwd, right)
    rot = np.stack([right, down, fwd])
    f = W / 2 / math.tan(math.radians(fov) / 2)  # fov is horizontal
    to_cam = lambda p: (p - eye) @ rot.T
    project = lambda c: (c[:, 0] / c[:, 2] * f + W / 2, c[:, 1] / c[:, 2] * f + H / 2, c[:, 2])
    return to_cam, project, rot, True


def _sprite_quad(center, poly, axes):
    """World corners (TL, TR, BL, BR) of a sprite turned towards the camera."""
    w, h = poly.size
    c = np.asarray(center, float)
    if poly.sprite_kind == 1:  # faces the camera
        right, up = axes[0], -axes[1]
    else:  # stays upright and turns about the world z axis
        right = np.array([axes[0][0], axes[0][1], 0.0])
        right /= np.linalg.norm(right) or 1.0
        up = np.array([0, 0, 1.0])
    return np.array([c - right * w + up * h, c + right * w + up * h,
                     c - right * w - up * h, c + right * w - up * h])


def _clip_near(cam, attrs):
    """Clip a camera-space polygon against z = NEAR, interpolating the attributes."""
    out_c, out_a = [], []
    n = len(cam)
    for i in range(n):
        a, b = i, (i + 1) % n
        za, zb = cam[a][2], cam[b][2]
        if za >= NEAR:
            out_c.append(cam[a]); out_a.append(attrs[a])
        if (za >= NEAR) != (zb >= NEAR):
            t = (NEAR - za) / (zb - za)
            out_c.append(cam[a] + t * (cam[b] - cam[a]))
            out_a.append(attrs[a] + t * (attrs[b] - attrs[a]))
    return np.array(out_c), np.array(out_a)


def render(meshes, vram, size=512, yaw=0.7, pitch=0.5, eye=None, target=None, fov=60.0,
           sprites=True, lighting=True, background=(40, 40, 40)):
    items = []  # (world verts (n,3), uvs (n,2) or None, colours (n,3), poly)
    for m in meshes:
        for p in m.polygons:
            cols = dmd.vertex_colors(m, p) if lighting else [p.colors[0]] * len(p.indices)
            items.append((np.array([m.vertices[i] for i in p.indices], float),
                          np.array(p.uvs, float) if p.uvs else None, np.array(cols, float), p))
    if not items:
        raise ValueError("nothing to draw")
    pts = np.concatenate([it[0] for it in items])
    W, H = (size, size) if np.isscalar(size) else size
    to_cam, project, axes, perspective = _camera(pts, yaw, pitch, eye, target, (W, H), fov)
    if sprites:
        for m in meshes:
            for center, p in m.sprites:
                cols = dmd.vertex_colors(m, p) if lighting else [p.colors[0]] * 4
                items.append((_sprite_quad(center, p, axes), np.array(p.uvs, float) if p.uvs else None,
                              np.array(cols, float), p))

    img = np.zeros((H, W, 3), float)
    img[:] = background
    depth = np.full((H, W), np.inf)
    pages = {}
    yy, xx = np.mgrid[0:H, 0:W]
    semi = []

    def raster(verts2, attrs, p, blend):
        x, y, z = verts2
        x0, x1 = int(max(x.min(), 0)), int(min(x.max() + 1, W))
        y0, y1 = int(max(y.min(), 0)), int(min(y.max() + 1, H))
        if x0 >= x1 or y0 >= y1:
            return
        d = (y[1] - y[2]) * (x[0] - x[2]) + (x[2] - x[1]) * (y[0] - y[2])
        if abs(d) < 1e-9:
            return
        px, py = xx[y0:y1, x0:x1] + 0.5, yy[y0:y1, x0:x1] + 0.5
        a = ((y[1] - y[2]) * (px - x[2]) + (x[2] - x[1]) * (py - y[2])) / d
        b = ((y[2] - y[0]) * (px - x[2]) + (x[0] - x[2]) * (py - y[2])) / d
        c = 1 - a - b
        inside = (a >= 0) & (b >= 0) & (c >= 0)
        zz = a * z[0] + b * z[1] + c * z[2]
        win = inside & (zz < depth[y0:y1, x0:x1])
        if not win.any():
            return
        lerp = lambda k: a * attrs[0, k] + b * attrs[1, k] + c * attrs[2, k]
        col = np.stack([lerp(2), lerp(3), lerp(4)], -1)
        stp = np.ones(win.shape, bool)
        if p.uvs is not None and p.tpage is not None:
            key = (p.tpage, p.clut)
            if key not in pages:
                pages[key] = vram.page_raw(p.tpage, p.clut)
            u = lerp(0).astype(int) & 255
            v = lerp(1).astype(int) & 255
            u, v = window(u, v, p.texwin)
            raw = pages[key][v, u].astype(np.uint32)
            tex = np.stack([(raw & 31) << 3, ((raw >> 5) & 31) << 3, ((raw >> 10) & 31) << 3], -1).astype(float)
            win &= raw != 0
            stp = (raw & 0x8000) != 0
            col = tex if p.code & 1 else tex * col / 128
        col = col.clip(0, 255)
        region = img[y0:y1, x0:x1]
        if blend is None:
            region[win] = col[win]
            depth[y0:y1, x0:x1][win] = zz[win]
            return
        opaque = win & ~stp
        region[opaque] = col[opaque]
        depth[y0:y1, x0:x1][opaque] = zz[opaque]
        mix = win & stp
        back, front = region[mix], col[mix]
        region[mix] = (back / 2 + front / 2, back + front, back - front, back + front / 4)[blend].clip(0, 255)

    def draw(verts, uvs, cols, p, blend):
        cam = to_cam(verts)
        attrs = np.concatenate([uvs if uvs is not None else np.zeros((len(verts), 2)), cols], 1)
        order = [(0, 1, 2), (1, 3, 2)] if len(verts) == 4 else [(0, 1, 2)]
        for t in order:
            c, at = cam[list(t)], attrs[list(t)]
            if perspective and (c[:, 2] < NEAR).any():
                if (c[:, 2] < NEAR).all():
                    continue
                c, at = _clip_near(c, at)
                for k in range(1, len(c) - 1):
                    tri = [0, k, k + 1]
                    raster(project(c[tri]), at[tri], p, blend)
                continue
            raster(project(c), at, p, blend)

    for verts, uvs, cols, p in items:
        if p.code & 2:
            semi.append((float(to_cam(verts)[:, 2].mean()), verts, uvs, cols, p))
            continue
        draw(verts, uvs, cols, p, None)
    for _, verts, uvs, cols, p in sorted(semi, key=lambda s: -s[0]):
        draw(verts, uvs, cols, p, blend_mode(p.tpage))
    return Image.fromarray(img.astype(np.uint8))


if __name__ == "__main__":
    args = sys.argv[1:]
    opts = {}
    while any(a.startswith("--") for a in args):
        i = next(k for k, a in enumerate(args) if a.startswith("--"))
        opts[args[i][2:]] = args[i + 1]
        del args[i:i + 2]
    vram = VRAM(); vram.load_tms(args[1])
    if len(args) > 3:
        data = open(args[0], "rb").read()
        meshes = dmd.objects(data)[int(args[3])].meshes
    else:
        meshes = dmd.load(args[0])
    vec = lambda s: tuple(float(x) for x in s.split(","))
    kw = {}
    if "eye" in opts:
        kw = dict(eye=vec(opts["eye"]), target=vec(opts["at"]), fov=float(opts.get("fov", 60)))
    size = tuple(int(x) for x in opts.get("size", "512").split("x"))
    # The game's screen clear colour fills whatever no polygon covers (e.g. SUBURB's centre).
    arena = os.path.splitext(os.path.basename(args[0]))[0].upper().rstrip("0123456789")
    if "bg" in opts:
        kw["background"] = tuple(int(x) for x in opts["bg"].split(","))
    elif arena in dmd.BACKGROUND:
        kw["background"] = dmd.BACKGROUND[arena]
    render(meshes, vram, size=size if len(size) == 2 else size[0], **kw).save(args[2])
    print("saved", args[2])
