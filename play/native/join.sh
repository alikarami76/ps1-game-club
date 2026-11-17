#!/bin/sh
# Join a RetroArch netplay host (macOS and Linux).
#   ./join.sh <host-address> "/path/to/Game.cue" [your-name] [port]
# Use the same game (same dump) and the same RetroArch and core versions as the host.
case "${1:-}" in -h|--help|"") sed -n '2,5p' "$0"; exit 0;; esac
. "$(dirname "$0")/_common.sh"
HOSTADDR="$1"; GAME="${2:-}"; NICK="${3:-Guest}"; PORT="${4:-55435}"
prepare
# shellcheck disable=SC2086
exec $RA -L "$CORE" --appendconfig "$here/netplay.cfg" --connect "$HOSTADDR" --port "$PORT" --nick "$NICK" "$GAME"
