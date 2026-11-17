class_name WebFileServer
extends Node
## Tiny HTTP/1.1 static file server for the web build (GET and HEAD only), run inside the game
## server process. Serves files under one root folder (dist/web/) with the right MIME types for
## .wasm and .pck, plus /server.json (the game port and whether it is ws or wss). It refuses any
## path that leaves the root or names a gamedata/ or cache/ folder, so players' game data is
## never served. Cross-origin isolation headers (COOP/COEP) are sent too; the threadless web
## build does not need them, but they keep a threaded build working.
##
## With tls set (TLSOptions.server) every connection is HTTPS. Chrome runs Godot web builds only
## in a secure context, and http://<LAN ip> is not one, so LAN hosting uses HTTPS.
## With redirect_port > 0 the server serves nothing and answers every request with a redirect to
## https://<same host>:<redirect_port><same path> (the old plain-http port keeps working).
##
## /local-gamedata/<path>: the server's own game data, ONLY for a browser on this same machine
## (the connection comes from 127.0.0.1 or ::1) and ONLY for manifest.json and the files the
## manifest lists (exact match, no listing, no traversal). Any other client gets 403. This lets
## the host's own browser load the game data without picking a folder; other machines still pick
## their own folder. /server.json says "local_data": true (and the manifest's checksum) only to
## loopback clients.

const CHUNK := 65536
const MIME := {
	"html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "js": "text/javascript",
	"mjs": "text/javascript", "wasm": "application/wasm", "pck": "application/octet-stream",
	"png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml", "ico": "image/x-icon",
	"json": "application/json", "css": "text/css", "txt": "text/plain; charset=utf-8",
	"webmanifest": "application/manifest+json", "woff2": "font/woff2",
}
const FORBIDDEN := ["gamedata", "cache"]

var server := TCPServer.new()
var root := ""
var ws_port := 8910
var server_name := ""
var ws_scheme := "ws"
var tls: TLSOptions = null     # set: serve HTTPS
var redirect_port := 0         # > 0: redirect every request to https on this port
var data_root := ""            # server's game-data folder (holds manifest.json); "" = none
var data_files := {}           # manifest-relative path -> true (what /local-gamedata/ may serve)
var data_id := ""              # sha256 of manifest.json, so browsers re-import when it changes
const LOCAL_DATA := "/local-gamedata/"
var ws_proxy := false          # true: /ws upgrades are forwarded to 127.0.0.1:ws_port
const WS_PATH := "/ws"
## Deployment behind a reverse proxy (see AccessGate): when set, only /healthz and /login are public;
## everything else (page, /server.json, /ws, /local-gamedata/) needs the session cookie and
## game data is served to cookie holders instead of to loopback only.
var gate: AccessGate = null
const PROXY_BUF := 1 << 20     # stop reading a side while 1 MB waits for the other side
var conns: Array = []          # {tcp, tls (StreamPeerTLS or null), buf, file, left, out, t, proxy}
var requests := 0
var proxied := 0               # /ws connections forwarded so far
## Called after /ws bytes went to the game port, so the game reads (and answers) them in this
## frame instead of the next one; then the answers are forwarded at once. Set by GameServer.
var poll_game: Callable
var _moved_up := 0

func listen(port: int, web_root: String, bind := "*") -> Error:
	root = web_root.simplify_path()
	return server.listen(port, bind)

## Allow /local-gamedata/ for loopback clients: manifest.json plus every file it lists.
func set_local_data(folder: String, listed: PackedStringArray) -> void:
	data_root = folder
	data_files = {"manifest.json": true}
	for rel in listed:
		data_files[rel] = true
	data_id = FileAccess.get_sha256(folder.path_join("manifest.json"))

static func is_loopback(addr: String) -> bool:
	addr = addr.to_lower()
	return addr.begins_with("127.") or addr == "::1" or addr == "0:0:0:0:0:0:0:1" or addr.begins_with("::ffff:127.") \
		or addr.begins_with("0:0:0:0:0:ffff:127.") or addr == "0:0:0:0:0:ffff:7f00:1"

func _ready() -> void:
	process_priority = 100            # after the game's Transport (-1000) has flushed this frame
	process_physics_priority = 100

