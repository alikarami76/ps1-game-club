"""Scripted menu navigation helpers for the headless emulator."""
import os
import sys
import numpy as np
from PIL import Image
import emu_harness as E

# Path to your own disc image (.cue). Set PS1_CUE, e.g. PS1_CUE="/path/to/Game.cue" python3 measure.py
CUE = os.environ.get("PS1_CUE", "")


def sheet(frames, path, cols=4):
    h, w = frames[0][1].shape[:2]
    rows = (len(frames) + cols - 1) // cols
    out = Image.new("RGB", (cols * w, rows * (h + 12)), (0, 0, 0))
    from PIL import ImageDraw
    d = ImageDraw.Draw(out)
    for i, (label, f) in enumerate(frames):
        x, y = (i % cols) * w, (i // cols) * (h + 12)
        out.paste(Image.fromarray(f), (x, y + 12))
        d.text((x + 2, y), label, fill=(255, 255, 0))
    out.save(path)


def run_script(emu, steps, snap_every=True):
    """steps: list of (button or None, hold, after)."""
    shots = []
    for i, (btn, hold, after) in enumerate(steps):
        if btn:
            emu.run(hold, [btn])
        emu.run(after)
        if snap_every:
            shots.append((f"{i}:{btn} f{emu.frames_run}", emu.frame.copy()))
    return shots
