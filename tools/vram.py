"""Emulate PS1 video memory (1024x512 16-bit words) and sample textures from it."""
import struct

import numpy as np

from tim import rgb555_to_rgba


class VRAM:
    def __init__(self):
        self.mem = np.zeros((512, 1024), np.uint16)

    def upload(self, x, y, w, h, words):
        self.mem[y:y + h, x:x + w] = np.frombuffer(words, "<u2", w * h).reshape(h, w)

    def load_tim(self, data, off=0):
        flags = struct.unpack_from("<I", data, off + 4)[0]
        pos = off + 8
        for _ in range(2 if flags & 8 else 1):
            blen, x, y, w, h = struct.unpack_from("<IHHHH", data, pos)
            self.upload(x, y, w, h, data[pos + 12:pos + 12 + w * h * 2])
            pos += blen

    def load_tms(self, path):
        data = open(path, "rb").read()
        if data[:5] != b"TXSPC":
            raise ValueError("not a TMS file")
        count = struct.unpack_from("<I", data, 12)[0]
        pos = 16
        for _ in range(count):
            size = struct.unpack_from("<I", data, pos)[0]
            self.load_tim(data, pos + 4)
            pos += 4 + size

    def page(self, tpage, clut):
        """Decode one 256x256 texture page with its palette to RGBA (0x0000 = transparent)."""
        return rgb555_to_rgba(self.page_raw(tpage, clut))

    def page_raw(self, tpage, clut):
        """Return one 256x256 texture page as 16-bit PS1 colours (bit 15 = semi-transparency).

        tpage bits: 0-3 x base (64-word units), 4 y base (256 lines), 5-6 blend mode,
        7-8 colour mode (0 = 4-bit, 1 = 8-bit with palette, 2 = 15-bit direct).
        clut: palette position, x = (clut & 63) * 16, y = clut >> 6.
        """
        bx, by, mode = (tpage & 15) * 64, ((tpage >> 4) & 1) * 256, (tpage >> 7) & 3
        cx, cy = (clut & 63) * 16, (clut >> 6) & 511
        u = np.arange(256)
        rows = self.mem[by:by + 256]
        if mode == 0:
            words = rows[:, (bx + u // 4) % 1024]
            idx = (words >> ((u % 4) * 4)) & 15
            px = self.mem[cy, cx + idx]
        elif mode == 1:
            words = rows[:, (bx + u // 2) % 1024]
            idx = (words >> ((u % 2) * 8)) & 255
            px = self.mem[cy, (cx + idx) % 1024]
        else:
            px = rows[:, (bx + u) % 1024]
        return px


def window(u, v, texwin):
    """Apply a texture window (mask_u, mask_v, offset_u, offset_v) to texel coordinates.

    Works on ints or numpy arrays. The GPU wraps u to (u & ~mask_u) | (offset_u & mask_u).
    """
    if texwin is None:
        return u, v
    mu, mv, ou, ov = texwin
    return (u & ~mu & 255) | (ou & mu), (v & ~mv & 255) | (ov & mv)


BLEND_MODES = ("average", "add", "subtract", "add_quarter")  # tpage bits 5-6


def blend_mode(tpage):
    """Semi-transparency mode of a texture page word: 0 = B/2+F/2, 1 = B+F, 2 = B-F, 3 = B+F/4."""
    return (tpage >> 5) & 3 if tpage is not None else 0
