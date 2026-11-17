extends Node
## Client connection to a game server: lobby browser, lobby membership, match routing.
## The server is a separate headless process (see scripts/server/game_server.gd); browsers
## cannot host, so desktop and web clients use exactly the same path.
##
## Lobby control messages are small JSON objects (Proto.CTRL). The game stream (inputs,
## snapshots, events) is binary and handled by the match scene.

signal state_changed
signal lobbies_changed
signal lobby_changed
signal error_message(text: String)
## Web: no game connection worked (the browser refused it). cert_url is a page on the game port
## the player can open to accept the certificate there too ("" when not https).
signal web_connect_failed(cert_url: String)

const MENU := "res://scenes/main_menu.tscn"
const MATCH := "res://scenes/match.tscn"
const DEFAULT_PORT := 8910
const DEFAULT_HTTP_PORT := 8080
const DEFAULT_HTTPS_PORT := 8443

var transport: Transport
var state := "offline"        # offline, connecting, browser, lobby, match
var my_id := 0
var lobbies: Array = []
var lobby: Dictionary = {}
var match_roster: Dictionary = {}
var match_settings: Dictionary = {}
var tour_last: Dictionary = {}   # tournament outcome from the last match_end: {won, level, finished}
var my_slot := -1
var match_node: Node = null
var rtt_ms := 0
var server_host := ""
var server_port := DEFAULT_PORT
var server_scheme := ""       # "ws", "wss", or "" = try wss, then ws (desktop)
var server_url := ""          # full ws:// or wss:// URL when one was given (path kept, e.g. /ws)
var _web_urls: Array = []     # web: URLs still to try, first = the current one
var web_cert_url := ""
var _scheme_now := "wss"
var local_server_pid := -1
var _ping_acc := 0.0
var _ping_seq := 0
var _list_acc := 0.0
var _auto := {}               # headless test automation (from command line)
var _connect_tries := 0
var _leaving := false          # sent "leave", ignore lobby updates until the server confirms

func _ready() -> void:
	transport = Transport.new()
	transport.name = "Transport"
	add_child(transport)
	transport.connected.connect(_on_connected)
	transport.connect_failed.connect(_on_connect_failed)
	transport.disconnected.connect(_on_disconnected)
	transport.packet.connect(_on_packet)

func is_web() -> bool:
	return OS.has_feature("web")

func transport_kind() -> Transport.Kind:
	if is_web():
		return Transport.Kind.WEBSOCKET
	return Transport.kind_from_name(str(Game.args.get("transport", "websocket")))

## host may be "host", "host:port", or a ws:// / wss:// URL (with a path, e.g.
## wss://host:8443/ws). scheme "" (desktop default): try wss first (the server's default,
## self-signed certificate accepted), then plain ws (a --no-tls server). The web page uses
## web_connect() instead.
func connect_to_server(host: String, port := DEFAULT_PORT, scheme := "") -> Error:
	host = host.strip_edges()
	server_url = ""
	if host.begins_with("wss://") or host.begins_with("ws://"):
		scheme = "wss" if host.begins_with("wss://") else "ws"
		var rest := host.split("://", true, 1)[1]
		var slash := rest.find("/")
		if slash >= 0 and rest.substr(slash) != "/":
			server_url = host
		host = rest.substr(0, slash) if slash >= 0 else rest
		if not host.contains(":"):
			port = 443 if scheme == "wss" else 80
	if host.contains(":") and not host.ends_with("]"):
		var hp := host.rsplit(":", true, 1)
		host = hp[0]
		port = int(hp[1])
	server_host = host
	server_port = port
	server_scheme = scheme
	_scheme_now = scheme if scheme != "" else "wss"
	return _connect_now()

