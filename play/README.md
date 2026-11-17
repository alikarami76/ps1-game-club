# Play: PS1 games with friends

Play a PlayStation game **you own** with friends, using existing open-source projects. There is no emulator written here: this folder wires up [EmulatorJS](https://emulatorjs.org) (GPL-3.0) with the PCSX-ReARMed core for the browser, and documents RetroArch's built-in netplay for native play.

- **`server/`**: a self-hosted "club" server. One command starts a landing page, the EmulatorJS player and the EmulatorJS netplay relay.
- **`native/`**: RetroArch plus PCSX-ReARMed on macOS, Windows or Linux, with helper scripts and a netplay config.

## What it does, and what it does not

Netplay here is **input sharing**. Every player runs the same game and the players' button presses are exchanged, so everyone sees the same thing.

- It works for games that already have a **local two-or-more player mode**, up to the number of players the game supports. A PS1 multitap allows up to 8 players in games that support it (native RetroArch route; the browser room dialog stops at 4).
- It does **not** add multiplayer to a single-player game. Making such a game multiplayer needs a remake, which is what the remake kit elsewhere in this repository is for.
- Everyone needs the same game (same dump and region).

## Legal note

Bring your own legally owned games. **No games and no BIOS files are included, downloaded or uploaded by anything here.** In the browser version, each player picks their own disc image from their own computer; the browser reads it locally and it is never sent to the server. The PS1 core runs with an open BIOS replacement (HLE), so no Sony BIOS is needed. Players may choose to load a BIOS dump from their own console, again only into their own browser. The `.gitignore` in this folder blocks game images, BIOS files and fetched bundles from being committed.

## Quick start: browser club

Requirements: Docker, **or** Node.js 18+ with `curl`, `openssl` and a 7-Zip tool (`7zz`, `7z` or `7za`) for the plain-script route.

```sh
cd play/server
docker compose up --build
```

Without Docker:

```sh
cd play/server
./setup.sh          # downloads the pinned EmulatorJS release and netplay logic, checks their hashes
npm start
```

Then open the address printed in the terminal (default port `3443`).

1. Everyone opens the club page, **picks their own disc** (`.chd`, `.pbp`, `.iso`, a single `.bin`, or a `.cue` together with all its `.bin` files) and presses **Start**.
2. Once the game runs, open **Netplay** in the emulator's bottom bar. The host enters a name and creates a room. Friends enter a name and press **Join**.
3. The host is player 1, the next joiner player 2, and so on.

Players only see each other's rooms when they use the same "game number". The page works it out from the disc, and there is a box to type the same number by hand when players have different dumps of one game.

Settings (environment variables or a `.env` file next to `docker-compose.yml`): `CLUB_PORT` (default 3443), `CLUB_NAME`, `CLUB_TLS` (`auto`, `on`, `off`), `CLUB_CERT` and `CLUB_KEY` (paths), `CLUB_HOST` (default all interfaces; use `127.0.0.1` to keep it on this computer).

### Pinned versions

| Part | Version | Licence |
| --- | --- | --- |
| EmulatorJS (player and PCSX-ReARMed core) | 4.2.3 (stable) | GPL-3.0 |
| EmulatorJS-Netplay room logic | v0.4.3, commit `50288f4` | Apache-2.0 |
| express / socket.io (npm) | 4.22.3 / 4.8.4 | MIT |

Pins and SHA-256 hashes live in `server/versions.env`. Nothing from upstream is committed; `setup.sh` fetches it into `server/vendor/`, which is git-ignored.

## LAN, internet and HTTPS

**HTTPS.** Browsers only expose some features (gamepads, certain storage and performance features) on secure pages, meaning `https://` or `http://localhost`. On the host computer `http://localhost:3443/` is enough. Friends on other computers should use `https://`:

```sh
cd play/server
./gen-cert.sh <address-friends-will-type>   # self-signed certificate; browsers warn once
```

With the certificate present the server switches to HTTPS on its own. For a public name use a real certificate (set `CLUB_CERT` and `CLUB_KEY`, or put the server behind a reverse proxy such as Caddy or nginx that terminates TLS and forwards WebSocket traffic).

**Ports.** One TCP port serves everything: `3443` by default (page, EmulatorJS files, room list and the netplay WebSocket). Allow it in the host's firewall. For internet play, forward that port on the router, or run the server on a cloud machine or behind a VPN or overlay network such as WireGuard or Tailscale.

**Signalling and TURN.** The EmulatorJS 4.2.3 netplay does **not** use peer-to-peer WebRTC. Every message, including controller input and the host's save state, goes through the club server over a socket.io WebSocket. So the club server is the "signalling server", it is also the relay, and **no TURN or STUN server is needed**, because players never connect directly to each other and only need to reach the club server. The price is that every player's delay includes a round trip to the server, so host the server close to the players (the same LAN is best). A future EmulatorJS release (the 4.3.0 pre-release line) may change the protocol; this folder pins 4.2.3. If you ever swap in a WebRTC-based netplay, that is when STUN/TURN would matter.

## Honest limits

- EmulatorJS 4.2.3 treats browser netplay as **experimental**: it only turns on in its debug mode, which this page sets, and its own source marks controller syncing as unfinished. Expect it to work best for two players on a good connection, and to desync now and then. In a headless test with two browser windows on one computer, a host and a joiner connected, the joiner received the host's state and both stayed within a frame or two of each other for minutes; controller messages from the joiner reached the host. Play on real separate computers, a long session, and a visible two-player match have not been tested.
- The EmulatorJS room dialog offers rooms of 2, 3 or 4 players. The 8-player multitap limit applies to native RetroArch play, not to the browser version.
- The host runs the game and sends its save state to every joiner. A player who joins late restarts everyone from the host's state.
- The browser emulator is slower than native, and each player's computer must keep up with full speed, or the others wait.
- The upstream room code has a small known flaw: when a host closes a room, rooms created after it can disappear from the list too. Restarting the club server clears everything.
- For serious play, prefer the native route in `native/`.

## Native play

See [`native/README.md`](native/README.md): RetroArch with the PCSX-ReARMed core and its built-in netplay, with host and join scripts for macOS, Linux and Windows, and a ready netplay config.
