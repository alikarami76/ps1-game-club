class_name GameServer
extends Node
## Dedicated headless server: one game port (WebSocket by default), many lobbies, each lobby's
## match isolated in its own World3D. Also serves the web build (dist/web/) so browsers on the
## LAN can open the game. Never serves gamedata/ or cache/.
##
## TLS (default): Chrome runs Godot web builds only in a secure context, and a plain
## http://<LAN ip> page is not one. So the web build is served over HTTPS (--https-port, 8443),
## the game port speaks wss:// (an https page cannot open ws://), and the old --http-port (8080)
## only redirects to the https address. All use one self-signed certificate (ServerTLS, kept in
## user://tls/, with subjectAltName localhost + the LAN addresses). Browsers open the game
## connection on the page's own address (wss://<page host:port>/ws, forwarded by WebFileServer to
## the game port on loopback), because Chrome's "Proceed" on a self-signed certificate covers only
## the page's origin; desktop clients use the game port directly. Desktop clients try wss first (accepting the self-signed certificate) and fall
## back to ws. --no-tls: plain http on --http-port and plain ws, for testing on this machine
## only (http://localhost counts as secure; http://<LAN ip> does not).
##
## Run: Godot --headless --path game -- --server [--port=8910] [--https-port=8443]
##      [--http-port=8080] [--no-tls] [--tls-cert=PATH --tls-key=PATH] [--web-root=PATH]
##      [--transport=enet] [--server-name=NAME]

var transport: Transport
var http: WebFileServer
var peers: Dictionary = {}            # peer -> {name, lobby (Lobby or null), hello}
var lobbies: Dictionary = {}          # id -> Lobby
var next_lobby_id := 1
var lobbies_dirty := false
var port := 8910
var http_port := 8080
var https_port := 8443
var use_tls := true
var behind_proxy := false             # --behind-proxy / TM_BEHIND_PROXY=1: plain http, access gate, game port on loopback only
var gate: AccessGate = null
var https: WebFileServer
var tls: ServerTLS
var server_name := "Arena Wheels server"
var _stat_acc := 0.0
var _stat_last_out := 0
var _stat_last_in := 0

