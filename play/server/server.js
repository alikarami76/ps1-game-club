// PS1 Game Club server.
// One process, one port: serves the club page, the self-hosted EmulatorJS files,
// and the EmulatorJS netplay relay (socket.io), over HTTPS when a certificate exists.
//
// The netplay room logic is upstream code (EmulatorJS-Netplay, Apache-2.0), fetched by
// setup.sh into vendor/netplay/functions.js. Only the HTTP glue below is ours.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const https = require("https");
const express = require("express");
const { Server } = require("socket.io");

const ROOT = __dirname;
const PUBLIC = path.join(ROOT, "public");
const VENDOR = path.join(ROOT, "vendor");
const FUNCTIONS = path.join(VENDOR, "netplay", "functions.js");

const PORT = parseInt(process.env.CLUB_PORT || "3443", 10);
const HOST = process.env.CLUB_HOST || "0.0.0.0";
const CERT = process.env.CLUB_CERT || path.join(ROOT, "certs", "club.crt");
const KEY = process.env.CLUB_KEY || path.join(ROOT, "certs", "club.key");
const TLS_MODE = (process.env.CLUB_TLS || "auto").toLowerCase(); // auto | on | off
const CLUB_NAME = (process.env.CLUB_NAME || "PS1 Game Club").slice(0, 60);

for (const needed of [FUNCTIONS, path.join(VENDOR, "emulatorjs", "loader.js")]) {
  if (!fs.existsSync(needed)) {
    console.error("Missing " + path.relative(ROOT, needed) + ". Run ./setup.sh first (or use docker compose, which does it for you).");
    process.exit(1);
  }
}
const netplay = require(FUNCTIONS);

const haveCert = fs.existsSync(CERT) && fs.existsSync(KEY);
const useTls = TLS_MODE === "on" || (TLS_MODE === "auto" && haveCert);
if (useTls && !haveCert) {
  console.error("CLUB_TLS=on but no certificate found. Run ./gen-cert.sh or set CLUB_CERT and CLUB_KEY.");
  process.exit(1);
}

const app = express();
app.disable("x-powered-by");

// Never cache the club page; vendor files are pinned so they may be cached briefly.
app.use((req, res, next) => {
  res.setHeader("Cache-Control", req.path.startsWith("/emulatorjs/") ? "public, max-age=3600" : "no-cache");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  next();
});

app.get("/config.json", (req, res) => res.json({ name: CLUB_NAME, tls: useTls }));

// Room list used by the EmulatorJS netplay menu.
global.rooms = global.rooms || [];
app.get("/list", (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  const args = netplay.transformArgs(req.url);
  if (!args.game_id || !args.domain) return res.json({});
  const gameId = parseInt(args.game_id, 10);
  const out = {};
  for (const room of global.rooms) {
    if (room.domain !== args.domain || room.game_id !== gameId) continue;
    out[room.sessionid] = {
      owner_name: room.owner.extra.player_name || room.owner.extra.name,
      room_name: room.name,
      max: room.max,
      current: room.current,
      password: room.password.trim() ? 1 : 0,
    };
  }
  res.json(out);
});

app.use("/emulatorjs", express.static(path.join(VENDOR, "emulatorjs"), { fallthrough: true }));
app.use(express.static(PUBLIC));

const server = useTls
  ? https.createServer({ cert: fs.readFileSync(CERT), key: fs.readFileSync(KEY) }, app)
  : http.createServer(app);

const io = new Server(server, {
  cors: { origin: "*", methods: ["GET", "POST"] },
  maxHttpBufferSize: 1e8, // the host sends a PS1 save state (about 4 MB) to joiners
});
const counter = { num: 0 };
netplay.start(io, global.rooms, counter, process.env.CLUB_DEBUG === "1");

server.listen(PORT, HOST, () => {
  const scheme = useTls ? "https" : "http";
  console.log(CLUB_NAME + " is up. Listening on " + HOST + ":" + PORT + " (" + scheme.toUpperCase() + ")");
  console.log("  This computer:  " + scheme + "://localhost:" + PORT + "/");
  if (HOST === "0.0.0.0") {
    for (const list of Object.values(os.networkInterfaces())) {
      for (const a of list || []) {
        if (a.family === "IPv4" && !a.internal) console.log("  On your network: " + scheme + "://" + a.address + ":" + PORT + "/");
      }
    }
  }
  if (!useTls) {
    console.log("  Note: plain HTTP. Friends on other computers need HTTPS for gamepads and some browser features. See README (./gen-cert.sh).");
  }
});

function shutdown() { io.close(); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 1500); }
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