func _connect_now() -> Error:
	var host := server_host if server_url == "" else server_url
	var port := server_port
	var err := transport.connect_to(host, port, transport_kind(), _scheme_now)
	if err != OK:
		return err
	transport.configure_sim(float(Game.args.get("net-latency", "0")), float(Game.args.get("net-jitter", "0")),
		float(Game.args.get("net-loss", "0")), str(Game.args.get("net-loss-mode", "")))
	_set_state("connecting")
	print("[net] connecting to %s" % (server_url if server_url != "" else "%s:%d (%s)" % [host, port, "enet" if transport.kind == Transport.Kind.ENET else _scheme_now]))
	return OK

func disconnect_from_server() -> void:
	_leaving = false
	transport.close()
	lobby = {}
	lobbies = []
	_set_state("offline")

func _set_state(s: String) -> void:
	state = s
	state_changed.emit()

func send_ctrl(d: Dictionary) -> void:
	transport.send(1, Proto.ctrl(d), true)

func send_game(data: PackedByteArray, reliable: bool) -> void:
	transport.send(1, data, reliable)

# ---------------- lobby actions ----------------
func request_list() -> void:
	send_ctrl({"t": "list"})

## Creates a lobby and joins it as host. `arg` is the lobby name, or a Dictionary of options:
## {"name": String, "settings": {...}, "start": bool}; any other key is taken as a setting, so
## create_lobby({"mode": "tournament", "difficulty": "normal", "start": true}) makes a one-player
## tournament lobby and starts level 1 at once (settings: mode "deathmatch"|"tournament",
## difficulty "easy"|"normal"|"hard", pickup_respawn 30|60|96, arena, bots, score_limit, time_limit).
func create_lobby(arg: Variant = "", settings := {}) -> void:
	_leaving = false
	var msg := {"t": "create", "name": ""}
	if typeof(arg) == TYPE_DICTIONARY:
		var s: Dictionary = (arg.get("settings", {}) as Dictionary).duplicate()
		for k in arg:
			if k != "name" and k != "start" and k != "settings":
				s[k] = arg[k]
		msg.name = str(arg.get("name", ""))
		msg.settings = s
		msg.start = bool(arg.get("start", false))
	else:
		msg.name = str(arg)
		if not settings.is_empty():
			msg.settings = settings
	send_ctrl(msg)

## One call for the main menu's "Tournament": a one-player tournament lobby, level 1 started.
func create_tournament(difficulty := "normal", start := true) -> void:
	create_lobby({"name": "Tournament", "mode": "tournament", "difficulty": difficulty, "start": start})

func join_lobby(id: int) -> void:
	_leaving = false
	send_ctrl({"t": "join", "id": id})

func join_or_create(lname: String) -> void:
	_leaving = false
	send_ctrl({"t": "join_name", "name": lname})

func leave_lobby() -> void:
	send_ctrl({"t": "leave"})
	_leaving = true
	lobby = {}
	_set_state("browser")
	_go_menu()

## with_vehicle: also ask for Game.player_vid (the server keeps its choice when that vehicle
## is not available to this player).
func set_me(ready: bool, with_vehicle := true) -> void:
	var d := {"t": "set", "ready": ready, "color": Game.player_color.to_html(false), "name": Game.player_name}
	if with_vehicle and Game.player_vid != "":
		d.vid = Game.player_vid
	send_ctrl(d)

func set_settings(s: Dictionary) -> void:
	send_ctrl({"t": "settings", "settings": s})

func start_match() -> void:
	send_ctrl({"t": "start"})

func is_lobby_host() -> bool:
	return not lobby.is_empty() and int(lobby.get("host", 0)) == my_id

func me_in_lobby() -> Dictionary:
	for m in lobby.get("members", []):
		if int(m.peer) == my_id:
			return m
	return {}

# ---------------- transport events ----------------
func _on_connected() -> void:
	_connect_tries = 0
	_web_urls.clear()
	# Only ids of the arenas this computer can load (and whether it has vehicle models) are
	# sent, so the lobby knows who can play where; no game data ever leaves this computer.
	send_ctrl({"t": "hello", "name": Game.player_name, "v": Proto.VERSION,
		"arenas": Array(Game.disc_arena_ids()), "disc_vehicles": not Game.disc_vehicle_ids().is_empty()})

