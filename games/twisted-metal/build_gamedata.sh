#!/bin/bash
# Builds gamedata/ (the folder the engine reads) from YOUR OWN Twisted Metal (USA) disc image.
#   games/twisted-metal/build_gamedata.sh "/path/to/Twisted Metal (USA).cue" [cache_dir] [gamedata_dir]
# Defaults: cache/ and gamedata/ at the top of the repo (both git-ignored). Nothing is downloaded or uploaded.
# Steps: tools/disc.py (extract the disc), tools/vab.py (decode the sound bank), tools/sfxlabel.py (label the
# sounds), organize.py (pick and sort the files, write manifest.json with a SHA-1 per file).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CUE="${1:?usage: build_gamedata.sh /path/to/game.cue [cache_dir] [gamedata_dir]}"
CACHE="${2:-$ROOT/cache}"
OUT="${3:-$ROOT/gamedata}"
python3 -I "$ROOT/tools/disc.py" "$CUE" "$CACHE"
python3 -I "$ROOT/tools/vab.py" "$CACHE/files/SND/UACORE.VAB" "$CACHE/sfx"
python3 -I "$ROOT/tools/sfxlabel.py" "$CACHE/sfx" > /dev/null
python3 -I "$ROOT/games/twisted-metal/organize.py" "$CACHE" "$OUT"
echo "done: point the engine at $OUT (engine/host.sh --data=$OUT)"
