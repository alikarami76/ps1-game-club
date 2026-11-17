#!/bin/bash
# Host a LAN game: dedicated headless server + the web build over HTTPS. No window opens.
#   ./host.sh [GAME_PORT] [HTTP_PORT] [HTTPS_PORT] [--data=PATH] [--no-tls] [other server flags]
#        (defaults 8910, 8080 and 8443; game data defaults to the saved setting or ../gamedata)
# Chrome only runs the web build in a secure context, and http://<LAN address> is not one, so the
# server serves the page over https (HTTPS_PORT) with a self-signed certificate it makes on first
# run (subjectAltName localhost + the LAN addresses; kept in the Godot user folder, tls/, and made
# again when the addresses change). The browser's game connection uses the page's own address
# (wss://<address>:HTTPS_PORT/ws, forwarded inside the server to GAME_PORT), so one "Proceed" on
# the certificate warning covers both. http://<address>:HTTP_PORT/ redirects to the https page.
# Desktop clients connect to <address>:GAME_PORT as before.
# --no-tls: plain http and ws, only for testing on this machine (http://localhost:HTTP_PORT/).
# --data=PATH is the game-data folder made from your own disc (the one holding manifest.json).
# The server needs it for the arenas' collision; only a browser on this same machine may load it
# (to skip picking the folder); other machines never get it. A --data folder without
# manifest.json stops the server with an error. Ctrl+C stops the server.
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME_PORT=8910
HTTP_PORT=8080
HTTPS_PORT=8443
if [[ $# -gt 0 && "$1" != --* ]]; then GAME_PORT=$1; shift; fi
if [[ $# -gt 0 && "$1" != --* ]]; then HTTP_PORT=$1; shift; fi
if [[ $# -gt 0 && "$1" != --* ]]; then HTTPS_PORT=$1; shift; fi
NO_TLS=0
ARGS=()
for a in "$@"; do
  if [[ "$a" == --data=* ]]; then
    d="${a#--data=}"; d="${d/#\~/$HOME}"
    if [[ ! -f "$d/manifest.json" ]]; then
      echo "host.sh: no manifest.json in '$d'. Point --data at your game-data folder (made with games/twisted-metal/organize.py)." >&2
      exit 2
    fi
    a="--data=$(cd "$d" && pwd)"   # absolute: Godot runs from the project folder
  fi
  [[ "$a" == --no-tls ]] && NO_TLS=1
  ARGS+=("$a")
done
LAN_IP=$( (ipconfig getifaddr en0 || ipconfig getifaddr en1 || hostname -I 2>/dev/null | awk '{print $1}') 2>/dev/null | head -1)
LAN_IP=${LAN_IP:-<this machine\'s LAN address>}
echo
if [[ $NO_TLS == 1 ]]; then
  echo "--no-tls: open http://localhost:$HTTP_PORT/ in Chrome on this machine only. Other machines need the default (https) mode."
else
  echo "Open https://$LAN_IP:$HTTPS_PORT/ in Chrome (on this machine https://localhost:$HTTPS_PORT/ works too)."
  echo "The first time, Chrome warns that the connection is not private: click Advanced, then Proceed, once."
  echo "That is expected with a self-signed certificate on your own network, and it covers the game connection too"
  echo "(the game runs over wss://$LAN_IP:$HTTPS_PORT/ws, the page's own address). If you used an older version of"
  echo "this server, reload the page: the certificate is new and Chrome asks once more."
  echo "Desktop players connect to $LAN_IP:$GAME_PORT."
fi
echo
exec "$GODOT" --headless --path "$HERE" -- --server --port=$GAME_PORT --http-port=$HTTP_PORT --https-port=$HTTPS_PORT --web-root="$HERE/../dist/web" ${ARGS[@]+"${ARGS[@]}"}
