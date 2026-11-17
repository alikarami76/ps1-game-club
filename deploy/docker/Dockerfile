# ps1-game-club engine server in one container: the headless Godot server, the web build and your own
# game data, plain http on $PORT (default 80) behind a reverse proxy or platform ingress that adds https.
# The Godot headless binary needs only libc, so no graphics or sound libraries are installed.
# Everything the image needs is in the build context made by assemble.sh (Linux server binary with its
# .pck embedded, the web build, a deployment copy of YOUR game data), so the build downloads nothing but
# the base image.
#
# The image holds game data read from your own disc: keep it in a private registry and never publish it.
#
# The server refuses to start without TM_ACCESS_KEY (at least 12 characters), which you set as an
# environment variable on the container at run time. It is never baked into the image or committed.
# Every path except /healthz and /login needs the login cookie. See README.md.
ARG BASE=debian:trixie-slim
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
# no apt-get: groupadd/useradd (passwd) and setpriv (util-linux) are already in the slim image
RUN groupadd -g 1001 tm && useradd -u 1001 -g tm -m -s /usr/sbin/nologin tm

WORKDIR /app
# slowest-changing first: the data and the web build, then the server binary, then the start script
COPY gamedata/ /app/gamedata/
COPY web/ /app/web/
COPY app/ArenaWheels.x86_64 /app/ArenaWheels.x86_64
COPY start.sh /app/start.sh
RUN chmod 755 /app/ArenaWheels.x86_64 /app/start.sh

# TM_PUBLIC_HTTPS=1 tells the page to use wss:// when the proxy ends TLS and forwards plain http.
# Set it to 0 if you serve the container over plain http only (local tests).
ENV TM_BEHIND_PROXY=1 TM_PUBLIC_HTTPS=1 PORT=80 HOME=/home/tm
EXPOSE 80
# No HEALTHCHECK: the slim image has no curl. Point your platform's probe at GET /healthz (answers "ok").
# The server is PID 1 (start.sh execs it).
ENTRYPOINT ["/app/start.sh"]
