#!/bin/sh
# Starts the engine server behind a reverse proxy. Needs TM_ACCESS_KEY in the environment (the server also
# checks it). Runs the server as the unprivileged user "tm" when the platform lets this container switch user
# (it keeps only the right to bind a low port); otherwise it runs as the user it was started as and says so.
set -eu
PORT="${PORT:-80}"
if [ -z "${TM_ACCESS_KEY:-}" ]; then
  echo "start.sh: TM_ACCESS_KEY is not set. Pass it as an environment variable (docker run -e TM_ACCESS_KEY=...). Refusing to start." >&2
  exit 2
fi
export TM_BEHIND_PROXY=1 HOME=/home/tm
set -- /app/ArenaWheels.x86_64 --headless -- --server --port=8910 "--http-port=$PORT" --web-root=/app/web --data=/app/gamedata "--server-name=${TM_SERVER_NAME:-PS1 Game Club}"
if [ "$(id -u)" = "0" ] && setpriv --reuid=tm --regid=tm --init-groups --inh-caps=+net_bind_service --ambient-caps=+net_bind_service true 2>/dev/null; then
  echo "start.sh: running as user tm on port $PORT"
  exec setpriv --reuid=tm --regid=tm --init-groups --inh-caps=+net_bind_service --ambient-caps=+net_bind_service "$@"
fi
echo "start.sh: cannot switch to user tm here; running as uid $(id -u) on port $PORT"
exec "$@"