func _physics_process(_d: float) -> void:
	# forward /ws traffic right after the match has sent this tick's snapshots
	_service_proxies()

func _service_proxies() -> void:
	_moved_up = 0
	for c in conns.duplicate():
		if c.proxy != null and not _service(c):
			_close(c)
	if _moved_up > 0 and poll_game.is_valid():
		poll_game.call()
		for c in conns.duplicate():
			if c.proxy != null and not _service(c):
				_close(c)

func _process(_d: float) -> void:
	while server.is_connection_available():
		var tcp := server.take_connection()
		tcp.set_no_delay(true)
		var sp: StreamPeerTLS = null
		if tls != null:
			sp = StreamPeerTLS.new()
			if sp.accept_stream(tcp, tls) != OK:
				tcp.disconnect_from_host()
				continue
		conns.append({"tcp": tcp, "tls": sp, "buf": PackedByteArray(), "file": null, "left": 0, "out": PackedByteArray(), "t": Time.get_ticks_msec(), "proxy": null})
	for c in conns.duplicate():
		if c.proxy == null and not _service(c):
			_close(c)
	_service_proxies()

func _close(c: Dictionary) -> void:
	if c.file != null:
		c.file.close()
	if c.proxy != null:
		var px: Dictionary = c.proxy
		if px.tls != null:
			px.tls.disconnect_from_stream()
		px.tcp.disconnect_from_host()
	if c.tls != null:
		c.tls.disconnect_from_stream()
	c.tcp.disconnect_from_host()
	conns.erase(c)

## Returns false when the connection should be closed.
func _service(c: Dictionary) -> bool:
	var tcp: StreamPeer = c.tcp
	if c.tls != null:
		var sp: StreamPeerTLS = c.tls
		sp.poll()
		var ts := sp.get_status()
		if ts == StreamPeerTLS.STATUS_HANDSHAKING:
			return Time.get_ticks_msec() - c.t < 10000
		if ts != StreamPeerTLS.STATUS_CONNECTED:
			return false   # handshake refused (e.g. a plain-http request) or closed
		tcp = sp
	elif c.proxy != null:
		var tp0: StreamPeerTCP = c.tcp
		tp0.poll()
		if tp0.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return false
	else:
		var tp: StreamPeerTCP = c.tcp
		tp.poll()
		var st := tp.get_status()
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			return false
		if st != StreamPeerTCP.STATUS_CONNECTED:
			return Time.get_ticks_msec() - c.t < 10000
	if c.proxy != null:
		return _service_proxy(c, tcp)
	# sending
	if not c.out.is_empty() or c.left > 0:
		for _i in 32:   # up to 2 MB per frame and connection while the socket takes it
			if c.out.is_empty():
				if c.file == null or c.left <= 0:
					break
				c.out = c.file.get_buffer(mini(CHUNK, c.left))
				c.left -= c.out.size()
				if c.out.is_empty():
					return false
			var res := tcp.put_partial_data(c.out)
			if res[0] != OK:
				return false
			if res[1] == 0:
				break
			c.out = c.out.slice(res[1])
			c.t = Time.get_ticks_msec()
		return not (c.out.is_empty() and c.left <= 0)   # close once everything is sent
	# reading the request
	var avail := tcp.get_available_bytes()
	if avail > 0:
		var r := tcp.get_partial_data(avail)
		if r[0] == OK:
			c.buf.append_array(r[1])
	if c.buf.size() > 16384:
		return false
	var text: String = (c.buf as PackedByteArray).get_string_from_ascii()
	var end: int = text.find("\r\n\r\n")
	if end < 0:
		return Time.get_ticks_msec() - c.t < 10000
	_respond(c, text.substr(0, end))
	if c.proxy != null:
		# bytes after the request head (none for a well-behaved client) go upstream too
		c.proxy.up_buf.append_array((c.buf as PackedByteArray).slice(end + 4))
		c.buf = PackedByteArray()
	return true

