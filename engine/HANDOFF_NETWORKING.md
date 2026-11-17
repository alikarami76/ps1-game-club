# Networking rework: handoff (paused 2026-11-15)

## Update 2026-11-16 (lobby defaults, tournament mode, driving state in the snapshot; protocol 7)

- Lobby defaults: on a disc arena "fill with bots" starts at 1 (the original's level 1 is one opponent), on the built-in
  yard at 4; the host can still change it (once changed it stays, even when the arena changes). Difficulty defaults to
  "normal" (`easy|normal|hard`). New setting `pickup_respawn` = 30, 60 or 96 s (default 96, the original's measured
  value; other numbers snap to the nearest option); used in deathmatch, a tournament always uses 96.
- Tournament mode (`settings.mode == "tournament"`, one human only; `Lobby.is_full()` is true at one member, and
  switching a lobby with more than one member to tournament is refused with an error). Level 1 comes from
  `Tournament.start_settings()`. When a level ends the lobby reads `match.tour_result`: won and a next level exists ->
  `Lobby.on_match_finished` starts the next level at once (same lobby, a new `match_start` with `settings.level`,
  `lives_left`, `difficulty` and arena of that level); lost or all six levels won -> `match_end` (with
  `"tour": {won, level, finished}`, stored as `Net.tour_last`) and the lobby is reset to a fresh tournament (level 1,
  4 lives). The host's difficulty choice is kept for every level; without one each level uses its own.
- API for the menu: `Net.create_tournament(difficulty := "normal", start := true)`, which is
  `Net.create_lobby({"name": "Tournament", "mode": "tournament", "difficulty": difficulty, "start": true})`.
  `Net.create_lobby(arg, settings := {})` takes either a name (as before) or a Dictionary: `name`, `start` (start at
  once; needs the arena, so XARENA game data), `settings` and any other key as a setting (`mode`, `difficulty`,
  `pickup_respawn`, `arena`, `bots`, `score_limit`, `time_limit`, `level` for a tournament test start). The server's
  `create` message takes the same `settings` and `start`. Without game data the start fails with the usual "cannot load
  this arena" error message (`Net.error_message`).
- Headless test: `tests/net/run_lobby.sh OUT PORT "T:1" 150 --mode=tournament [--level=N] [--difficulty=easy]` (the
  clients' `--mode/--level/--difficulty/--pickup-respawn` flags are sent as lobby settings; the server's old `--mode`
  hook in match.gd is gone).
- Prediction state: the owner block of S_SNAP now carries the `_drive_tick` state: i16 signed speed (1/4 raw unit),
  i16 steering angle (1/16), u16 travel yaw, u8 stop ticks, and two flag bits (sliding, reverse mode) = +7 bytes (40
  in all). `_reconcile` restores it with `set_state(own)` (it used to copy the state from the client's own history and
  re-derive speed from the velocity) and treats a drive-state mismatch like a position mismatch. `Proto.VERSION` = 7.

## Update 2026-11-16 (real Chrome: game connection on the page's own address)

- Bug: in real Chrome, `https://localhost:8443/` + Advanced > Proceed loaded the page, but the
  game's `wss://localhost:8910` failed ("Could not connect to localhost:8910"; server log
  "mbedtls error: returned -0x7780", i.e. Chrome sent a fatal alert). The Proceed exception did
  not cover a WebSocket on another port, and the certificate had no subjectAltName. Earlier tests
  used `ignore_https_errors`, so they never saw a certificate check. (Headless Chrome with a
  fresh profile did let the other port through after `thisisunsafe`, so the exact rule differs
  between builds; the fix below does not depend on it.)
