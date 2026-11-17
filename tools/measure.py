"""Measure per-vehicle driving values from the player's own disc in the headless emulator.

Writes data/tuning.json. The game logic updates once every 3 emulator frames
(20 ticks per second). Units: distance in game world units, time in ticks,
angles in degrees.
"""
import json
import math
import os

import numpy as np

import emu_harness as E
import nav

STATE_DIR = "../cache/emu"
POS_X, POS_Z = 0x1A1B24, 0x1A1B28  # player vehicle world x, y (int32; vehicle struct 0x801A179C +0x388/+0x38C)
HEADING = 0x1A1B44  # player heading (int32, 4096 = one turn, unwrapped; struct +0x3A8). LEFT lowers it.
SPEED = 0x1A1B34  # forward speed, 1/32 world unit per tick
# 0x80191768/0x8019176C (used before) is the camera view-space translation, not world position.
VEHICLE_IDS = ["ICE", "CAB", "SEMI", "COP", "LOWRIDER", "LAMBO",
               "DUNEB", "HUMVEE", "HARLEY", "VETTE", "MONSTERT", "MADMAX"]  # select-screen order


def pos(emu):
    r = emu.ram().view("<i4")
    return np.array([r[POS_X // 4], r[POS_Z // 4]], float)


def start_match(emu, k):
    emu.load_state(f"{STATE_DIR}/after_nav1.state")
    emu.run(4, ["B"]); emu.run(60)
    for _ in range(k):
        emu.run(4, ["RIGHT"]); emu.run(40)
    emu.screenshot(f"{STATE_DIR}/select_{k:02d}.png")
    emu.run(4, ["B"]); emu.run(90)
    emu.run(4, ["B"]); emu.run(180)
    emu.run(4, ["B"]); emu.run(360)
    emu.save_state(f"{STATE_DIR}/match_{k:02d}.state")


FRAMES_PER_TICK = 3


def align(emu):
    """Advance to just after a game tick so later samples land on tick boundaries."""
    before = pos(emu)
    for _ in range(FRAMES_PER_TICK):
        emu.run(1, ["UP"])
        if (pos(emu) != before).any():
            return


def drive(emu, ticks, buttons):
    path = [pos(emu)]
    for _ in range(ticks):
        emu.run(FRAMES_PER_TICK, buttons)
        path.append(pos(emu))
    return np.array(path)


def speeds(path):
    return np.hypot(*np.diff(path, axis=0).T)


def yaw(emu):
    return int(emu.ram().view("<i4")[HEADING // 4])


def turn_rate(emu, ticks, buttons):
    """Mean |heading change| in degrees per tick over the last half of `ticks` ticks."""
    ys = [yaw(emu)]
    for _ in range(ticks):
        emu.run(FRAMES_PER_TICK, buttons)
        ys.append(yaw(emu))
    d = np.diff(np.array(ys, float))
    d[d > 2048] -= 4096
    d[d < -2048] += 4096
    return float(np.abs(d[ticks // 2:]).mean() * 360 / 4096)


def measure(emu, k):
    state = f"{STATE_DIR}/match_{k:02d}.state"
    out = {}
    # acceleration to top speed
    emu.load_state(state); align(emu)
    v = speeds(drive(emu, 70, ["UP"]))
    top = float(np.median(v[50:70]))
    out["top_speed_per_tick"] = round(top, 2)
    out["accel_curve_per_tick"] = [round(float(x), 2) for x in v[:50]]
    out["ticks_to_90pct"] = int(np.argmax(v > 0.9 * top))
    # braking from speed
    emu.load_state(state); align(emu); drive(emu, 50, ["UP"])
    vb = speeds(drive(emu, 40, ["DOWN"]))
    out["ticks_to_stop"] = int(np.argmax(vb < 1.0)) if (vb < 1.0).any() else None
    # coasting (no input) from speed
    emu.load_state(state); align(emu); drive(emu, 50, ["UP"])
    vc = speeds(drive(emu, 60, []))
    out["ticks_to_stop_coasting"] = int(np.argmax(vc < 1.0)) if (vc < 1.0).any() else None
    # reverse top speed
    emu.load_state(state); align(emu)
    vr = speeds(drive(emu, 60, ["DOWN"]))
    out["reverse_speed_per_tick"] = round(float(np.median(vr[40:60])), 2)
    # turning at full speed and from low speed
    emu.load_state(state); align(emu); drive(emu, 45, ["UP"])
    out["turn_deg_per_tick_fast"] = round(turn_rate(emu, 15, ["UP", "LEFT"]), 2)
    emu.load_state(state); align(emu); drive(emu, 6, ["UP"])
    out["turn_deg_per_tick_slow"] = round(turn_rate(emu, 12, ["UP", "LEFT"]), 2)
    return out


if __name__ == "__main__":
    emu = E.Emulator(nav.CUE)
    results = {}
    for k, vid in enumerate(VEHICLE_IDS):
        if not os.path.exists(f"{STATE_DIR}/match_{k:02d}.state"):
            start_match(emu, k)
        results[vid] = measure(emu, k)
        print(vid, results[vid], flush=True)
    os.makedirs("../data", exist_ok=True)
    json.dump({"units": {"distance": "game world units", "time": "game ticks (20 per second, 3 emulator frames each)",
                         "angle": "degrees"},
               "vehicles": results}, open("../data/tuning.json", "w"), indent=2)