## /ws: forward bytes both ways between the browser (down) and the game's WebSocket port (up).
func _service_proxy(c: Dictionary, down: StreamPeer) -> bool:
	var px: Dictionary = c.proxy
	var up_tcp: StreamPeerTCP = px.tcp
	up_tcp.poll()
	var st := up_tcp.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		return Time.get_ticks_msec() - c.t < 5000
	if st != StreamPeerTCP.STATUS_CONNECTED:
		return _flush_down(px, down)
	var up: StreamPeer = up_tcp
	if px.use_tls:
		if px.tls == null:
			px.tls = StreamPeerTLS.new()
			# loopback to our own game port, which uses our own certificate
			if px.tls.connect_to_stream(up_tcp, "localhost", TLSOptions.client_unsafe()) != OK:
				return false
		var ut: StreamPeerTLS = px.tls
		ut.poll()
		var uts := ut.get_status()
		if uts == StreamPeerTLS.STATUS_HANDSHAKING:
			return Time.get_ticks_msec() - c.t < 5000
		if uts != StreamPeerTLS.STATUS_CONNECTED:
			return _flush_down(px, down)
		up = ut
	for _i in 8:
		var moved := 0
		var a := _pipe(down, up, px, "up_buf")
		if a > 0:
			_moved_up += a
		var b := _pipe(up, down, px, "down_buf")
		if a < 0 or b < 0:
			return _flush_down(px, down) if a < 0 else false
		moved = a + b
		if moved == 0:
			break
		if px.use_tls:
			(px.tls as StreamPeerTLS).poll()
	return true

## Reads what src has (while the buffer is not full) and writes the buffer to dst. Returns the
## bytes moved, or -1 when src or dst failed.
func _pipe(src: StreamPeer, dst: StreamPeer, px: Dictionary, buf_key: String) -> int:
	var buf: PackedByteArray = px[buf_key]
	var moved := 0
	var avail := src.get_available_bytes()
	if avail > 0 and buf.size() < PROXY_BUF:
		var r := src.get_partial_data(mini(avail, PROXY_BUF))
		if r[0] != OK:
			return -1
		buf.append_array(r[1])
		moved += (r[1] as PackedByteArray).size()
	if not buf.is_empty():
		var w := dst.put_partial_data(buf)
		if w[0] != OK:
			return -1
		if w[1] > 0:
			buf = buf.slice(w[1])
			moved += w[1]
	px[buf_key] = buf
	return moved

## The game side closed: send the browser what is left (the close frame), then close.
func _flush_down(px: Dictionary, down: StreamPeer) -> bool:
	var buf: PackedByteArray = px.down_buf
	if not buf.is_empty():
		down.put_partial_data(buf)
	return false

func _respond(c: Dictionary, head: String) -> void:
	requests += 1
	var line := head.split("\r\n")[0].split(" ")
	if gate != null:
		if _gate_request(c, head, line):
			return
	if line.size() < 2 or not (line[0] in ["GET", "HEAD"]):
		_simple(c, 405, "Method Not Allowed")
		return
	var head_only: bool = line[0] == "HEAD"
	if redirect_port > 0:
		_redirect(c, head, line[1])
		return
	var path := line[1].split("?")[0].split("#")[0].uri_decode()
	var loopback := is_loopback((c.tcp as StreamPeerTCP).get_connected_host())
	var data_ok := loopback if gate == null else true   # gate: this request already holds a session
	if OS.is_stdout_verbose() or Game.args.has("verbose"):
		print("[http] %s %s from %s" % [line[0], path, (c.tcp as StreamPeerTCP).get_connected_host()])
	if path == WS_PATH:
		if ws_proxy and line[0] == "GET" and _header(head, "upgrade").to_lower() == "websocket":
			_start_proxy(c, head, line[1])
		else:
			_simple(c, 426 if ws_proxy else 404, "Upgrade Required" if ws_proxy else "Not Found")
		return
	if path.begins_with(LOCAL_DATA):
		var drel := path.substr(LOCAL_DATA.length())
		if not data_ok or data_root == "" or not data_files.has(drel) or not GameData.is_safe_rel(drel):
			_simple(c, 403, "Forbidden")
			return
		_send_file(c, data_root.path_join(drel), drel, head_only)
		return
	if path == "/server.json":
		var info := {"ws_port": ws_port, "ws_scheme": ws_scheme, "name": server_name, "version": Proto.VERSION}
		if ws_proxy:
			# same host and port as this page, so the page's certificate exception covers it
			info.ws_path = WS_PATH
			var host := _header(head, "host")
			if _is_host_port(host):
				var secure := tls != null
				if gate != null:
					# TM_PUBLIC_HTTPS=1: the public address is https even though the proxy says http. Some hosting
					# platforms end TLS at an outer load balancer and its ingress forwards "X-Forwarded-Proto: http", and an https
					# page may not open a ws:// socket.
					var proto := _header(head, "x-forwarded-proto").to_lower().split(",")[0].strip_edges()
					secure = proto == "https" or OS.get_environment("TM_PUBLIC_HTTPS") == "1"
				info.ws_url = "%s://%s%s" % ["wss" if secure else "ws", host, WS_PATH]
		if data_ok and data_root != "":
			info.local_data = true
			info.data_id = data_id
			if gate != null:
				info.import_music = true   # deployment data is small (ogg); a browser keeps all of it
		var body := JSON.stringify(info).to_utf8_buffer()
		_send_bytes(c, 200, "OK", "application/json", body, head_only)
		return
	if path.ends_with("/"):
		path += "index.html"
	var rel := path.trim_prefix("/")
	if not is_safe(rel):
		_simple(c, 403, "Forbidden")
		return
	_send_file(c, root.path_join(rel), rel, head_only)

