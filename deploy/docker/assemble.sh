#!/bin/bash
# Assembles a Docker build context (default: dist/docker/ in this repo, git-ignored) from the engine and your
# own game data:
#   - Linux x86_64 server binary (Godot export of engine/, .pck embedded) -> app/
#   - web build -> web/   (the existing dist/web/, or a fresh export with --rebuild-web)
#   - deployment game data -> gamedata/  (tools/make_deploy_data.py; OGG music needs ffmpeg, or --no-music)
#   - Dockerfile and start.sh from this folder
# Usage: deploy/docker/assemble.sh [--rebuild-web] [--no-music] [--data=DIR] [--out=DIR] [--ffmpeg=PATH]
# Then: docker build -t my-game-club "$OUT"   (add --build-arg BASE=<mirror>/debian:trixie-slim to use a mirror)
# Needs Godot 4.7.2 with the Linux and Web export templates ($GODOT overrides the binary path).
# The output holds your own game data: never push it to a public repository or registry.
# No access key is read or written here; set TM_ACCESS_KEY on the running container.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
OUT="$PROJ/dist/docker"
DATA="$PROJ/gamedata"
REBUILD_WEB=0; NO_MUSIC=0; FFMPEG_ARG=()
for a in "$@"; do case "$a" in
  --rebuild-web) REBUILD_WEB=1;; --no-music) NO_MUSIC=1;; --out=*) OUT="${a#--out=}";; --data=*) DATA="${a#--data=}";;
  --ffmpeg=*) FFMPEG_ARG=("$a");;
  *) echo "unknown option $a" >&2; exit 2;; esac; done
[[ -f "$DATA/manifest.json" ]] || { echo "no manifest.json in $DATA (build it from your disc first, see games/)" >&2; exit 2; }
mkdir -p "$OUT/app" "$OUT/web" "$OUT/gamedata"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. snapshot of the project (so a running edit cannot half-land in the export), then the exports
rsync -a --exclude tests --exclude .godot "$PROJ/engine/" "$WORK/engine/"
mkdir -p "$WORK/dist"
"$GODOT" --headless --path "$WORK/engine" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$WORK/engine" --export-release "Linux" "$WORK/dist/ArenaWheels.x86_64" 2>&1 | tail -3
[[ -x "$WORK/dist/ArenaWheels.x86_64" ]] || { echo "Linux export failed" >&2; exit 1; }
cp "$WORK/dist/ArenaWheels.x86_64" "$OUT/app/ArenaWheels.x86_64"
if [[ $REBUILD_WEB == 1 || ! -f "$PROJ/dist/web/index.html" ]]; then
  mkdir -p "$WORK/dist/web"
  "$GODOT" --headless --path "$WORK/engine" --export-release "Web" "$WORK/dist/web/index.html" 2>&1 | tail -3
  rm -rf "$OUT/web"; mkdir -p "$OUT/web"; cp "$WORK/dist/web/"* "$OUT/web/"
else
  rm -rf "$OUT/web"; mkdir -p "$OUT/web"; cp "$PROJ/dist/web/"* "$OUT/web/"
fi
# 2. deployment game data (your gamedata/ is only read)
if [[ $NO_MUSIC == 1 ]]; then
  python3 "$PROJ/tools/make_deploy_data.py" "$DATA" "$OUT/gamedata" --no-music
else
  python3 "$PROJ/tools/make_deploy_data.py" "$DATA" "$OUT/gamedata" ${FFMPEG_ARG[@]+"${FFMPEG_ARG[@]}"}
fi
# 3. container files
cp "$HERE/Dockerfile" "$HERE/start.sh" "$OUT/"
printf '.git\n.gitignore\n.env\n*.key\n' > "$OUT/.dockerignore"
echo "assembled $OUT"; du -sh "$OUT"/app "$OUT"/web "$OUT"/gamedata
