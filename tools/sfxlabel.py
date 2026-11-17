"""Guess what each decoded sound effect is, from duration, envelope and spectrum only.

Usage: python3 -I tools/sfxlabel.py <sfx_dir>   (reads and updates <sfx_dir>/index.json)
Labels are rule-based guesses with a confidence between 0 and 1; none were checked by ear.
"""
import json
import os
import sys
import wave

import numpy as np


def features(path, rate=44100):
    w = wave.open(path)
    x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(float) / 32768
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    freq = np.fft.rfftfreq(len(x), 1 / rate)
    cum = np.cumsum(spec) / spec.sum()
    n = max(len(x) // 10, 1)
    env = np.array([np.sqrt((x[k * n:(k + 1) * n] ** 2).mean()) for k in range(10)])
    seg = x[len(x) // 4:len(x) // 4 + 4096]
    ac = np.correlate(seg, seg, "full")[len(seg) - 1:]
    hi = min(len(ac) - 1, 1500)
    lag = int(np.argmax(ac[40:hi])) + 40
    return dict(
        seconds=round(len(x) / rate, 3), rms=round(float(np.sqrt((x ** 2).mean())), 3),
        peak=round(float(abs(x).max()), 3),
        centroid_hz=int((spec * freq).sum() / spec.sum()),
        bw95_hz=int(freq[np.searchsorted(cum, 0.95)]),
        flatness=round(float(np.exp(np.log(spec + 1e-12).mean()) / spec.mean()), 4),
        periodicity=round(float(ac[lag] / ac[0]), 2),
        attack=round(float(env[:3].mean() / (env.max() + 1e-9)), 2),
        tail=round(float(env[-2:].mean() / (env.max() + 1e-9)), 2),
        rising=bool(env[:2].mean() < 0.5 * env[3:7].mean()))


def guess(f, looped):
    """Return (label, confidence)."""
    if looped:
        if f["seconds"] >= 1 and f["centroid_hz"] < 700:
            return "engine loop (low rumble, loops)", 0.55
        if f["seconds"] >= 0.5 and f["bw95_hz"] > 3000:
            return "sustained noise loop (flame, hiss or turbo)", 0.35
        if f["seconds"] >= 1:
            return "engine/motor loop (mid band)", 0.4
        return "short tonal loop (hum, UI tone or instrument)", 0.3
    if f["rising"] and f["seconds"] < 0.4:
        return "swell or power-up whoosh", 0.3
    if f["rising"]:
        return "rocket/missile whoosh (builds up)", 0.35
    if f["flatness"] > 0.02 and f["tail"] < 0.25 and f["seconds"] > 0.9:
        return "explosion (noise burst with long decay)", 0.55
    if f["flatness"] > 0.02 and f["tail"] < 0.25:
        return "short impact or ricochet (bright noise decay)", 0.4
    if f["flatness"] > 0.02:
        return "steady noise (machine-gun burst, flame or steam)", 0.35
    if f["periodicity"] > 0.4 and f["centroid_hz"] < 1500:
        return "pitched tone (horn, siren, beep or instrument)", 0.3
    if f["tail"] < 0.15 and f["seconds"] > 0.4:
        return "gun/cannon shot or thud (dark decay)", 0.4
    return "unclassified sound", 0.15


def main(sfx_dir):
    path = os.path.join(sfx_dir, "index.json")
    ix = json.load(open(path))
    for i, s in ix["samples"].items():
        f = features(os.path.join(sfx_dir, s["file"]))
        label, conf = guess(f, s["loop_end"] is not None)
        s.update(label=label, confidence=conf, features=f)
        print(i, s["file"], label, conf)
    for p in ix["programs"].values():
        labs = [ix["samples"][str(t["vag"])] for t in p["tones"] if str(t["vag"]) in ix["samples"]]
        if labs:
            best = max(labs, key=lambda s: s["confidence"])
            p["label"], p["confidence"] = best["label"], round(best["confidence"] * 0.8, 2)
    json.dump(ix, open(path, "w"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