## Access gate. Returns true when the request was answered here (health, login, or refused).
## Anything without a valid session cookie gets the same plain 404, whatever it asked for.
func _gate_request(c: Dictionary, head: String, line: PackedStringArray) -> bool:
	var target: String = line[1] if line.size() >= 2 else ""
	var path := target.split("?")[0].split("#")[0].uri_decode()
	var is_get: bool = line.size() >= 2 and line[0] in ["GET", "HEAD"]
	if is_get and path == "/healthz":
		_send_bytes(c, 200, "OK", "text/plain; charset=utf-8", "ok\n".to_utf8_buffer(), line[0] == "HEAD")
		return true
	if is_get and path == "/login":
		_login(c, head, target)
		return true
	if is_get and gate.has_session(_header(head, "cookie")):
		return false
	_simple(c, 404, "Not Found")
	return true

func _client_id(c: Dictionary, head: String) -> String:
	var xff := _header(head, "x-forwarded-for")
	if xff != "":
		return xff.split(",")[-1].strip_edges().left(64)   # the last hop is the one our own proxy added
	return (c.tcp as StreamPeerTCP).get_connected_host()

func _login(c: Dictionary, head: String, target: String) -> void:
	var client := _client_id(c, head)
	if gate.is_limited(client):
		_simple(c, 429, "Too Many Requests")
		return
	var key := ""
	var qi := target.find("?")
	if qi >= 0:
		for kv in target.substr(qi + 1).split("#")[0].split("&"):
			var p := kv.split("=", true, 1)
			if p[0] == "key" and p.size() == 2:
				key = p[1].uri_decode()
	if key == "" or not gate.check_key(key):
		gate.record_fail(client)
		_simple(c, 404, "Not Found")
		return
	var hdr := "HTTP/1.1 302 Found\r\nLocation: /\r\n%sContent-Length: 0\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n" % gate.set_cookie_header()
	c.out = hdr.to_ascii_buffer()

## Value of the first header with this (lower-case) name, "" when absent.
static func _header(head: String, name: String) -> String:
	for l in head.split("\r\n").slice(1):
		var i := l.find(":")
		if i > 0 and l.substr(0, i).strip_edges().to_lower() == name:
			return l.substr(i + 1).strip_edges()
	return ""

## host, host:port, [v6] or [v6]:port with nothing else in it.
static func _is_host_port(h: String) -> bool:
	if h == "" or h.length() > 300:
		return false
	for ch in h:
		if not (ch.is_valid_identifier() or ch.is_valid_int() or ch in [".", "-", ":", "[", "]"]):
			return false
	return true

