# Arena Wheels engine (engine/)

Godot 4.7 project, Mobile renderer. Original procedural content only: menus, HUD, arena,
vehicles and sounds are this project's own. Content from the player's own disc is only read at
runtime from their own game-data folder (`GameData`); servers never serve or relay it.

The project is named "Arena Wheels" inside Godot (window title, user folder, export names). It was built for
the Twisted Metal (USA) remake: `GAME_SPECIFIC.md` lists which scripts are generic and which are that game's,
and `../games/twisted-metal/README.md` shows how to build the game-data folder it reads. Open it with
Godot 4.7.2; `Godot --headless --path engine --import` imports it without a window.

## Hosting a LAN game

One machine runs a dedicated headless server (no window, no local player):

    engine/host.sh [--data=PATH]         # = Godot --headless --path engine -- --server --port=8910 --http-port=8080 --https-port=8443

The server reads the arenas' collision from its own game-data folder (`--data`, else the saved
setting, else `../gamedata`); without game data it offers only the built-in Test Yard. A `--data`
folder without `manifest.json` stops it with an error.

It prints the address to open. Players then either

- open `https://<host-ip>:8443/` in Chrome (web build, served from `dist/web/` by the server).
  The first time, Chrome warns that the connection is not private: click **Advanced**, then
  **Proceed**, once. That one Proceed covers the game connection too, because the game connection
  uses the same address (see below). This warning is expected with a self-signed certificate on
  your own network. `http://<host-ip>:8080/` still works: it redirects to the https address; or
- start the desktop app, enter `<host-ip>:8910` and press Connect.

Why https: Chrome runs Godot web builds only in a secure context. `http://localhost` counts as
secure, but `http://<LAN ip>` does not, and Godot then stops with "Secure Context - Check web
server configuration (use HTTPS)". So the server:

- makes a self-signed certificate on first run (RSA 2048 key from Godot's `Crypto`), stores it in
  the Godot user folder under `tls/` (on macOS
  `~/Library/Application Support/Godot/app_userdata/Arena Wheels/tls/`), reuses it, and makes a
  new one when the LAN addresses change, it is about to expire, or it is from an older version
  without subjectAltName (`--tls-cert=PATH --tls-key=PATH` use your own files instead).
  Godot's `Crypto.generate_self_signed_certificate()` cannot add a subjectAltName, and Chrome
  checks names only against the subjectAltName, so `ServerTLS` writes the certificate itself
  (X.509 v3, signed with `Crypto.sign`): subject `CN=<LAN address>`, subjectAltName
  `DNS:localhost`, every LAN address, `127.0.0.1` and `::1`, extended key usage serverAuth. Chrome
  still warns once (nobody vouches for a self-signed certificate), but the names match, so a
  machine that chooses to trust the certificate (e.g. add `server.crt` to the macOS keychain as
  trusted) gets no warning at all. If the hand-written certificate ever fails to load, the
  server falls back to Godot's own (CN only) and says so in the log;
- serves the web build over HTTPS on `--https-port` (8443) and redirects plain http on
  `--http-port` (8080) to it;
- carries the browser's game connection on the page's own address: `wss://<host>:8443/ws`.
  Chrome's Proceed is an exception for the page's origin, and in real Chrome it did not carry
  over to a WebSocket on another port (the game port refused the connection: "Could not connect
  to localhost:8910", server log "mbedtls error: returned -0x7780"). The https server sees the
  WebSocket upgrade on `/ws` and forwards that connection, byte for byte in both directions, to
  the game's own WebSocket port on loopback (`127.0.0.1:8910`), so the game sees an ordinary
  WebSocket client: same binary protocol, same snapshots, same lobby code. It adds about one
  server frame (a few ms) of latency. `/server.json` gives the page `ws_url` =
  `wss://<host:port the page used>/ws` (plus `ws_port` for the fallback);
- still accepts `wss://` directly on the game port (8910), for desktop clients and as the page's
  fallback. If both the `/ws` address and the game port fail, the page shows a message with a
  link to `https://<host>:8910/` (accept the certificate there too; that tab then shows an error,
  which is expected) and a **Retry** button;
- desktop clients try `wss://` first (accepting the self-signed certificate, since there is no
  authority on a LAN to check it against) and fall back to `ws://`, so they connect to old and
  `--no-tls` servers as well. Typing `ws://host:port` or `wss://host:port` forces one;
  `wss://host:8443/ws` (the browsers' path) works from the desktop app too.

`--no-tls` turns all of this off (plain http on `--http-port`, plain ws, still with `/ws` on the
page's port): only for testing on the server machine itself at `http://localhost:8080/`.
`--no-ws-proxy` turns `/ws` off (browsers then use the game port directly, as before).

Game data by default: the desktop app uses the saved folder, else `../gamedata` beside the
project, and skips the game-data page when it finds a `manifest.json` there. In Chrome on the
server machine itself (`https://127.0.0.1:8443/` or the LAN address from that machine), the page
copies the server's game data into the browser by itself (no picker, music skipped to save
space) and goes straight on; it copies again when the server's manifest changes. The server
offers this only at `/local-gamedata/`, only to connections from 127.0.0.1 or ::1, and only for
`manifest.json` and the files it lists; every other client gets 403 there, and `/server.json`
shows `local_data` only to loopback clients. Other machines pick their own folder once; the copy
stays in that browser (IndexedDB). With game data a new lobby starts on the first disc arena,
players get disc vehicles, and the Test Yard sits last in the arena list as "Test Yard (built-in,
for testing)". Without game data the lobby and the match HUD show a banner saying so, and a lobby
on a disc arena says who lacks it and why Start is disabled. "Play without game data" is a small
link on the first screen and asks for confirmation.

The desktop app can also press **Start local server**: it launches the same headless server as a
separate process on this machine and connects to it. Browsers cannot host.

Flow (step rail on the left): game data (first launch) -> driver name and colour (remembered) ->
server -> lobby browser (auto-refreshes) -> create or join a lobby -> pick a vehicle (a turning
preview rendered at run time from your own game data, PgUp/PgDn to change) and press Ready ->
the lobby host picks the arena, score limit, time and bots and starts -> results -> lobby.
Keyboard: Tab/arrows, Enter, Esc back, F2 settings (texture quality, window/fullscreen, window
size up to 2560x1440, 3D render scale).

Content in a lobby: the arena id (`test_yard` or e.g. `WH/part1`) travels in the lobby settings
and the match start, so the server and every client build the same arena, each from its own game
data. Clients tell the server only which arena ids they can load; the host's list shows arenas
both the server and the host have, and Start is refused while a member lacks the arena. Vehicles
are ids (`builtin_1`..`builtin_8`, or game-data ids such as `ICE`): the 12 game-data vehicles are
offered when the server and the player both have game data, else the 8 built-in ones. Driving
numbers come from `engine/data/tuning.json` (measured numbers only, shipped with the game), so the
server and every client run the same profiles. If the host leaves,
the next player becomes host; empty lobbies close. Joining a lobby whose match is running puts you
straight into that match (you spawn after a short respawn delay; a bot makes room if needed).

Controls: W/S drive, A/D steer, Ctrl handbrake, Alt turbo, Space machine gun, Shift fire weapon,
Q/E change weapon, R unstuck, Tab scores, F3 network overlay, Esc menu.

## Web build

Export preset "Web" (threads off, so no SharedArrayBuffer and no cross-origin isolation needed)
to `dist/web/`. The server's HTTPS part serves that folder with the right types (`.wasm`
application/wasm, `.pck` application/octet-stream) and COOP/COEP headers, plus `/server.json`
(the game port and `ws_scheme`, wss by default). It answers 403 for any path that leaves the
folder, starts with a dot, or names a `gamedata/` or `cache/` folder; `/local-gamedata/` is the
loopback-only exception described under Hosting.

Game data on the web: the Game data page has **Choose folder...**. Chrome's
`showDirectoryPicker()` is used on secure origins (https, localhost); on a plain `http://<LAN ip>`
page Chrome hides it, so it falls back to `<input webkitdirectory>`. Only `manifest.json` and the
files it lists are copied into `user://gamedata` (IndexedDB). `GameData.read_bytes(rel_path)`
reads them the same way on desktop and web. "Skip music" avoids copying the large music files.

## Command line (after `--`)

Server: `--server --port=8910 --https-port=8443 --http-port=8080 (redirect to https; 0 alone =
no web serving) --no-tls --no-ws-proxy --tls-cert=PATH --tls-key=PATH --web-root=PATH --transport=enet --server-name=X`

Web page test automation: URL query keys `name`, `lobby`, `autostart`, `bots`, `arena`,
`time-limit`, `score-limit`, `autodrive`, `netstats`, `vehicle` act like the client flags, e.g.
`https://host:8443/?name=W1&lobby=T&autostart=1&bots=2&arena=test_yard&time-limit=20&autodrive`
(the page connects through `/ws`, joins or creates lobby T and starts a match).

Client automation (tests): `--connect=HOST:PORT --name=X --lobby=NAME --autostart=N --bots=N
--score-limit=N --time-limit=S --matches=N --autodrive --netstats --overlay --exit-after=S`

Network simulator (client, both directions): `--net-latency=MS` (one way) `--net-jitter=MS`
`--net-loss=PCT` `--net-loss-mode=hol|drop` (`hol` = TCP-style: a loss stalls the stream until
resent, default for WebSocket; `drop` = packet discarded, default for ENet). `--no-predict`.

Other: `--data=PATH` (game-data folder), `--verbose`, `--vehicle=ID`, `--arena=ID` (with
`--autostart` or `--solo`), `--no-disc-models`, `--upscale=1|2|4`, `--diag`,
`--vehicle-collision=hull|box|flat|capsule` (game-data vehicles; default hull).

Solo test: `Godot --headless --path engine -- --host --solo --arena=WH/part1 --time-limit=120 --autodrive`
starts a local server (with this machine's game data), a lobby with 7 bots, plays one match and
quits. The server log line `[server-match]` reports falls, bot resets, bot stuck events and the
distance each bot drove.

## Netcode

- Transport (`scripts/net/transport.gd`): WebSocketMultiplayerPeer by default for everyone, wss
  with the server's self-signed certificate (`--no-tls`: ws); ENet optional
  (`--transport=enet`, desktop only, no TLS). Raw byte packets, no RPCs.
- Server (`scripts/server/`): one process, one game port, many lobbies. Each lobby's match runs in
  its own SubViewport with its own World3D, so physics spaces and state are separate.
- Fixed 30 Hz simulation tick (physics_ticks_per_second = 30), snapshots at 20 Hz.
- Vehicles are kinematic (`CharacterBody3D` + `Vehicle.sim_step`), so the server and the client run
  the same step and the client can rewind and replay.
- Messages (`scripts/net/proto.gd`, `snapshot.gd`), all little endian:
  - `C_INPUT` (30/s): u8 type, u32 last snapshot tick received (ack), u32 render tick (for lag
    compensation), u32 newest input tick, u8 n=4, then n x (u8 buttons, i8 steer). 22 bytes.
    Buttons: accel, brake, handbrake, gun, fire, next, prev, turbo; accel+brake = unstuck.
  - `S_SNAP` (20/s): 22-byte header (tick, base tick, input ack, seq, flags, time, 32 pickup bits), the
    receiver's own vehicle at full precision (33 bytes: mm position, yaw, yaw rate, velocity,
    ammo, energy, heat, turbo, freeze), then only the vehicles and projectiles that changed since
    the base: per vehicle u8 slot + u8 mask + fields (position i16 x3 at 1/32 m, yaw u16, pitch/roll
    i8, health u8, state bits); per projectile u16 id + mask + fields. Delta against the client's
    last acknowledged snapshot; a full snapshot every 2 s or when the base is gone.
  - `S_EVENTS` (reliable, u16 sequence): kills, explosions, rams, specials, scores, match over.
  - `CTRL`: small JSON objects for the lobby (list, create, join, ready, settings, start).
  - `C_PING`/`S_PONG` for round-trip time.
- Server input handling: a short per-player input queue; one input per tick, two when the queue
  grows (catch up); if an input has not arrived the vehicle holds for that tick (keeps the server
  in step with the client's prediction); a lost input is replaced by the previous one.
- Client prediction: the local vehicle runs `sim_step` every tick; each snapshot carries the server
  state after the last input it applied; if it differs from what was predicted for that tick, the
  client resets to it, replays the newer inputs, and hides the jump with a decaying visual offset.
  `sim_step` always moves the car by exactly one tick, even when a replay runs outside a physics
  frame (`move_and_slide` otherwise uses the render-frame delta there). The R-key unstuck is replayed
  too. Debug with `--trace-pred` and `tests/net/pred_diff.py`.
- Remote vehicles and projectiles are interpolated in server time with an adaptive delay
  (snapshot spacing + measured jitter, 66-330 ms), extrapolating up to 0.25 s when packets stall.
- The shooter's missiles, mines and bolts appear immediately (predicted) and are swapped for the
  server's copy when it arrives; own tracers are drawn locally.
- Machine gun hits are checked on the server against where the shooter saw the target (rewind by
  the shooter's render tick, at most 200 ms).

The prediction NaN in the old code came from `Vehicle._integrate_forces`: the correction
accumulators (`_corr_pos`, `_corr_vel`, `_corr_rot`) were applied but never cleared, so every
later correction re-applied the whole sum (positive feedback until positions reached ~1e4 m), and
the accumulated quaternion was never normalised. The ack state was also sampled when the input
arrived instead of after it was applied.

## Gameplay numbers

`data/tuning.json` (this engine's copy of the Twisted Metal numbers, measured, see `games/twisted-metal/data/TUNING.md`) feeds `VehicleProfile`: constant turning
radius with yaw-rate ramp-in, handbrake turn multiplier and deceleration, health 100-140, turbo
(2 tanks x 3 s, x1.5 top speed, extra acceleration), machine gun (1 damage, 5 shots/s, heat 6 per
shot, locks at 200 until 100, cools 20/s), missiles (fire 7, homing 15, power 25, freeze stops the
target 3 s), mines 15, every weapon refires after 1.05 s, special energy 20 (+1 per 4.05 s).
Built-in stand-in vehicles keep their own original profiles and specials (bolt, salvo, flame,
shockwave, heavy shell) within those ranges. Ramming damage scales with closing speed and mass.

## Tests (headless)

- `tests/net/run_lobby.sh OUT PORT "A:8" 180 [client flags]` then `python3 -I tests/net/summary.py OUT`
- `Godot --headless --path engine res://scenes/tests/vehicle_tuning.tscn -- --disc`

Vehicle collision: built-in vehicles use a capsule. Game-data vehicles use a capsule sized to the
car for the ground contact plus the car's convex hull above 0.5 m (walls and other cars); the
server builds the same shapes from its own game data. `--quantize-state` (server and clients)
rounds the vehicle state to the owner snapshot's precision every tick (`Vehicle.quantize_state`);
it is off by default because it measured worse (Test Yard, 8 clients: 66% of corrections under
5 cm with it, 79% without).

Disc arenas: per-arena clear colour and a flat ground plane in that colour at the model's z = 0,
a flat collision floor there too (SUBURB's centre lot has no polygons), spatial splits drawn
inside/outside by camera (ROOF), pickups from `data_files` plus the pickups that sit in the wreck
states of destructible props (available from the start; props cannot be destroyed yet). Pickup
kinds by label; rear missile and rear flame stand in as fire missiles, oil as mines, unlabelled
icons give a random weapon.

Content seams: `Game.arena_provider` (ArenaProvider; optional meta "ramps" helps bots) and
`Game.vehicle_provider` (VehicleModelProvider).