func _on_connect_failed() -> void:
	if not _web_urls.is_empty():
		print("[net] could not connect to %s" % _web_urls[0])
		_web_urls.pop_front()
		if not _web_urls.is_empty() and connect_to_server(_web_urls[0]) == OK:
			return
		_set_state("offline")
		error_message.emit("Your browser did not accept the connection to the game server.")
		web_connect_failed.emit(web_cert_url)
		return
	if server_scheme == "" and _scheme_now == "wss" and transport_kind() == Transport.Kind.WEBSOCKET:
		_scheme_now = "ws"    # maybe a --no-tls server
		if _connect_now() == OK:
			return
	if _auto.get("retry", false) and _connect_tries < 30:
		_connect_tries += 1
		get_tree().create_timer(0.5).timeout.connect(func(): connect_to_server(server_url if server_url != "" else server_host, server_port, server_scheme))
		return
	_set_state("offline")
	error_message.emit("Could not connect to %s:%d" % [server_host, server_port])

func _on_disconnected() -> void:
	print("[net] disconnected from server")
	lobby = {}
	_set_state("offline")
	Game.last_message = "Disconnected from the server"
	error_message.emit(Game.last_message)
	_go_menu()
	if _auto.has("quit_on_disconnect"):
		get_tree().quit()

func _on_packet(_from: int, p: PackedByteArray) -> void:
	if p.is_empty():
		return
	match p[0]:
		Proto.CTRL:
			_on_ctrl(Proto.parse_ctrl(p))
		Proto.S_PONG:
			if p.size() >= 5:
				var sent := p.decode_u32(1)
				var now := Time.get_ticks_msec() & 0xFFFFFFFF
				var r := now - sent
				if r >= 0 and r < 10000:
					rtt_ms = r if rtt_ms == 0 else roundi(lerpf(rtt_ms, r, 0.25))
		Proto.S_SNAP, Proto.S_EVENTS:
			if match_node != null and is_instance_valid(match_node):
				match_node.on_packet(p)

func _on_ctrl(d: Dictionary) -> void:
	match str(d.get("t", "")):
		"welcome":
			my_id = int(d.id)
			print("[net] connected as peer %d; server '%s'" % [my_id, d.get("server", "")])
			_set_state("browser")
			request_list()
			_auto_after_welcome()
		"lobbies":
			lobbies = d.get("list", [])
			lobbies_changed.emit()
		"lobby":
			if _leaving:
				return
			var was_in := not lobby.is_empty()
			lobby = d.get("lobby", {})
			if not was_in and state != "match":
				_set_state("lobby")
				print("[net] in lobby '%s' (%d)" % [lobby.get("name", ""), int(lobby.get("id", 0))])
			lobby_changed.emit()
			if match_node != null and is_instance_valid(match_node) and d.has("roster"):
				match_node.on_roster(d.roster)
			_auto_lobby()
		"left":
			_leaving = false
			lobby = {}
			_set_state("browser")
			_go_menu()
		"error":
			error_message.emit(str(d.get("msg", "Error")))
			print("[net] server says: %s" % d.get("msg", ""))
		"match_start":
			match_roster = d.get("roster", {})
			match_settings = d.get("settings", {})
			my_slot = int(d.get("slot", -1))
			_set_state("match")
			print("[net] match starting, my slot %d, %d vehicles" % [my_slot, match_roster.size()])
			get_tree().change_scene_to_file(MATCH)
		"match_end":
			tour_last = d.get("tour", {})
			print("[net] match ended, back to the lobby")
			if match_node != null and is_instance_valid(match_node) and Game.last_results.is_empty():
				match_node._store_results(-1)
			match_node = null
			_set_state("lobby")
			_go_menu()
			if _auto.has("matches"):
				_auto.matches -= 1
				if _auto.matches <= 0:
					get_tree().create_timer(1.0).timeout.connect(get_tree().quit)

