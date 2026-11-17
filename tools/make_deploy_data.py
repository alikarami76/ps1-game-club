"""Make a small deployment copy of gamedata/: the music WAVs become OGG Vorbis (~128 kbps).

Usage: python3 tools/make_deploy_data.py SRC_GAMEDATA OUT_DIR [--ffmpeg=PATH] [--bitrate=128k] [--no-music]

SRC_GAMEDATA is never changed. OUT_DIR gets a copy of every file except the music, the music
as .ogg, and a manifest.json whose audio.music list and checksums are rewritten the same way
games/twisted-metal/organize.py writes them (same sha1 function, same relative paths). The engine reads .ogg
music through WavLoader.load_ogg. Needs ffmpeg with libvorbis (or ffmpeg's own vorbis encoder).
"""
import json
import os
import shutil
import subprocess
import sys

import hashlib


def sha1(path):
    """Same checksum as games/twisted-metal/organize.py writes into manifest.json."""
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if len(args) != 2:
        sys.exit(__doc__)
    src, out = os.path.abspath(args[0]), os.path.abspath(args[1])
    no_music = "--no-music" in sys.argv   # tests only: leave the music out entirely (no encoder needed)
    ffmpeg = opts.get("ffmpeg") or shutil.which("ffmpeg")
    if not ffmpeg and not no_music:
        sys.exit("ffmpeg not found: install it (brew install ffmpeg) or pass --ffmpeg=PATH")
    bitrate = opts.get("bitrate", "128k")
    manifest = json.load(open(f"{src}/manifest.json"))
    music = manifest["audio"]["music"]
    if os.path.exists(out):
        shutil.rmtree(out)
    skip = {os.path.normpath(m) for m in music}
    for root, _, names in os.walk(src):
        for n in names:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, src)
            if rel == "manifest.json" or os.path.normpath(rel) in skip:
                continue
            os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
            shutil.copy2(p, os.path.join(out, rel))
    new_music = []
    for m in ([] if no_music else music):
        dest_rel = os.path.splitext(m)[0] + ".ogg"
        dest = os.path.join(out, dest_rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        # libvorbis if present, else ffmpeg's built-in vorbis encoder (needs -strict -2 on old builds)
        for codec in (["-c:a", "libvorbis", "-b:a", bitrate], ["-c:a", "vorbis", "-strict", "-2", "-b:a", bitrate]):
            r = subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", os.path.join(src, m), "-vn", *codec, dest])
            if r.returncode == 0:
                break
        else:
            sys.exit(f"ffmpeg could not encode {m}")
        new_music.append(dest_rel)
        print(f"{m} -> {dest_rel} ({os.path.getsize(dest) / 1e6:.1f} MB)")
    manifest["audio"]["music"] = new_music
    manifest["checksums"] = {}
    for root, _, names in os.walk(out):
        for n in names:
            p = os.path.join(root, n)
            if n != "manifest.json":
                manifest["checksums"][os.path.relpath(p, out)] = sha1(p)
    json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=2)
    total = sum(os.path.getsize(os.path.join(r, n)) for r, _, ns in os.walk(out) for n in ns)
    print(f"wrote {len(manifest['checksums'])} files, {total / 1e6:.1f} MB, to {out}")


if __name__ == "__main__":
    main()
