#!/bin/sh
# Host a RetroArch netplay game (macOS and Linux).
#   ./host.sh "/path/to/Game.cue" [your-name] [port]
# Friends then run join.sh with your address. Netplay shares controller input:
# it works for games that already have a local 2+ player mode.
case "${1:-}" in -h|--help|"") sed -n '2,5p' "$0"; exit 0;; esac
. "$(dirname "$0")/_common.sh"
GAME="$1"; NICK="${2:-Host}"; PORT="${3:-55435}"
prepare
echo "Hosting on port $PORT (TCP). Friends join with:  ./join.sh <your-address> \"their-copy-of-the-game\" [name] $PORT"
# shellcheck disable=SC2086
exec $RA -L "$CORE" --appendconfig "$here/netplay.cfg" --host --port "$PORT" --nick "$NICK" "$GAME"
