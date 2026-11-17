"""Decode PlayStation TIM images to PNG.

Usage: python3 -I tools/tim.py <file.tim | dir> <out_dir>
"""
import os
import struct
import sys

import numpy as np
from PIL import Image


def rgb555_to_rgba(px):
    """Convert PS1 16-bit colours to RGBA. Colour 0x0000 is transparent."""
    px = px.astype(np.uint32)
    r = (px & 31) << 3
    g = ((px >> 5) & 31) << 3
    b = ((px >> 10) & 31) << 3
    a = np.where(px == 0, 0, 255)
    return np.stack([r, g, b, a], axis=-1).astype(np.uint8)


def parse_tim(data, offset=0):
    """Return (rgba_array, bytes_consumed) for the TIM at offset."""
    magic, flags = struct.unpack_from("<II", data, offset)
    if magic != 0x10:
        raise ValueError("not a TIM")
    bpp_mode, has_clut = flags & 7, flags & 8
    pos = offset + 8
    clut = None
    if has_clut:
        blen, _, _, cw, ch = struct.unpack_from("<IHHHH", data, pos)
        clut = np.frombuffer(data, "<u2", cw * ch, pos + 12).reshape(ch, cw)
        pos += blen
    blen, _, _, w16, h = struct.unpack_from("<IHHHH", data, pos)
    raw = np.frombuffer(data, np.uint8, w16 * 2 * h, pos + 12)
    pos += blen
    if bpp_mode == 0:  # 4-bit indexed
        idx = np.stack([raw & 15, raw >> 4], axis=-1).reshape(h, w16 * 4)
        img = rgb555_to_rgba(clut[0][idx])
    elif bpp_mode == 1:  # 8-bit indexed
        img = rgb555_to_rgba(clut[0][raw.reshape(h, w16 * 2)])
    elif bpp_mode == 2:  # 16-bit direct
        img = rgb555_to_rgba(raw.view("<u2").reshape(h, w16))
    elif bpp_mode == 3:  # 24-bit direct
        w = w16 * 2 // 3
        rgb = raw.reshape(h, w16 * 2)[:, : w * 3].reshape(h, w, 3)
        img = np.dstack([rgb, np.full((h, w), 255, np.uint8)])
    else:
        raise ValueError(f"unknown bpp mode {bpp_mode}")
    return img, pos - offset


def convert(path, out_dir):
    data = open(path, "rb").read()
    img, _ = parse_tim(data)
    name = os.path.splitext(os.path.basename(path))[0] + ".png"
    Image.fromarray(img, "RGBA").save(os.path.join(out_dir, name))
    return img.shape


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    paths = [src] if os.path.isfile(src) else [
        os.path.join(d, f) for d, _, fs in os.walk(src) for f in fs if f.upper().endswith(".TIM")]
    ok = 0
    for p in sorted(paths):
        try:
            convert(p, out); ok += 1
        except Exception as e:
            print(f"failed {p}: {e}")
    print(f"converted {ok}/{len(paths)}")