- Fix 1, one origin: `WebFileServer` answers a WebSocket upgrade on `/ws` (on the https port, and
  on the http port with `--no-tls`) by connecting to `127.0.0.1:<game port>` (wss with
  `TLSOptions.client_unsafe()`, or ws with `--no-tls`), sending a clean upgrade request (only the
  WebSocket headers) and then copying bytes both ways. The game's WebSocketMultiplayerPeer sees an
  ordinary client, so protocol, snapshots and lobby code are unchanged. Godot 4.7 has no public
  way to hand an accepted stream to WebSocketMultiplayerPeer, which is why it is a forwarder and
  not `WebSocketPeer.accept_stream`. Forwarding runs in `_process` and `_physics_process`
  (priority 100, after Transport) and calls `GameServer`'s `transport.poll()` right after bytes
  go upstream, so inputs and pongs are handled in the same frame. Measured with two headless
  desktop clients on this machine: RTT 15 ms through `/ws` against 8 ms direct; with Chrome
  (swiftshader) the RTT is the same either way (about 200-400 ms, set by the slow software
  renderer, not by the network). `/server.json` adds `ws_path` and `ws_url`
  (`wss://<Host header>/ws`). `--no-ws-proxy` turns it off.
- Web client (`Net.web_connect`): tries `ws_url` first, then `wss://<host>:<ws_port>`; if both
  fail, `web_connect_failed(cert_url)` makes the server page show a message, a link to
  `https://<host>:<ws_port>/` to accept the certificate there, and Retry. `connect_to_server`
  now keeps a URL path (`wss://host:8443/ws` works from the desktop app too).