func _go_menu() -> void:
	var cur := get_tree().current_scene
	if cur == null or cur.scene_file_path != MENU:
		get_tree().change_scene_to_file(MENU)

func _process(delta: float) -> void:
	if not transport.is_connected_to_server():
		return
	_ping_acc += delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		var w := Proto.writer()
		w.put_u8(Proto.C_PING)
		w.put_u32(Time.get_ticks_msec() & 0xFFFFFFFF)
		transport.send(1, w.data_array, false)
	if state == "browser":
		_list_acc += delta
		if _list_acc >= 3.0:
			_list_acc = 0.0
			request_list()

# ---------------- local server (desktop) ----------------
## Starts a headless server process on this machine and connects to it.
func start_local_server(port := DEFAULT_PORT, http_port := DEFAULT_HTTP_PORT, https_port := DEFAULT_HTTPS_PORT) -> Error:
	if is_web():
		return ERR_UNAVAILABLE
	var args := PackedStringArray()
	args.append("--headless")
	if OS.has_feature("editor") or FileAccess.file_exists("res://project.godot") and not OS.has_feature("template"):
		args.append("--path")
		args.append(ProjectSettings.globalize_path("res://"))
	args.append("--")
	args.append("--server")
	args.append("--port=%d" % port)
	args.append("--http-port=%d" % http_port)
	args.append("--https-port=%d" % https_port)
	if GameData.has_data():
		args.append("--data=%s" % ProjectSettings.globalize_path(GameData.root()))   # same game data as this client
	for k in ["exit-after", "vehicle-collision", "no-disc-models", "verbose"]:
		if Game.args.has(k):
			args.append("--%s=%s" % [k, Game.args[k]])
	stop_local_server()
	local_server_pid = OS.create_process(OS.get_executable_path(), args)
	if local_server_pid <= 0:
		local_server_pid = -1
		return FAILED
	print("[net] started local server, pid %d" % local_server_pid)
	_auto["retry"] = true
	_connect_tries = 0
	get_tree().create_timer(0.8).timeout.connect(func(): connect_to_server("127.0.0.1", port))
	return OK

func stop_local_server() -> void:
	if local_server_pid > 0:
		OS.kill(local_server_pid)
		local_server_pid = -1

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		stop_local_server()

# ---------------- web: server address ----------------
## On the web the server is the machine that served the page. The game connection goes to the
## page's own host and port, path /ws (/server.json ws_url), which the server forwards to its game
## port: Chrome's "Advanced > Proceed" on the self-signed certificate covers only the page's
## origin, so a separate port could be refused. If that fails, the game port itself is tried
## (/server.json ws_port). If both fail, web_connect_failed(cert_url) lets the menu offer a link
## to accept the certificate on the game port, then Retry. An https page can only open wss://.
func web_connect() -> void:
	var host := str(JavaScriptBridge.eval("location.hostname", true))
	var page_host := str(JavaScriptBridge.eval("location.host", true))
	var page_scheme := "wss" if str(JavaScriptBridge.eval("location.protocol", true)) == "https:" else "ws"
	if host.contains(":") and not host.begins_with("["):
		host = "[%s]" % host
	web_server_info(func(d: Dictionary):
		var scheme := "wss" if page_scheme == "wss" else str(d.get("ws_scheme", "ws"))
		var port := int(d.get("ws_port", DEFAULT_PORT))
		var urls: Array = []
		var same := str(d.get("ws_url", ""))
		if same == "" and d.has("ws_path"):
			same = "%s://%s%s" % [scheme, page_host, str(d.ws_path)]
		if same.begins_with(scheme + "://"):
			urls.append(same)
		urls.append("%s://%s:%d" % [scheme, host, port])
		web_cert_url = "https://%s:%d/" % [host, port] if scheme == "wss" else ""
		_web_urls = urls
		if Game.args.has("lobby") and _auto.is_empty():
			_auto = {"web": true}     # ?lobby=... test automation (see Game._web_args)
		if connect_to_server(urls[0]) != OK:
			_on_connect_failed())

