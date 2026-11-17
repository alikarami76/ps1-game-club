#!/bin/bash
# Builds the PCSX-ReARMed libretro core from source into emu/pcsx_rearmed/ (git-ignored, never committed).
# tools/emu_harness.py loads it from there (or from $PS1_CORE).
#
#   tools/build_core.sh [--ref=COMMIT_OR_BRANCH] [--jobs=N]
#
# This is the same build the Twisted Metal example used: a shallow clone of
# https://github.com/libretro/pcsx_rearmed, its submodules, then `make -f Makefile.libretro`.
# Tested on macOS (Apple Silicon, platform=osx -> pcsx_rearmed_libretro.dylib). On Linux the
# Makefile picks the platform itself and writes pcsx_rearmed_libretro.so.
# Needs git, make and a C compiler (Xcode command line tools on macOS, build-essential on Debian).
# The core runs with its built-in HLE BIOS by default, so no BIOS file is needed or wanted here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/emu/pcsx_rearmed"
REPO=https://github.com/libretro/pcsx_rearmed
REF=""
JOBS=$( (sysctl -n hw.ncpu || nproc) 2>/dev/null || echo 4)
for a in "$@"; do case "$a" in
  --ref=*) REF="${a#--ref=}";;
  --jobs=*) JOBS="${a#--jobs=}";;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "unknown option $a" >&2; exit 2;; esac; done

mkdir -p "$ROOT/emu"
if [[ ! -d "$DEST/.git" ]]; then
  if [[ -n "$REF" ]]; then
    git clone "$REPO" "$DEST"
    git -C "$DEST" checkout "$REF"
  else
    git clone --depth 1 "$REPO" "$DEST"
  fi
elif [[ -n "$REF" ]]; then
  git -C "$DEST" fetch origin "$REF" && git -C "$DEST" checkout FETCH_HEAD
fi
git -C "$DEST" submodule update --init --depth 1

PLATFORM=()
[[ "$(uname -s)" == Darwin ]] && PLATFORM=(platform=osx)
make -C "$DEST" -f Makefile.libretro -j"$JOBS" ${PLATFORM[@]+"${PLATFORM[@]}"}
ls -la "$DEST"/pcsx_rearmed_libretro.* 
echo "built core in $DEST (commit $(git -C "$DEST" rev-parse --short HEAD))"