- Fix 2, certificate: `ServerTLS` writes the X.509 v3 DER itself and signs it with
  `Crypto.sign` (Godot's `generate_self_signed_certificate` cannot add extensions):
  subjectAltName `DNS:localhost`, each LAN address, 127.0.0.1, ::1; CA:FALSE; key usage;
  serverAuth. Checked with openssl 3 (`verify -partial_chain -check_ss_sig`: OK) and Python
  `cryptography` (signature OK). Meta `format: 2` + the SAN list; older certificates are
  replaced on the next start, so players Proceed once more after the upgrade. Falls back to the
  CN-only certificate if loading the hand-written one fails.
- Also fixed: `/server.json` and `/local-gamedata/` did not treat a browser on `localhost` as
  loopback when Chrome connected over IPv6 (`get_connected_host()` returns `0:0:0:0:0:0:0:1`, not
  `::1`), so `https://localhost:8443/` never auto-imported the server's game data.
- Web test hook: page URL query keys (`name`, `lobby`, `autostart`, `bots`, `arena`, `time-limit`,
  `score-limit`, `autodrive`, `netstats`, `vehicle`) act like the client flags (`Game._web_args`).
- Tested with real certificate checks (Python Playwright, `channel="chrome"`, headless,
  swiftshader, no `ignore_https_errors`, fresh profile): first load fails with
  `net::ERR_CERT_AUTHORITY_INVALID`, typing `thisisunsafe` on the interstitial (one Proceed),
  then the page connects to `wss://<same host>:<port>/ws`, joins a lobby, plays a 20 s test_yard
  match with a bot and returns to the lobby, 0 console errors, for `https://localhost:9443/`
  (auto-imported 93 files first), `https://<LAN ip>:9443/` and `https://127.0.0.1:9443/`; about
  21-28 snapshots/s received. `--no-tls` `http://localhost/` also plays over `ws://.../ws`.
  Fallback: an ENet server (no WebSocket at all) makes the page show the message, the link and
  Retry. Desktop headless client by LAN ip on 8910 (wss) and via `wss://127.0.0.1:9443/ws` both
  play a match. run_lobby 8 clients, test_yard, 90 s: 93.2% of corrections < 5 cm, 0.10% >= 1 m,
  0 errors (one 646 ms tick spike while ten Godot processes started at once).
- Expected log noise: each first visit logs a few "mbedtls error: returned -0x7780" / "TLS
  handshake error: -30592" lines: Chrome rejecting the certificate before the player clicks
  Proceed.
- User steps: restart `host.sh`, open the printed URL, click Advanced > Proceed once.

## Update 2026-11-16 (LAN browser play over HTTPS; game data by default)

- Bug: Chrome on another machine opening `http://<LAN ip>:8080` showed Godot's "Secure Context -
  use HTTPS" error. Plain http is a secure context only on localhost; earlier tests used
  127.0.0.1, so this was missed.
- Fix: `ServerTLS` (`scripts/server/server_tls.gd`) makes a self-signed RSA 2048 certificate with
  `CN=<LAN ip>` in `user://tls/`, reuses it, remakes it when the LAN ip changes or it nears
  expiry. The web build is served over HTTPS (`--https-port`, 8443; `StreamPeerTLS.accept_stream`
  + `TLSOptions.server`), `--http-port` (8080) only redirects (301, same host and path) to https,
  and the game port accepts wss (`WebSocketMultiplayerPeer.create_server(..., TLSOptions.server)`).
  `/server.json` has `ws_scheme`. Desktop clients try wss (`TLSOptions.client_unsafe()`) then ws.
  `--no-tls` restores plain http/ws for localhost tests. `--http-port=0` alone still means no web
  serving (run_lobby.sh), and the game port is still wss there.
- Game data by default: `/local-gamedata/<manifest path>` serves the server's manifest-listed
  files to loopback clients only (403 for everyone else); `/server.json` adds `local_data` and
  `data_id` (manifest sha256) only for loopback. The web menu auto-imports it (music skipped) when
  the browser has no data or the id changed, then skips the data page. Desktop skips the data page
  when ../gamedata (or the saved folder) has a manifest. Lobbies default to the first disc arena
  when the server has data; Test Yard is listed last as "Test Yard (built-in, for testing)".
  No-data banner in the lobby and the HUD; lobby explains who lacks the arena and why Start is
  disabled. "Play without game data" is a small link with a confirmation dialog.
- Tested (headless Chrome, swiftshader, ignore_https_errors): page by LAN ip is a secure context
  and cross-origin isolated, no boot error, lobby -> match over wss with snapshots, 0 console
  errors; loopback page auto-imports 93 files in about 9 s, lobby defaults to XARENA/part1 and a
  disc vehicle, match over wss; LAN `/local-gamedata/manifest.json` is 403; desktop client by LAN
  ip connects over wss; run_lobby 8 clients over wss, 0 errors; `--no-tls` falls back to ws.
- Known: the server logs one "mbedtls error: returned -0x6c00" when a browser tab closes its wss
  connection abruptly; harmless.

## Update 2026-11-16 (disc loader hooked in)

- Protocol version 5: 32 pickup bits in the snapshot header; vehicle ids (`vid`) instead of model
  indices in the lobby, roster and `set`; `hello` carries the client's loadable arena ids and a
  `disc_vehicles` flag (ids only; no game data travels). Lobby settings carry the arena id.
- Server: `arena_ids()` = test_yard + its own game-data arenas; builds disc arenas collision-only;
  refuses Start while a member lacks the arena; `--data` without manifest.json exits with code 2
  and a message (`host.sh` checks first too).
- ENet send-to-disconnecting-peer: fixed in `Transport._raw_send` (checks the ENetPacketPeer is
  active and connected). An ENet match with 3 clients quitting at the end logged no
  "Unable to send packet" line.
- `--host --solo --arena=ID`: local server + lobby with 7 bots, one match, quit. Server reports
  falls, bot resets, bot stuck events and distance per bot.
- Results are in the section "Test results 2026-11-16" at the end.

Work was paused on request. The project loads cleanly: `Godot --headless --path engine --import`
reports 0 script errors. The design and the wire format are documented in `engine/README.md`
(sections "Hosting a LAN game", "Netcode", "Gameplay numbers"). 

## Done and tested headless

- **Transport** (`scripts/net/transport.gd`): WebSocket by default, ENet with `--transport=enet`.
  It sends raw byte packets (no RPCs). The client-side simulator takes `--net-latency`,
  `--net-jitter`, `--net-loss` and `--net-loss-mode=hol|drop`. `hol` makes a lost packet stall
  the stream, the way TCP does.
- **Protocol** (`scripts/net/proto.gd`, `scripts/net/snapshot.gd`): input packets of 22 bytes,
  with 4 inputs of redundancy. Delta snapshots are sent against each client's last
  acknowledged snapshot, with a full snapshot every 2 s. Events are reliable and carry a
  sequence number. Lobby control uses small JSON messages.
- **Dedicated server** (`scripts/server/game_server.gd`, `lobby.gd`, `scenes/server.tscn`,
  `engine/host.sh`):
  - many lobbies on one port, each match in its own SubViewport/World3D;
  - host migration, empty lobbies close, joining a running match works.
- **HTTP server** (`scripts/server/web_file_server.gd`): serves `dist/web` with the correct
  MIME types and COOP/COEP headers, plus `/server.json`. It answers 403 for any path that
  names gamedata/ or cache/, leaves the folder, or starts with a dot.
- **Kinematic vehicle** (`scripts/gameplay/vehicle.gd`): `sim_step` is shared by the server and
  by client prediction/replay. The vehicle is a CharacterBody3D.
- **Match** (`scripts/gameplay/match.gd`):
  - the server keeps a per-player input queue (hold, catch-up, repeat a lost input);
  - the client predicts its own vehicle, replays inputs on reconciliation and smooths the
    correction with a decaying visual offset;
  - remote vehicles and projectiles use an adaptive interpolation delay;
  - missiles, mines and bolts appear for the shooter as soon as they fire;
  - machine-gun hits are lag-compensated (rewind capped at 200 ms).
- **Root cause of the old NaN.** In the old `Vehicle._integrate_forces`, the correction
  accumulators were applied but never cleared, and the quaternion was never normalised. That
  code was replaced.
- **Measured tuning** (`vehicle_profile.gd`, `vehicle_profiles.gd`, `weapons.gd`,
  `projectile.gd`, `pickup.gd`, `hud.gd`, `bot_ai.gd`):
  - driving: constant turning radius with ramp-in, handbrake turn multiplier, turbo (Alt);
  - weapons and health: health per vehicle, machine-gun heat, fire/homing/power/freeze
    missiles, mines, special energy;
  - each built-in vehicle has an original special;
  - ramming damage scales with closing speed and mass;
  - bots navigate: feeler rays, unstuck/detour, ramps through the arena meta `ramps`, and they
    pick up items.
- **F3 overlay and logs** (`scripts/gameplay/net_stats.gd`): the overlay shows ping, jitter,
  loss, bytes/s, snapshot age, interpolation delay and reconciliation error. `--netstats`
  writes the same to the log.
- **Front end** (`scripts/ui/main_menu.gd`): game data, then name (remembered), then server or
  "Start local server", then the lobby browser (auto-refresh), then the lobby (ready, vehicle,
  colour, host settings, start).
- **GameData** (`scripts/autoload/game_data.gd`): `read_bytes(rel)` and a web root of
  `user://gamedata`.
- **Web folder picker** (`scripts/ui/web_data_import.gd`): uses `showDirectoryPicker` and falls
  back to `<input webkitdirectory>`, then copies the manifest's files into IndexedDB.

## Test results (headless, WebSocket, 3-minute matches)

| Test | Down / up per client | Server tick avg / max | Reconciliation | Errors |
|---|---|---|---|---|
| 8 clients, 1 lobby | 2.76 / 0.86 KB/s | 0.92 / 4.4 ms | 86% < 5 cm, worst 1.8 m | 0 |
| Same, 50 ms one-way latency, 20 ms jitter, 2% loss | 2.82 / 0.86 KB/s | 0.91 / 9.1 ms | 89% < 5 cm, worst 2.8 m | 0 |
| 2 lobbies of 4 | 1.92 / 0.86 KB/s | 0.26 and 0.20 / 2.6 ms | worst 1.65 m | 0 |

In the latency run, the measured RTT was about 150 ms and the interpolation delay 126–154 ms.
Each player's vehicle was held on about 4.5% of server ticks, because a simulated TCP
retransmit delays inputs by about 130 ms.

Other checks:

- HTTP checks passed.
- The vehicle tuning test passed for 20 profiles (worst error 9.5%).
- The "Start local server" test passed (`tests/net/local_server_test.gd`).
- Join-in-progress and host migration were checked by hand.
- ENet under simulated loss works.
- The large reconciliation errors were diagnosed (`--diag`): they happen within a few metres of
  another vehicle or near explosions, which only the server simulates.

## Partly done

- **10-minute soak**: started in the background (4 clients, simulated latency, 600 s).
  Its output was not kept, so rerun it (see below).
  At the last check, about 3 minutes in, it had no errors and a tick max of 1.1 ms.
- **Web picker** (`scripts/ui/web_data_import.gd`): written but never run in a browser,
  because the web export has not been built.
- **Web connect**:
  - `Net.web_server_address`, which fetches `/server.json`, is also untested in a browser;
  - the `dist/web/index.html` placeholder was created for the HTTP test and will be
    overwritten by the export.
- **Arena choice**: the server only offers `test_yard` (`GameServer.arena_ids`).
  Disc arenas need the other agent's loader plus server-side collision.
- **Disc vehicle profiles**: these are used only if the vehicle provider reports disc IDs. The
  server and the clients must load the same `tuning.json`, otherwise prediction will not match.

## Not started

- **WebRTC**: evaluated on paper only, not implemented.
  - Godot web builds have WebRTC built in. A desktop or headless Godot server needs the
    `webrtc-native` GDExtension, which is not bundled.
  - Unordered data channels with `maxRetransmits: 0` would remove the TCP stalls.
  - Signalling can go over the existing WebSocket.
  - On a LAN, Chrome's mDNS host candidates must be resolvable by the server.
  - Recommendation: keep WebSocket as the default and add WebRTC later as an optional
    transport.
- **Unmeasured weapons**: rear missile, oil, spikes and the rear flame are not implemented.
- **Turbo refills**: whether turbo refills on pickups is not implemented. A refill on respawn
  is assumed.
- **Health pickup**: the amount is an assumed 40.
- **Freeze visual**: there is no visual tint on frozen vehicles.

## Known bugs and limits

- **ENet send error**: one server log line "Unable to send packet on channel 2, max channels: 0"
  from `transport.gd` `_raw_send`. It probably comes from sending to a peer that is
  disconnecting. Fix it by checking the peer's state before sending, as is already done for
  WebSocket.
- **WebSocket stalls**: a lost TCP segment holds that player's vehicle on the server for a few
  ticks; remote viewers see a short pause, then a catch-up. A bigger input buffer would hide
  this but adds latency.
- **Unpredicted interactions**: vehicle-to-vehicle collisions and pushes are server-only, so
  close fights cause 0.25–3 m corrections. They are smoothed over 0.1 s.
- **Unstuck during replay**: fixed 2026-11-16 (the R-key unstuck is replayed; see below).
- **Not run with a window**:
  - the camera/visual ordering change, which moves car visuals to `Vehicle.update_visual`
    called by the match, has not been seen in a window;
  - the HUD bars have not been checked in a window.

## How to test

```bash
cd engine
tests/net/run_lobby.sh /tmp/t1 8920 "A:8" 180 && python3 -I tests/net/summary.py /tmp/t1
tests/net/run_lobby.sh /tmp/t2 8921 "A:8" 180 --net-latency=50 --net-jitter=20 --net-loss=2 && python3 -I tests/net/summary.py /tmp/t2
tests/net/run_lobby.sh /tmp/t3 8922 "A:4 B:4" 180 && python3 -I tests/net/summary.py /tmp/t3
tests/net/run_lobby.sh /tmp/soak 8923 "S:4" 600 --net-latency=50 --net-jitter=20 --net-loss=2   # 10-minute soak
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tests/net/local_server_test.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://scenes/tests/vehicle_tuning.tscn -- --disc
./host.sh            # real LAN hosting: prints the URLs
```

Add `--diag` to the client flags to print every reconciliation error above 25 cm with context.

## Next steps

1. Rerun the 10-minute soak and check that the client and server logs show no errors and no
   growing reconciliation error.
2. Fix the ENet send-to-disconnecting-peer error in `Transport._raw_send`.
3. Once the export templates are installed, export the "Web" preset to `dist/web/`. Then test in
   Chrome on the LAN: page load, `/server.json`, lobby join, the folder picker over http
   (webkitdirectory fallback), and that IndexedDB keeps the data after a reload.
4. Open one desktop window briefly to check the HUD, the menu layout and the smoothness of the
   predicted car and camera.
5. Optional:
   - replay R-key resets during reconciliation;
   - an adaptive server input buffer per player (grow it after a hold);
   - WebRTC transport behind `Transport` once `webrtc-native` is available for the server.

## Test results 2026-11-16 (WH/part1 from game data, game-data vehicles, hull collision)

| Test (3 min unless noted) | Down / up per client | Server tick avg / max | Corrections < 5 cm / >= 1 m | Errors |
|---|---|---|---|---|
| 8 clients, 1 lobby | 2.73 / 0.86 KB/s | 1.14 / 18.6 ms | 44.2% / 8.7% (avg 0.30 m) | 0 |
| Same, 50 ms latency, 20 ms jitter, 2% loss | 2.82 / 0.86 KB/s | 0.95 / 48.2 ms | 89.5% / 0.8% | 0 |
| 2 lobbies of 4 | 1.94 / 0.86 KB/s | 0.59-0.68 / 3.8-17.8 ms | 58.3% / 9.1% (one 63 m outlier) | 0 |
| Soak, 4 clients, 10 min, latency/jitter/loss | 1.96 / 0.86 KB/s | 0.63 / 4.4 ms | 89.3% / 0.56%, not growing | 0 |

Compared with the test-yard runs above: bandwidth and tick times are unchanged; prediction is as
good as before with simulated latency, and clearly worse without it. Single tick-max spikes
(18-48 ms) coincide with clients building arenas on the same machine.

**Open, top priority: prediction errors with zero latency.** With `--diag`, most corrections
over 25 cm happen more than 8 m from any other vehicle, with equal speed and grounded state on
both sides; the error grows with speed during acceleration (about speed x 0.05 s, i.e. 1.5
ticks of travel), as if client and server applied the same inputs at a slightly different
point. It does not depend on the collision shape (capsule and hull give the same counts on WH)
and also shows on the Test Yard (8 clients, 90 s: 79% < 5 cm, against 86% in the original
baseline). Rounding the state to the wire precision every tick (`--quantize-state`) made it
worse (66%) and is off. Next: log the server's per-input state and the client's predicted state
for one client and diff them tick by tick; check the catch-up path (two inputs in one server
tick) and the input-queue start (`c.next`) at zero latency.

Solo matches with 7 bots (`--host --solo`, 120 s each, every arena): 0 script errors; no falls on
XARENA, WH, PARK, SUBURB, XFWY after the z = 0 collision floor (PARK had 5 before); ROOF has
11 falls per part (cars driving off the roof; bots now treat drop-offs as walls, part 2 went
from 20 to 11). Bot stuck events 18-90 per match; every bot kept driving (lowest 119 m in 120 s,
on SUBURB).

How to rerun with a disc arena: add `--arena=WH/part1` to the client flags of run_lobby.sh.

## Update 2026-11-16: zero-latency prediction errors fixed

**Root cause.** `CharacterBody3D.move_and_slide()` moves the body by `velocity x` the *engine's*
delta: the physics delta inside a physics frame, but the render-frame delta anywhere else. The
client's reconciliation (`_reconcile`, which replays inputs through `Vehicle.sim_step`) runs from
the packet callback, and `Transport` polls in both `_process` and `_physics_process`. When a
snapshot was handled in `_process`, every replayed tick moved the car by speed x frame time
(about 7 ms headless) instead of speed x 1/30 s, so the replayed state was short by most of a
tick of travel and the next ack showed an error of about speed x 0.02-0.03 s. With simulated
latency the delayed packets were mostly released by the `_physics_process` poll, which is why
latency looked better. Inputs, ack mapping, the input queue and the base state were all
correct: the tick diff showed identical inputs and states to the millimetre on both sides
except on the first replayed tick, which moved 0.14 m instead of 0.65 m.

**Fix** (`vehicle.gd` `sim_step`): when not in a physics frame, scale the velocity by
`dt / engine_delta` around `move_and_slide()` and scale it back after, so a step always covers
exactly `dt`. Inside physics frames (the server, normal prediction) the factor is exactly 1 and
nothing changes.

**R-key unstuck** is now replayed during reconciliation: `pred_hist` stores `flip_cd`, the
replay restores it from the acked tick and applies `request_upright()` on the reset-chord edge
exactly as `_client_tick` did (both now also skip it while frozen, as the server does).

**Diff harness.** `--trace-pred` on the server prints `[tp-s]` (state after each consumed input,
with server tick and input tick); on a client it prints `[tp-c]` (state after each predicted
tick) and `[tp-r]` (each ack with the server state and the error). Run
`SERVER_FLAGS=--trace-pred tests/net/run_lobby.sh OUT PORT "A:8" 60 --trace-pred --arena=WH/part1`
then `python3 -I tests/net/pred_diff.py OUT` for the ticks around every correction over 25 cm.
After the fix the remaining big corrections in the diff are vehicle-to-vehicle rams (server-only
velocity reversal), as expected.

Results (3-minute matches, 8 clients unless noted; bandwidth unchanged, 0 client errors):

| Test | Down / up per client | Before: < 5 cm / >= 1 m | After: < 5 cm / >= 1 m |
|---|---|---|---|
| WH/part1, 0 latency | 2.74 / 0.86 KB/s | 44.2% / 8.7% | 97.6% / 0.06% |
| WH/part1, 50 ms / 20 ms / 2% | 2.84 / 0.86 KB/s | 89.5% / 0.8% | 96.5% / 0.08% |
| Test yard, 0 latency | 2.75 / 0.86 KB/s | 79% (90 s) | 93.7% / 0.08% |
| Test yard, 50 ms / 20 ms / 2% | 2.90 / 0.86 KB/s | 89% | 98.0% / 0.05% |
| 2 lobbies of 4, test yard | 1.94 / 0.86 KB/s | 58.3% / 9.1% (WH) | 94.6% / 0.09% |
| 2 lobbies of 4, WH/part1 | 1.86 / 0.86 KB/s | 58.3% / 9.1% | 97.4% / 0.04% |

Testing notes: another agent ran servers on the same machine at the same time, so use unusual
ports (two of my runs hit "could not listen ... Already in use" and were rerun; one stray "Solo"
lobby joined a test server). Runs without `--arena` picked XARENA/part1 once, so pass
`--arena=test_yard` explicitly. Some runs logged server SCRIPT ERRORs from the in-progress prop
work (`disc_props.gd:495 _show_state` out of bounds, `game.gd:122 has_disc_data`
`is_available`); none came from the netcode. `--quantize-state` was not re-measured after the fix.