## Hands this connection to the /ws forwarder: connects to the game port on loopback and sends
## it a clean upgrade request (only the WebSocket headers, so cookies or long headers from the
## browser never hit the game server's handshake size limit).
func _start_proxy(c: Dictionary, head: String, target: String) -> void:
	var key := _header(head, "sec-websocket-key")
	var ver := _header(head, "sec-websocket-version")
	if key == "" or ver == "":
		_simple(c, 400, "Bad Request")
		return
	var up := StreamPeerTCP.new()
	if up.connect_to_host("127.0.0.1", ws_port) != OK:
		_simple(c, 502, "Bad Gateway")
		return
	up.set_no_delay(true)
	var req := "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: %s\r\n" % [target if _is_safe_target(target) else WS_PATH, ws_port, key, ver]
	var proto := _header(head, "sec-websocket-protocol")
	if proto != "":
		req += "Sec-WebSocket-Protocol: %s\r\n" % proto
	req += "\r\n"
	c.proxy = {"tcp": up, "tls": null, "use_tls": tls != null, "up_buf": req.to_ascii_buffer(), "down_buf": PackedByteArray()}
	c.t = Time.get_ticks_msec()
	proxied += 1

static func _is_safe_target(t: String) -> bool:
	for i in t.length():
		var u := t.unicode_at(i)
		if u <= 32 or u >= 127:
			return false
	return t.begins_with("/")

func _send_file(c: Dictionary, full: String, rel: String, head_only: bool) -> void:
	if not FileAccess.file_exists(full):
		_simple(c, 404, "Not Found")
		return
	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		_simple(c, 404, "Not Found")
		return
	var size := f.get_length()
	var hdr := _headers(200, "OK", mime_for(rel), size)
	c.out = hdr.to_ascii_buffer()
	if head_only:
		f.close()
	else:
		c.file = f
		c.left = size

## Relative URL path check: no parent references, no absolute or drive paths, no hidden files,
## and nothing inside a gamedata/ or cache/ folder.
static func is_safe(rel: String) -> bool:
	if rel == "" or rel.begins_with("/") or rel.contains("\\") or rel.contains(":"):
		return false
	for i in rel.length():
		if rel.unicode_at(i) < 32:
			return false
	for part in rel.split("/"):
		if part == "" or part == "." or part == ".." or part.begins_with("."):
			return false
		if part.to_lower() in FORBIDDEN:
			return false
	return true

static func mime_for(rel: String) -> String:
	return MIME.get(rel.get_extension().to_lower(), "application/octet-stream")

func _headers(code: int, msg: String, ctype: String, length: int) -> String:
	return "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n" % [code, msg, ctype, length]

func _send_bytes(c: Dictionary, code: int, msg: String, ctype: String, body: PackedByteArray, head_only: bool) -> void:
	var out := _headers(code, msg, ctype, body.size()).to_ascii_buffer()
	if not head_only:
		out.append_array(body)
	c.out = out

func _simple(c: Dictionary, code: int, msg: String) -> void:
	_send_bytes(c, code, msg, "text/plain; charset=utf-8", ("%d %s\n" % [code, msg]).to_utf8_buffer(), false)

## 301 to https on redirect_port, keeping the host name the browser used and the path.
func _redirect(c: Dictionary, head: String, target: String) -> void:
	var host := ""
	for l in head.split("\r\n"):
		if l.to_lower().begins_with("host:"):
			host = l.substr(5).strip_edges()
	if host.begins_with("["):
		host = host.substr(0, host.find("]") + 1)
	elif host.contains(":"):
		host = host.split(":")[0]
	if host == "" or not host.is_valid_ip_address() and not _is_host_name(host):
		host = server_host_fallback
	if not target.begins_with("/"):
		target = "/"
	var url := "https://%s:%d%s" % [host, redirect_port, target]
	var body := ("Moved to %s\n" % url).to_utf8_buffer()
	var hdr := "HTTP/1.1 301 Moved Permanently\r\nLocation: %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" % [url, body.size()]
	c.out = hdr.to_ascii_buffer()
	c.out.append_array(body)

var server_host_fallback := "localhost"

static func _is_host_name(h: String) -> bool:
	if h.length() > 253:
		return false
	for ch in h:
		if not (ch.is_valid_identifier() or ch == "-" or ch == "." or ch.is_valid_int()):
			return false
	return true
