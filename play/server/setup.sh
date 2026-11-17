#!/bin/sh
# Fetch the pinned upstream files the club server needs. Safe to re-run.
#   ./setup.sh            install npm packages, fetch EmulatorJS (PS1 core only) and the netplay logic
#   ./setup.sh --skip-npm skip "npm install" (the Docker build does that separately)
# Needs: curl, a SHA-256 tool (sha256sum or shasum), and one of 7zz, 7z, 7za or bsdtar.
# Downloads about 300 MB once (the EmulatorJS release archive holds every core). Only the
# PS1 core and the player files are kept, in vendor/ (git-ignored). No game or BIOS is fetched.
set -eu
cd "$(dirname "$0")"
. ./versions.env

SKIP_NPM=0
[ "${1:-}" = "--skip-npm" ] && SKIP_NPM=1

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
need() { command -v "$1" >/dev/null 2>&1; }
need curl || { echo "curl is required"; exit 1; }

if [ "$SKIP_NPM" = 0 ]; then
  need npm || { echo "Node.js and npm are required (https://nodejs.org)"; exit 1; }
  npm install --omit=dev --no-audit --no-fund
fi

CACHE=.cache
mkdir -p "$CACHE" vendor/netplay

# 1. Netplay room logic (one small file, Apache-2.0).
echo "Fetching netplay logic $NETPLAY_VERSION ..."
curl -fsSL "$NETPLAY_FUNCTIONS_URL" -o vendor/netplay/functions.js.tmp
[ "$(sha256 vendor/netplay/functions.js.tmp)" = "$NETPLAY_FUNCTIONS_SHA256" ] || { echo "Hash mismatch for netplay functions.js"; rm -f vendor/netplay/functions.js.tmp; exit 1; }
mv vendor/netplay/functions.js.tmp vendor/netplay/functions.js
curl -fsSL "$NETPLAY_LICENSE_URL" -o vendor/netplay/LICENSE-Apache-2.0.txt || true

# 2. EmulatorJS release.
if [ -f vendor/emulatorjs/loader.js ] && [ -f vendor/emulatorjs/.version ] && [ "$(cat vendor/emulatorjs/.version)" = "$EJS_VERSION $EJS_SHA256" ]; then
  echo "EmulatorJS $EJS_VERSION already installed."
  echo "Done."; exit 0
fi

ARCHIVE="$CACHE/emulatorjs-$EJS_VERSION.7z"
if [ ! -f "$ARCHIVE" ] || [ "$(sha256 "$ARCHIVE")" != "$EJS_SHA256" ]; then
  echo "Downloading EmulatorJS $EJS_VERSION (about 300 MB) ..."
  i=0
  while :; do
    curl -fL --retry 5 --retry-all-errors -C - -o "$ARCHIVE" "$EJS_URL" && break
    i=$((i + 1)); [ "$i" -ge 10 ] && { echo "Download failed"; exit 1; }
    sleep 2
  done
fi
[ "$(sha256 "$ARCHIVE")" = "$EJS_SHA256" ] || { echo "Hash mismatch for the EmulatorJS archive. Delete $ARCHIVE and retry."; exit 1; }

TMP="$CACHE/extract"
rm -rf "$TMP"; mkdir -p "$TMP"
echo "Extracting the player and the PS1 core ..."
if need 7zz || need 7z || need 7za; then
  SZ=$(command -v 7zz || command -v 7z || command -v 7za)
  "$SZ" x -y -bso0 -bsp0 -o"$TMP" "$ARCHIVE" 'data/*' '-x!data/cores/*' >/dev/null
  "$SZ" x -y -bso0 -bsp0 -o"$TMP" "$ARCHIVE" 'data/cores/pcsx_rearmed*' 'data/cores/reports/pcsx_rearmed.json' >/dev/null
elif need bsdtar; then
  bsdtar -xf "$ARCHIVE" -C "$TMP" --exclude 'data/cores/*' 'data/*'
  bsdtar -xf "$ARCHIVE" -C "$TMP" 'data/cores/pcsx_rearmed*' 'data/cores/reports/pcsx_rearmed.json'
else
  echo "Install a 7-Zip tool (7zz, 7z or 7za; on Debian/Ubuntu: apt install 7zip or p7zip-full) or bsdtar."; exit 1
fi
[ -f "$TMP/data/loader.js" ] || { echo "Unexpected archive layout"; exit 1; }
[ -f "$TMP/data/cores/pcsx_rearmed-legacy-wasm.data" ] || { echo "PCSX-ReARMed core missing from archive"; exit 1; }

rm -rf vendor/emulatorjs
mv "$TMP/data" vendor/emulatorjs
echo "$EJS_VERSION $EJS_SHA256" > vendor/emulatorjs/.version
rm -rf "$TMP"
echo "Done. Start the club with:  npm start   (or docker compose up --build)"