## Web: the page server's /server.json as a Dictionary (empty when it could not be read). For a
## browser on the server machine itself it also has local_data = true and data_id.
func web_server_info(cb: Callable) -> void:
	var origin := str(JavaScriptBridge.eval("location.protocol + '//' + location.host", true))
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, code, _h, body):
		req.queue_free()
		var d = JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null
		cb.call(d if typeof(d) == TYPE_DICTIONARY else {}))
	if req.request(origin + "/server.json") != OK:
		req.queue_free()
		cb.call({})

# ---------------- headless test automation ----------------
## --connect=HOST:PORT --lobby=NAME [--autostart=N] [--bots=N] [--score-limit=N] [--time-limit=S]
## [--matches=N]: connect, join (or create) the named lobby, mark ready; the lobby host starts the
## match once N humans are in. Used by tests/net/*.sh.
func auto_start() -> void:
	_auto = {"retry": true, "quit_on_disconnect": true}
	if Game.args.has("matches"):
		_auto.matches = int(Game.args.matches)
	var addr := str(Game.args.get("connect", "127.0.0.1:%d" % DEFAULT_PORT))
	connect_to_server(addr)

## --host [--solo]: start a local server, join it; --solo creates a lobby and starts a match with
## bots at once (default 7 bots, --arena=ID, --time-limit=S, --matches=N then quit).
func auto_host() -> void:
	_auto = {"retry": true}
	if Game.args.has("solo"):
		_auto.solo = true
		_auto.quit_on_disconnect = true
		if not Game.args.has("matches"):
			Game.args["matches"] = "1"
		_auto.matches = int(Game.args.matches)
		if not Game.args.has("autostart"):
			Game.args["autostart"] = "1"
		if not Game.args.has("bots"):
			Game.args["bots"] = "8"
		if not Game.args.has("lobby"):
			Game.args["lobby"] = "Solo"
	var port := int(Game.args.get("port", str(DEFAULT_PORT)))
	if start_local_server(port, int(Game.args.get("http-port", "0"))) != OK:
		printerr("[net] could not start the local server")
		get_tree().quit(1)

func _auto_after_welcome() -> void:
	if _auto.is_empty():
		return
	if Game.args.has("lobby"):
		join_or_create(str(Game.args.lobby))

func _auto_lobby() -> void:
	if _auto.is_empty() or lobby.is_empty() or state != "lobby":
		return
	var me := me_in_lobby()
	if not me.is_empty() and not bool(me.get("ready", false)):
		set_me(true, Game.args.has("vehicle"))
	if is_lobby_host() and str(lobby.get("state", "")) == "waiting":
		var want := int(Game.args.get("autostart", "0"))
		var n: int = lobby.get("members", []).size()
		var all_ready := true
		for m in lobby.get("members", []):
			all_ready = all_ready and bool(m.get("ready", false))
		if want > 0 and n >= want and all_ready:
			var s := {}
			if Game.args.has("bots"):
				s.bots = int(Game.args.bots)
			if Game.args.has("score-limit"):
				s.score_limit = int(Game.args["score-limit"])
			if Game.args.has("time-limit"):
				s.time_limit = int(Game.args["time-limit"])
			if Game.args.has("arena"):
				s.arena = str(Game.args.arena)
			if Game.args.has("mode"):             # --mode=tournament [--level=N]: headless tournament test
				s.mode = str(Game.args.mode)
				if Game.args.has("level"):
					s.level = int(Game.args.level)
			if Game.args.has("difficulty"):
				s.difficulty = str(Game.args.difficulty)
			if Game.args.has("pickup-respawn"):
				s.pickup_respawn = int(Game.args["pickup-respawn"])
			if not _auto.has("settings_sent"):
				_auto.settings_sent = true
				set_settings(s)
				get_tree().create_timer(0.3).timeout.connect(start_match)
