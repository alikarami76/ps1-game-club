# Generic container recipe

Runs the engine server (`engine/`) as one container behind any reverse proxy or platform ingress that adds
https and passes WebSocket upgrades: a home server with Caddy or nginx, a VPS, or a Kubernetes-style platform.
The image holds the web build and a deployment copy of **your own** game data, so friends' browsers need no
folder picker. Because of that the image contains material read from your disc: keep it in a private registry,
behind the access key, for your own club. Never push it anywhere public.

## Build

```bash
deploy/docker/assemble.sh --rebuild-web            # makes dist/docker/ (git-ignored)
docker build -t my-game-club dist/docker
# behind a registry mirror:  docker build --build-arg BASE=<mirror>/library/debian:trixie-slim -t my-game-club dist/docker
```

`assemble.sh` needs Godot 4.7.2 with the Linux and Web export templates (`GODOT=/path/to/godot` overrides
the default macOS path) and `ffmpeg` for the OGG music (`--ffmpeg=PATH`, or `--no-music`). It reads your game
data from `gamedata/` at the top of the repo (`--data=DIR` for another folder) and never changes it. The base
image is a build argument, `BASE`, defaulting to `debian:trixie-slim`.

## Run

```bash
python3 -c "import secrets;print(secrets.token_urlsafe(48))" > ~/.config/my-game-club.key   # keep it outside the repo
chmod 600 ~/.config/my-game-club.key
docker run -d --name game-club -p 8080:80 -e TM_ACCESS_KEY="$(cat ~/.config/my-game-club.key)" my-game-club
```

Put an https proxy in front of port 8080 (or let your platform's ingress do it). For a quick plain-http test on
one machine add `-e TM_PUBLIC_HTTPS=0` and open `http://localhost:8080/login?key=...`.

## How it works

- The Godot server runs headless in proxy mode (`--behind-proxy`, set by `TM_BEHIND_PROXY=1`). It speaks plain
  http on `$PORT` (80); the proxy in front adds https and passes WebSocket upgrades.
- The page connects to `wss://<host>/ws`, which the server forwards to its own game port. That port listens on
  127.0.0.1 only, inside the container. `TM_PUBLIC_HTTPS=1` (the default in the image) makes the page use `wss://`
  even when the proxy forwards `X-Forwarded-Proto: http`.
- **Access gate.** The server will not start without `TM_ACCESS_KEY` (at least 12 characters). Only `/healthz`
  (answers `ok`) and `/login` are public. Every other request (page, wasm, pck, `/server.json`, the `/ws`
  upgrade, game data) gets a plain 404 unless it carries the login cookie.
- `GET /login?key=<key>` compares the key in constant time, then sets the cookie `tm_session` (HttpOnly, Secure,
  SameSite=Strict, 30 days, value = HMAC-SHA256 of a fixed label under the key, so it never contains the key)
  and redirects to `/`. Five failed logins from one client in five minutes give 429 for that client.
- The key is read only from the environment and is never logged. The server log does not print query strings.
- Game data is served from `/local-gamedata/...` to cookie holders only. On the first visit the page copies it
  into the browser's storage, then plays as usual. The music is OGG Vorbis (about 128 kbps) in this copy,
  which keeps the Twisted Metal data near 50 MB.
- `start.sh` drops to the unprivileged user `tm` when the platform allows it, keeping only the right to bind a
  low port.

## Log in

Open `https://<your host>/login?key=<your key>` once per browser. The cookie lasts 30 days. The key sits in the
URL once, so it can appear in browser history and proxy access logs: clear the history entry, and rotate the key
if the link was shared anywhere.

## Rotate the key

Make a new key, restart the container with the new `TM_ACCESS_KEY`. Every old cookie stops working at once,
because the cookie is derived from the key.

## Update

A protocol change needs the web build and the server rebuilt together; `assemble.sh --rebuild-web` always does
both. Rebuild the image and restart the container.

## Test

`python3 engine/tests/net/gate_test.py --port=9930` starts its own headless server and checks that every route is
refused without the cookie, including the WebSocket upgrade, plus login, the rate limit and refusing to start
without a key.
