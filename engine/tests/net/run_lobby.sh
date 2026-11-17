#!/bin/bash
# Headless network test: one dedicated server + N bot-driven clients over WebSocket.
# Usage: tests/net/run_lobby.sh OUT_DIR PORT "LOBBY:COUNT [LOBBY:COUNT ...]" SECONDS [extra client flags...]
# Example: tests/net/run_lobby.sh /tmp/t1 8920 "A:8" 180 --net-latency=50 --net-jitter=20 --net-loss=2
# Each client logs [netstats-final] (bytes/s, reconciliation error); the server logs per-lobby tick
# times ([server-match]) and totals ([server-stats]). Summarise with tests/net/summary.py OUT_DIR.
# SERVER_FLAGS=... adds flags to the server only (e.g. SERVER_FLAGS=--trace-pred, see pred_diff.py).
set -u
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=$1; PORT=$2; LOBBIES=$3; SECS=$4; shift 4
mkdir -p "$OUT"; rm -f "$OUT"/*.log
"$GODOT" --headless --path "$HERE" -- --server --port=$PORT --http-port=0 --exit-after=$((SECS + 40)) ${SERVER_FLAGS:-} > "$OUT/server.log" 2>&1 &
SRV=$!
sleep 2
PIDS=()
for spec in $LOBBIES; do
  L=${spec%%:*}; N=${spec##*:}
  for i in $(seq 1 $N); do
    "$GODOT" --headless --path "$HERE" -- --connect=127.0.0.1:$PORT --name="$L-p$i" --lobby="$L" \
      --autostart=$N --bots=0 --time-limit=$SECS --score-limit=999 --matches=1 --autodrive --netstats \
      --exit-after=$((SECS + 35)) "$@" > "$OUT/client_${L}_$i.log" 2>&1 &
    PIDS+=($!)
  done
done
wait "${PIDS[@]}"
sleep 1
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
echo "done: $OUT"