static func clean_name(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			out += ch
	out = out.strip_edges().left(16)
	return out if out != "" else "Player"

## The built-in arena plus every arena in this server's own game data (needed for collision).
func arena_ids() -> Array:
	return Game.local_arena_ids()

## A new lobby starts on the first game-data arena its creator also has. When the server has
## game data but the creator has none, it still starts on the server's first game-data arena
## (the lobby then shows who lacks it and why Start is disabled). The built-in test yard is the
## default only when the server has no game data.
func default_arena_for(peer: int) -> String:
	var theirs: Array = peers.get(peer, {}).get("arenas", [])
	for a in arena_ids():
		if a != Game.TEST_YARD and a in theirs:
			return a
	for a in arena_ids():
		if a != Game.TEST_YARD:
			return a
	return Game.TEST_YARD

func _ready() -> void:
	process_physics_priority = -2000
	port = int(Game.args.get("port", "8910"))
	http_port = int(Game.args.get("http-port", "8080"))
	# --http-port=0 alone keeps meaning "no web serving" (tests); --https-port=N turns it back on
	https_port = int(Game.args.get("https-port", "0" if http_port == 0 else "8443"))
	server_name = str(Game.args.get("server-name", server_name))
	var kind := Transport.kind_from_name(str(Game.args.get("transport", "websocket")))
	behind_proxy = Game.args.has("behind-proxy") or OS.get_environment("TM_BEHIND_PROXY") in ["1", "true"]
	use_tls = not Game.args.has("no-tls") and not behind_proxy
	if behind_proxy:
		gate = AccessGate.new()
		if not gate.setup(OS.get_environment("TM_ACCESS_KEY")):
			printerr("[server] --behind-proxy needs the environment variable TM_ACCESS_KEY (a long random secret, at least %d characters). Refusing to start without it." % AccessGate.MIN_KEY_LEN)
			get_tree().quit(1)
			return
		http_port = int(Game.args.get("http-port", OS.get_environment("PORT") if OS.get_environment("PORT") != "" else "80"))
	var tls_opts: TLSOptions = null
	if use_tls:
		tls = ServerTLS.new()
		if tls.setup(lan_addresses(), str(Game.args.get("tls-cert", "")), str(Game.args.get("tls-key", ""))) != OK:
			printerr("[server] TLS setup failed; run with --no-tls for plain http (this machine only)")
			get_tree().quit(1)
			return
		tls_opts = tls.server_options()
		if not tls.alt_names.is_empty():
			print("[tls] certificate names: %s" % ", ".join(tls.alt_names))
	transport = Transport.new()
	transport.name = "Transport"
	add_child(transport)
	transport.peer_joined.connect(_on_peer_joined)
	transport.peer_left.connect(_on_peer_left)
	transport.packet.connect(_on_packet)
	var err := transport.listen(port, kind, "127.0.0.1" if behind_proxy else "*", tls_opts)
	if err != OK:
		printerr("[server] could not listen on port %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	var wss := tls_opts != null and kind == Transport.Kind.WEBSOCKET
	print("[server] %s listening on port %d (%s), tick %d Hz, snapshots %d Hz" % [server_name, port, "enet" if kind == Transport.Kind.ENET else ("websocket wss" if wss else "websocket ws"), Proto.TICK_RATE, int(Proto.SNAP_RATE)])
	var root := str(Game.args.get("web-root", ProjectSettings.globalize_path("res://").path_join("../dist/web").simplify_path()))
	var web_on := false
	if use_tls and https_port > 0:
		https = _web_server("Https", root, wss)
		https.tls = tls_opts
		web_on = _listen_web(https, https_port, "HTTPS")
		if web_on:
			print("[server] browsers play over wss://<address>:%d/ws (same address as the page, forwarded to the game port)" % https_port)
		if http_port > 0 and http_port != https_port:
			http = _web_server("HttpRedirect", root, wss)
			http.redirect_port = https_port
			http.server_host_fallback = lan_addresses()[0]
			if _listen_web(http, http_port, "HTTP redirect"):
				print("[server] http://<address>:%d/ redirects to https://<address>:%d/" % [http_port, https_port])
	elif behind_proxy:
		http = _web_server("Http", root, false)
		http.gate = gate
		web_on = _listen_web(http, http_port, "HTTP")
		if not web_on:
			get_tree().quit(1)
			return
		print("[server] behind a proxy: plain http on port %d, every path except /healthz and /login needs the access cookie" % http_port)
	elif not use_tls and http_port > 0:
		http = _web_server("Http", root, false)
		web_on = _listen_web(http, http_port, "HTTP")
	if web_on:
		print("[server] serving the web game from %s" % root)
	for a in ([] if behind_proxy else lan_addresses()):
		print("[server] LAN: desktop clients connect to %s:%d" % [a, port])
	if behind_proxy:
		pass
	elif web_on and use_tls:
		var a0: String = lan_addresses()[0]
		print("")
		print("[server] Open https://%s:%d/ in Chrome. The first time, Chrome warns that the connection is not private: click Advanced, then Proceed. This is expected with a self-signed certificate on your own network." % [a0, https_port])
		for a in lan_addresses().slice(1):
			print("[server] (also reachable at https://%s:%d/)" % [a, https_port])
		print("")
	elif web_on:
		print("[server] --no-tls: open http://localhost:%d/ in Chrome on THIS machine only. Other machines must use the default TLS mode (Chrome refuses Godot web builds on a plain http LAN address)." % http_port)

func _web_server(n: String, root: String, wss: bool) -> WebFileServer:
	var w := WebFileServer.new()
	w.name = n
	w.ws_port = port
	w.ws_scheme = "wss" if wss else "ws"
	# /ws on the page's own port; --no-ws-proxy turns it off (browsers then use the game port)
	w.ws_proxy = transport.kind == Transport.Kind.WEBSOCKET and not Game.args.has("no-ws-proxy")
	w.poll_game = func():
		transport.poll()   # read what the browsers just sent
		transport.poll()   # and flush any immediate answers (pongs)
	w.server_name = server_name
	add_child(w)
	w.root = root
	if GameData.has_data():
		# loopback-only: lets a browser on this machine load the server's game data by itself
		w.set_local_data(GameData.root(), GameData.listed_files(GameData.manifest()))
	return w

func _listen_web(w: WebFileServer, p: int, what: String) -> bool:
	var e := w.listen(p, w.root)
	if e != OK:
		printerr("[server] %s: could not listen on port %d: %s" % [what, p, error_string(e)])
		return false
	return true

static func lan_addresses() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	if out.is_empty():
		out.append("127.0.0.1")
	return out

func send_to(peer: int, data: PackedByteArray, reliable: bool) -> void:
	transport.send(peer, data, reliable)

func _on_peer_joined(id: int) -> void:
	peers[id] = {"name": "Player", "lobby": null, "hello": false, "arenas": [], "disc_vehicles": false}

func _on_peer_left(id: int) -> void:
	var p: Dictionary = peers.get(id, {})
	if not p.is_empty() and p.lobby != null:
		print("[server] %s left (lobby %s)" % [p.name, p.lobby.name])
		p.lobby.remove_member(id)
	peers.erase(id)
	lobbies_dirty = true

func _on_packet(from: int, p: PackedByteArray) -> void:
	if p.is_empty() or not peers.has(from):
		return
	var info: Dictionary = peers[from]
	match p[0]:
		Proto.CTRL:
			_on_ctrl(from, info, Proto.parse_ctrl(p))
		Proto.C_INPUT:
			var lb: Lobby = info.lobby
			if lb != null and lb.match_node != null:
				lb.match_node.server_on_input(from, p)
		Proto.C_PING:
			if p.size() >= 5:
				var w := PackedByteArray([Proto.S_PONG])
				w.append_array(p.slice(1, 5))
				transport.send(from, w, false)

func _err(peer: int, msg: String) -> void:
	send_to(peer, Proto.ctrl({"t": "error", "msg": msg}), true)

func _on_ctrl(peer: int, info: Dictionary, d: Dictionary) -> void:
	var t := str(d.get("t", ""))
	if t != "hello" and not info.hello:
		return
	match t:
		"hello":
			if int(d.get("v", 0)) != Proto.VERSION:
				_err(peer, "Version mismatch: server %d, client %d" % [Proto.VERSION, int(d.get("v", 0))])
				get_tree().create_timer(0.5).timeout.connect(func(): transport.disconnect_peer(peer))
				return
			info.hello = true
			info.name = clean_name(str(d.get("name", "Player")))
			# arena ids and a flag only: the client's own game data never travels
			var arenas: Array = []
			if typeof(d.get("arenas")) == TYPE_ARRAY:
				for a in d.arenas.slice(0, 64):
					if str(a) in arena_ids():
						arenas.append(str(a))
			info.arenas = arenas
			info.disc_vehicles = bool(d.get("disc_vehicles", false))
			send_to(peer, Proto.ctrl({"t": "welcome", "id": peer, "server": server_name}), true)
			print("[server] %s connected (peer %d)" % [info.name, peer])
		"list":
			send_to(peer, _list_msg(), true)
		"create":
			_leave(peer, info)
			var lb := _create_lobby(str(d.get("name", "")), info.name)
			_join(peer, info, lb)
			# optional: settings applied to the new lobby by its creator (the host), e.g.
			# {"mode": "tournament", "difficulty": "normal"}, and "start": true to begin at once
			if info.lobby == lb:
				if typeof(d.get("settings")) == TYPE_DICTIONARY:
					lb.set_settings(peer, d.settings)
				if bool(d.get("start", false)):
					lb.start(peer)
		"join":
			var lb2: Lobby = lobbies.get(int(d.get("id", -1)))
			if lb2 == null:
				_err(peer, "That lobby no longer exists")
				return
			_leave(peer, info)
			_join(peer, info, lb2)
		"join_name":
			var want := clean_name(str(d.get("name", "")))
			var found: Lobby = null
			for lb3 in lobbies.values():
				if lb3.name == want and not lb3.is_full():
					found = lb3
					break
			_leave(peer, info)
			if found == null:
				found = _create_lobby(want, info.name)
			_join(peer, info, found)
		"leave":
			_leave(peer, info)
			send_to(peer, Proto.ctrl({"t": "left"}), true)
			send_to(peer, _list_msg(), true)
		"set":
			if info.lobby != null:
				if d.has("name"):
					info.name = clean_name(str(d.name))
				info.lobby.set_member(peer, d)
		"settings":
			if info.lobby != null and typeof(d.get("settings")) == TYPE_DICTIONARY:
				info.lobby.set_settings(peer, d.settings)
		"start":
			if info.lobby != null:
				info.lobby.start(peer)
		"match_loaded":
			if info.lobby != null and info.lobby.match_node != null:
				info.lobby.match_node.server_on_ready(peer)

func _create_lobby(lname: String, owner_name: String) -> Lobby:
	lname = clean_name(lname) if lname.strip_edges() != "" else "%s's lobby" % owner_name.left(8)
	var lb := Lobby.new(next_lobby_id, lname, self)
	lobbies[next_lobby_id] = lb
	next_lobby_id += 1
	print("[server] lobby %d '%s' created" % [lb.id, lb.name])
	lobbies_dirty = true
	return lb

func _join(peer: int, info: Dictionary, lb: Lobby) -> void:
	if not lb.add_member(peer, info.name):
		_err(peer, "That lobby is full")
		send_to(peer, _list_msg(), true)
		return
	info.lobby = lb
	print("[server] %s joined lobby '%s' (%d/%d, %s)" % [info.name, lb.name, lb.members.size(), Lobby.MAX_PLAYERS, lb.state])

func _leave(peer: int, info: Dictionary) -> void:
	if info.lobby != null:
		var lb: Lobby = info.lobby
		info.lobby = null
		lb.remove_member(peer)

func on_lobby_closed(lb: Lobby) -> void:
	lobbies.erase(lb.id)
	lobbies_dirty = true
	print("[server] lobby '%s' closed (empty)" % lb.name)

func _list_msg() -> PackedByteArray:
	var l: Array = []
	for lb in lobbies.values():
		l.append(lb.list_entry())
	return Proto.ctrl({"t": "lobbies", "list": l})

func report_match(lb: Lobby) -> void:
	var m = lb.match_node
	if m == null:
		return
	var n := maxi(m.tick_count, 1)
	print("[server-match] lobby=%s arena=%s ticks=%d tick_avg=%.3f ms tick_max=%.3f ms snaps=%d avg_snap=%.1f B full=%d falls=%d bot_resets=%d" % [
		lb.name, m.arena_id, m.tick_count, m.tick_usec_sum / float(n) / 1000.0, m.tick_usec_max / 1000.0, m.snaps_sent,
		m.bytes_snap / float(maxi(m.snaps_sent, 1)), m.full_snaps, m.falls, m.bot_resets])
	for c in m.conns.values():
		print("[server-match]   peer=%d slot=%d holds=%d repeats=%d" % [c.peer, c.slot, c.holds, c.repeats])
	var odo: Array = []
	for v in m.vehicles.values():
		if v.is_bot():
			odo.append("%s=%.0fm" % [v.vid, v.odometer])
	if not odo.is_empty():
		print("[server-match]   bot_stuck_events=%d bot distance: %s" % [m.bot_stuck, " ".join(odo)])

func _process(delta: float) -> void:
	if lobbies_dirty:
		lobbies_dirty = false
		var msg := _list_msg()
		for id in peers:
			if peers[id].hello and peers[id].lobby == null:
				send_to(id, msg, true)
	_stat_acc += delta
	if _stat_acc >= 10.0:
		var out_rate := (transport.bytes_out - _stat_last_out) / _stat_acc
		var in_rate := (transport.bytes_in - _stat_last_in) / _stat_acc
		_stat_last_out = transport.bytes_out
		_stat_last_in = transport.bytes_in
		_stat_acc = 0.0
		var parts: Array = []
		for lb in lobbies.values():
			var m = lb.match_node
			if m != null:
				var n := maxi(m.tick_count, 1)
				parts.append("%s:%s %dp tick_avg=%.2fms max=%.2fms" % [lb.name, lb.state, lb.members.size(), m.tick_usec_sum / float(n) / 1000.0, m.tick_usec_max / 1000.0])
			else:
				parts.append("%s:%s %dp" % [lb.name, lb.state, lb.members.size()])
		print("[server-stats] peers=%d lobbies=%d out=%.0f B/s in=%.0f B/s physics_frame=%.2f ms | %s" % [peers.size(), lobbies.size(), out_rate, in_rate,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, " | ".join(parts)])
