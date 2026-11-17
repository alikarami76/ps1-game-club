#!/usr/bin/env python3
"""Proves the --behind-proxy access gate: every route is refused without the cookie (including the
/ws upgrade and game data), works with it, rate-limits bad logins, and refuses to start without a key.

Usage: python3 gate_test.py [--godot=PATH] [--data=GAMEDATA] [--web=DIR] [--port=9930]
Runs its own headless server on --port (and port+1 for the game); never touches other ports.
"""
import base64, http.client, os, secrets, signal, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.abspath(os.path.join(HERE, "..", ".."))
opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
GODOT = opts.get("godot", os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot"))
DATA = opts.get("data", os.path.join(GAME, "..", "gamedata"))
WEB = opts.get("web", os.path.join(GAME, "..", "dist", "web"))
PORT = int(opts.get("port", "9930"))
KEY = secrets.token_urlsafe(32)
fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails.append(name)


def req(method, path, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request(method, path, headers=headers or {})
    r = c.getresponse()
    body = r.read(2000)
    return r.status, dict((k.lower(), v) for k, v in r.getheaders()), body


def ws_upgrade(cookie=None, xff="9.9.9.9"):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    k = base64.b64encode(os.urandom(16)).decode()
    h = f"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {k}\r\nSec-WebSocket-Version: 13\r\nX-Forwarded-For: {xff}\r\n"
    if cookie:
        h += f"Cookie: {cookie}\r\n"
    s.sendall((h + "\r\n").encode())
    data = s.recv(500).decode("latin1")
    s.close()
    return data.split("\r\n")[0]


env = dict(os.environ, TM_ACCESS_KEY=KEY, TM_BEHIND_PROXY="1")
base = [GODOT, "--headless", "--path", GAME, "--", "--server", f"--port={PORT + 1}", f"--http-port={PORT}", f"--web-root={WEB}", f"--data={DATA}"]

# 1. refuses to start without a key
env0 = {k: v for k, v in env.items() if k != "TM_ACCESS_KEY"}
r = subprocess.run(base, env=env0, capture_output=True, text=True, timeout=60)
check("refuses to start without TM_ACCESS_KEY", r.returncode != 0 and "TM_ACCESS_KEY" in (r.stderr + r.stdout))
env1 = dict(env, TM_ACCESS_KEY="short")
r = subprocess.run(base, env=env1, capture_output=True, text=True, timeout=60)
check("refuses to start with a short key", r.returncode != 0)

proc = subprocess.Popen(base, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", PORT), timeout=0.5).close()
            break
        except OSError:
            time.sleep(0.3)
    manifest_rel = "manifest.json"
    # 2. every route refused without the cookie
    routes = ["/", "/index.html", "/index.js", "/index.wasm", "/index.pck", "/server.json", "/ws",
              f"/local-gamedata/{manifest_rel}", "/local-gamedata/audio/sfx/index.json", "/local-gamedata/../project.godot",
              "/nothing", "/login", "/login?key=", "/login?key=wrong", "/%2e%2e/etc/passwd"]
    for p in routes:
        for m in ("GET", "HEAD", "POST"):
            st, hd, body = req(m, p, {"X-Forwarded-For": "1.1.1.1" if p != "/login?key=wrong" else "2.2.2.2"})
            check(f"no cookie: {m} {p} -> 404", st == 404 and b"ok" not in body[:3] and "set-cookie" not in hd, st)
    check("no cookie: /ws upgrade refused", ws_upgrade().split(" ")[1] == "404", ws_upgrade())
    check("wrong cookie: /ws upgrade refused", ws_upgrade("tm_session=deadbeef").split(" ")[1] == "404")
    st, hd, body = req("GET", "/", {"Cookie": "tm_session=" + "0" * 64})
    check("forged cookie refused", st == 404)
    # 3. health check is open and says nothing
    st, hd, body = req("GET", "/healthz")
    check("/healthz open, body is just ok", st == 200 and body.strip() == b"ok", (st, body))
    # 4. correct login
    st, hd, body = req("GET", f"/login?key={KEY}", {"X-Forwarded-For": "3.3.3.3"})
    sc = hd.get("set-cookie", "")
    check("login redirects to /", st == 302 and hd.get("location") == "/")
    check("cookie is HttpOnly, Secure, SameSite=Strict", all(x in sc for x in ("HttpOnly", "Secure", "SameSite=Strict")) and sc.startswith("tm_session="), sc[:12])
    check("cookie does not contain the key", KEY not in sc)
    cookie = sc.split(";")[0]
    H = {"Cookie": cookie, "Host": "tm.example.test", "X-Forwarded-Proto": "https"}
    st, hd, body = req("GET", "/", H)
    check("with cookie: / serves the page", st == 200 and b"<html" in body.lower())
    st, hd, body = req("GET", "/index.pck", H)
    check("with cookie: /index.pck serves", st == 200)
    st, hd, body = req("GET", "/server.json", H)
    check("with cookie: /server.json says wss://<host>/ws and local data", st == 200 and b'"wss://tm.example.test/ws"' in body.replace(b" ", b"") and b"local_data" in body, body[:200])
    st, hd, body = req("GET", f"/local-gamedata/{manifest_rel}", H)
    check("with cookie: game data manifest serves", st == 200 and b"\"format\"" in body, st)
    st, hd, body = req("GET", "/local-gamedata/../project.godot", H)
    check("with cookie: traversal still refused", st in (403, 404))
    st, hd, body = req("GET", "/gamedata/manifest.json", H)
    check("with cookie: /gamedata/ web path still refused", st == 403)
    check("with cookie: /ws upgrade accepted (101)", ws_upgrade(cookie).split(" ")[1] == "101", ws_upgrade(cookie))
    # 5. rate limit: 5 bad logins from one client, then even the right key is refused for that client
    for _ in range(5):
        req("GET", "/login?key=nope", {"X-Forwarded-For": "4.4.4.4"})
    st, _, _ = req("GET", f"/login?key={KEY}", {"X-Forwarded-For": "4.4.4.4"})
    check("rate limit: 429 after 5 failures", st == 429, st)
    st, _, _ = req("GET", f"/login?key={KEY}", {"X-Forwarded-For": "5.5.5.5"})
    check("rate limit is per client (another client can log in)", st == 302, st)
finally:
    proc.send_signal(signal.SIGINT)
    try:
        out = proc.communicate(timeout=15)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        out = proc.communicate()[0]
check("the key never appears in the server log", KEY not in out)
print("\n%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
