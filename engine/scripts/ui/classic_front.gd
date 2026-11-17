class_name ClassicFront
extends Control
## The front end in the original game's layout and look, built at run time from the player's own
## disc: full-screen images (UASCREEN, UABIOS), the disc fonts (UAFONT1, CPFONT) driven by the
## glyph tables read from the player's executable, the cars' cards and driver portraits, and the
## disc's own names and texts. Nothing from the disc is stored in the project.
##
## Everything is drawn on a 320x240 stage (the original's screen), scaled to the window: 4:3
## letterboxed by default, or stretched ([video] screen = "stretch"). Positions are measured from
## emulator frames of the original (cache/fidelity/menus, not shipped).
##
## Flow: title -> main menu (LAN PLAY, TOURNAMENT, OPTIONS) -> LAN: driver, server, lobby list,
## lobby (= the original's vehicle select) -> match -> results -> lobby. TOURNAMENT starts a
## private lobby against bots. The lobby list, server and settings screens have no original;
## they use the same backdrops, fonts and highlight.
##
## Keys: up/down select, left/right change, Enter/Space confirm, Esc back (gamepad: d-pad, A, B).

const UI := preload("res://scripts/ui/disc_ui.gd")
const DiscSettingsS := preload("res://scripts/disc/disc_settings.gd")
const DiscArenaS := preload("res://scripts/disc/disc_arena_provider.gd")
const Ps1SettingsS := preload("res://scripts/render/ps1_settings.gd")

# colours measured from the original's frames
const C_ITEM := Color8(176, 56, 40)        # menu entry
const C_SEL := Color8(216, 112, 48)        # selected entry
const C_DIS := Color8(96, 40, 32)          # unavailable entry (dimmed red)
const C_GOLD := Color8(216, 160, 64)       # headings ("WELCOME!")
const C_NOTE := Color8(208, 200, 248)      # small text ("Player 1")
const C_ARROW := Color8(208, 200, 248)
const PITCH := 20                          # menu line spacing
const SW := 320.0
const SH := 240.0

var menu: Control                          # the modern menu (fallback pages)
var screen := ""
var sel := 0
var items: Array = []                      # [{text: Callable|String, do: Callable, lr: Callable, off: bool}]
var t := 0.0                               # seconds on this screen
var fade := 0.0
var msg := ""
var msg_t := 0.0
var editing := ""                          # key of the entry being typed into
var edit_buf := ""
var bio_page := 0
var lobby_scroll := 0
var sounds: MenuSounds
var preview: SubViewport
var turntable: Node3D
var cam: Camera3D
var preview_vid := ""
var fonts := {}

static var tournament := false             # the current lobby is a solo tournament
static var _pending_tournament := false
static var _start_when_ready := false
static var _title_seen := false

func _init(owner_menu: Control) -> void:
	menu = owner_menu

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_filter()
	focus_mode = Control.FOCUS_ALL
	for f in ["menu", "big", "small", "digits"]:
		fonts[f] = UI.font(f)
	sounds = MenuSounds.new()
	add_child(sounds)
	ClassicControls.apply()
	_setup_preview()
	Net.state_changed.connect(_on_net_state)
	Net.lobbies_changed.connect(func(): if screen == "lobbies": _build_items(true))
	Net.lobby_changed.connect(_on_lobby_changed)
	Net.error_message.connect(func(tx): _say(tx))
	if OS.has_feature("web"):
		Net.web_connect_failed.connect(_on_web_failed)
	resized.connect(queue_redraw)
	if Game.last_message != "":
		_say(Game.last_message)
		Game.last_message = ""
	get_viewport().gui_release_focus()
	sounds.play_track(0)

## Opens the screen matching the modern menu's page (or the net state).
func start(page: String) -> void:
	if Net.state == "lobby":
		if bool(Net.tour_last.get("finished", false)) and _is_tour():
			tournament = true
			_go("gameover" if not bool(Net.tour_last.get("won", false)) else "results")
		else:
			_go("results" if not Game.last_results.is_empty() else "lobby")
	elif Net.state == "browser":
		_go("lobbies")
	elif page == "server" and Net.state == "connecting":
		_go("lan")
	else:
		_go("main" if _title_seen else "title")

# ---------------- stage ----------------
func _stretch() -> bool:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return str(c.get_value("video", "screen", "letterbox")) == "stretch"

## Original pixels (UI upscaling off) are drawn at a whole-number scale when the window allows,
## so every pixel is the same size; upscaled art fills the window and is filtered.
func _apply_filter() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if UI.scale() == 1 else CanvasItem.TEXTURE_FILTER_LINEAR

func _stage() -> Transform2D:
	var s := size
	if _stretch():
		return Transform2D(Vector2(s.x / SW, 0), Vector2(0, s.y / SH), Vector2.ZERO)
	var k := minf(s.x / SW, s.y / SH)
	if UI.scale() == 1 and k >= 1.0:
		k = floorf(k)
	return Transform2D(Vector2(k, 0), Vector2(0, k), ((s - Vector2(SW, SH) * k) * 0.5).floor())

func _f(n: String):
	return fonts.get(n)

func _text(font: String, pos: Vector2, tx: String, col: Color) -> void:
	var f = _f(font)
	if f != null:
		f.draw(self, pos, tx, col)

func _ctext(font: String, cx: float, y: float, tx: String, col: Color) -> void:
	var f = _f(font)
	if f != null:
		f.draw_centered(self, cx, y, tx, col)

func _width(font: String, tx: String) -> int:
	var f = _f(font)
	return f.width(tx) if f != null else 0

func _bg(name: String, dim := 0.0) -> void:
	var tex := UI.screen(name)
	if tex != null:
		draw_texture_rect(tex, Rect2(0, 0, SW, SH), false)
	if dim > 0.0:
		draw_rect(Rect2(0, 0, SW, SH), Color(0, 0, 0, dim))

# ---------------- navigation ----------------
var _guard_until := 0

func _go(s: String, keep_sel := false) -> void:
	# a confirm that arrives right after a screen change belongs to the previous screen
	_guard_until = Time.get_ticks_msec() + 300
	if s != screen:
		fade = 0.25
		t = 0.0
		if not keep_sel:
			sel = 0
	screen = s
	editing = ""
	if s == "title":
		_title_seen = true
	if s == "lobby" or s == "carinfo":
		pass
	else:
		_clear_preview()
	_build_items()
	queue_redraw()

func _say(tx: String) -> void:
	msg = tx
	msg_t = 6.0
	queue_redraw()

func _item(text, action := Callable(), lr := Callable(), off := false) -> Dictionary:
	return {"text": text, "do": action, "lr": lr, "off": off}

func _label_of(it: Dictionary) -> String:
	var tx = it.text
	return str(tx.call()) if tx is Callable else str(tx)

func _build_items(keep := false) -> void:
	var old := sel
	items = []
	match screen:
		"title":
			pass
		"main":
			items = [_item("LAN PLAY", func(): _go("driver" if not Game.has_saved_name() else "lan")),
				_item("TOURNAMENT", func(): _go("tourney")),
				_item("OPTIONS", func(): _go("options"))]
			if not OS.has_feature("web"):
				items.append(_item("QUIT", func(): get_tree().quit()))
		"options":
			items = [_item(func(): return "CONTROLS: %s" % ClassicControls.NAMES[ClassicControls.preset()],
					func(): _go("controls"), func(d): ClassicControls.set_preset(posmod(ClassicControls.preset() + d, 4))),
				_item(UI.text("audio_controls", "AUDIO CONTROLS"), func(): _go("audio")),
				_item("VIDEO", func(): _go("video")),
				_item("DRIVER", func(): _go("driver")),
				_item("GAME DATA", _to_game_data),
				_item("EXIT", func(): _go("main"))]
		"controls":
			items = [_item("", func(): _go("options", true), func(d): ClassicControls.set_preset(posmod(ClassicControls.preset() + d, 4)))]
		"audio":
			items = [_item("MUSIC:", Callable(), func(d): MenuSounds.set_level("music", MenuSounds.level("music") + d)),
				_item(UI.text("effects", "EFFECTS:"), Callable(), func(d):
					MenuSounds.set_level("effects", MenuSounds.level("effects") + d)
					sounds.move()),
				_item(UI.text("play_track", "PLAY TRACK:"), func(): sounds.play_track(_track), func(d):
					_track = posmod(_track + d, maxi(GameData.music_paths().size(), 1))
					sounds.play_track(_track)),
				_item("EXIT", func(): _go("options", true))]
		"video":
			items = _video_items()
		"driver":
			items = [_item(func(): return "NAME: %s" % (edit_buf + ("_" if int(t * 3) % 2 == 0 else " ") if editing == "name" else Game.player_name.to_upper()),
					func(): _edit("name", Game.player_name)),
				_item("COLOUR:", Callable(), func(d): _cycle_colour(d)),
				_item("CONTINUE", func():
					Game.save_profile()
					_go("lan"))]
		"lan":
			if OS.has_feature("web"):
				items = [_item("FIND LOBBIES", _connect), _item("EXIT", func(): _go("main"))]
			else:
				items = [_item(func(): return "SERVER: %s" % (edit_buf + "_" if editing == "addr" else Game.server_addr), func(): _edit("addr", Game.server_addr)),
					_item("CONNECT", _connect),
					_item("HOST A SERVER", _host),
					_item("EXIT", func(): _go("main"))]
		"lobbies":
			for e in Net.lobbies:
				var lid := int(e.id)
				var full: bool = int(e.players) >= int(e.max)
				items.append(_item(str(e.name).to_upper(), func(): Net.join_lobby(lid), Callable(), full))
			items.append(_item(func(): return "NEW LOBBY: %s_" % edit_buf if editing == "lobby" else "CREATE LOBBY",
				func(): _edit("lobby", "%s's game" % Game.player_name)))
			items.append(_item("EXIT", func():
				Net.disconnect_from_server()
				_go("lan")))
		"lobby":
			items = _lobby_items()
		"battle":
			items = _battle_items()
		"carinfo":
			items = [_item("", _next_bio)]
		"tourney":
			items = [_item(func(): return "DIFFICULTY: %s" % _diff_label(_difficulty), Callable(), func(d): _difficulty = DIFFS[posmod(DIFFS.find(_difficulty) + d, 3)]),
				_item("START", _start_tournament),
				_item("EXIT", func(): _go("main", true))]
		"begin":
			items = [_item(UI.text("begin_battle", "BEGIN BATTLE"), _begin_battle),
				_item("OPTIONS", func(): _go("tour_opts")),
				_item("EXIT", func(): _go("lobby"))]
		"tour_opts":
			items = [_item(func(): return "DIFFICULTY: %s" % _diff_label(str(_settings().get("difficulty", "normal"))), Callable(),
					func(d):
						var i := DIFFS.find(str(_settings().get("difficulty", "normal")))
						Net.set_settings({"difficulty": DIFFS[posmod(i + d, 3)]})),
				_item(func(): return "CONTROLS: %s" % ClassicControls.NAMES[ClassicControls.preset()], Callable(),
					func(d): ClassicControls.set_preset(posmod(ClassicControls.preset() + d, 4))),
				_item("EXIT", func(): _go("begin", true))]
		"gameover":
			items = [_item("YES", func():
					Game.last_results = {}
					Net.tour_last = {}
					_go("begin")),
				_item("NO", func():
					Game.last_results = {}
					Net.tour_last = {}
					_leave_lobby())]
		"results":
			items = [_item("CONTINUE", _leave_results)]
		"pause":
			pass
	if keep:
		sel = clampi(old, 0, maxi(items.size() - 1, 0))
	else:
		sel = clampi(sel, 0, maxi(items.size() - 1, 0))
	while not items.is_empty() and items[sel].off and sel < items.size() - 1:
		sel += 1

var _track := 0

func _video_items() -> Array:
	var c := func(k: String, d): return Game.display_setting(k, d)
	var out: Array = []
	# shares the renderer's default: no key = PS1 ACCURATE
	out.append(_item(func(): return "RENDERING: %s" % ("PS1 ACCURATE" if Ps1SettingsS.get_value("ps1_accurate") else "MODERN"),
		Callable(), func(_d): _set_cfg("video", "ps1_rendering", not Ps1SettingsS.get_value("ps1_accurate"))))
	out.append(_item(func(): return "SCREEN: %s" % ("STRETCHED" if _stretch() else "4:3"),
		Callable(), func(_d):
			_set_cfg("video", "screen", "letterbox" if _stretch() else "stretch")
			queue_redraw()))
	out.append(_item(func(): return "3D UPSCALING: %s" % DiscSettingsS.UPSCALE_LABELS[maxi(DiscSettingsS.UPSCALE_CHOICES.find(DiscSettingsS.texture_upscale()), 0)].to_upper(),
		Callable(), func(d):
			var i := DiscSettingsS.UPSCALE_CHOICES.find(DiscSettingsS.texture_upscale())
			DiscSettingsS.set_texture_upscale(DiscSettingsS.UPSCALE_CHOICES[posmod(i + d, DiscSettingsS.UPSCALE_CHOICES.size())])
			DiscArenaS.clear_cache()))
	out.append(_item(func(): return "3D SCALE: %d" % roundi(float(c.call("render_scale", 1.0)) * 100.0),
		Callable(), func(d):
			var i := _nearest(Game.RENDER_SCALES, float(c.call("render_scale", 1.0)))
			Game.set_display_setting("render_scale", Game.RENDER_SCALES[clampi(i + d, 0, Game.RENDER_SCALES.size() - 1)])
			Game.apply_display_settings()))
	if not OS.has_feature("web"):
		out.append(_item(func(): return "WINDOW: %s" % ("FULL SCREEN" if bool(c.call("fullscreen", false)) else "WINDOWED"),
			Callable(), func(_d):
				Game.set_display_setting("fullscreen", not bool(c.call("fullscreen", false)))
				Game.apply_display_settings()))
		out.append(_item(func():
				var r: Vector2i = c.call("resolution", Vector2i(1280, 720))
				return "RESOLUTION: %dX%d" % [r.x, r.y],
			Callable(), func(d):
				var r: Vector2i = c.call("resolution", Vector2i(1280, 720))
				var i := maxi(Game.RESOLUTIONS.find(r), 0)
				Game.set_display_setting("resolution", Game.RESOLUTIONS[posmod(i + d, Game.RESOLUTIONS.size())])
				Game.apply_display_settings()))
	out.append(_item(func(): return "UI UPSCALING: %s" % {1: "OFF", 2: "2X", 4: "4X"}[UI.scale()],
		Callable(), func(d):
			UI.set_scale(UI.UPSCALE_CHOICES[posmod(UI.UPSCALE_CHOICES.find(UI.scale()) + d, 3)])
			for f in ["menu", "big", "small", "digits"]:
				fonts[f] = UI.font(f)
			_apply_filter()))
	out.append(_item(func(): return "NAME TAGS: %s" % ("ON" if bool(_cfg("video", "name_tags", false)) else "OFF"),
		Callable(), func(_d): _set_cfg("video", "name_tags", not bool(_cfg("video", "name_tags", false)))))
	out.append(_item("MENUS: ORIGINAL", Callable(), func(_d): _to_modern()))
	out.append(_item("EXIT", func(): _go("options", true)))
	return out

func _nearest(arr: Array, v: float) -> int:
	var best := 0
	for i in arr.size():
		if absf(float(arr[i]) - v) < absf(float(arr[best]) - v):
			best = i
	return best

func _cfg(sec: String, k: String, d):
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return c.get_value(sec, k, d)

func _set_cfg(sec: String, k: String, v) -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value(sec, k, v)
	c.save("user://settings.cfg")

func _cycle_colour(d: int) -> void:
	var pal: Array = menu.PALETTE
	var i := 0
	for k in pal.size():
		if Color.html(pal[k]).is_equal_approx(Game.player_color):
			i = k
	Game.player_color = Color.html(pal[posmod(i + d, pal.size())])
	Game.save_profile()

func _to_modern() -> void:
	_set_cfg("video", "menus", "modern")
	menu.call("classic_closed", "server" if Net.state == "offline" else "")
	queue_free()

func _to_game_data() -> void:
	menu.call("classic_closed", "data")
	queue_free()

# ---------------- text entry ----------------
func _edit(key: String, initial: String) -> void:
	editing = key
	edit_buf = "" if key == "name" and not Game.has_saved_name() else initial
	queue_redraw()

func _commit_edit() -> void:
	_guard_until = Time.get_ticks_msec() + 300
	var v := edit_buf.strip_edges()
	var key := editing
	editing = ""
	match key:
		"name":
			if v != "":
				Game.player_name = v.left(16)
				Game.save_profile()
		"addr":
			if v != "":
				Game.server_addr = v
				Game.save_profile()
		"lobby":
			if v != "":
				tournament = false
				Net.create_lobby(v.left(16))
	queue_redraw()

# ---------------- LAN ----------------
func _connect() -> void:
	_say("CONNECTING...")
	if OS.has_feature("web"):
		Net.web_connect()
		return
	if Net.connect_to_server(Game.server_addr) != OK:
		_say("COULD NOT CONNECT")

func _host() -> void:
	if Net.start_local_server() != OK:
		_say("COULD NOT START THE SERVER")
		return
	Game.server_addr = "127.0.0.1:%d" % Net.DEFAULT_PORT
	var ips := GameServer.lan_addresses()
	_say("SERVER STARTED. FRIENDS JOIN AT %s" % (("%s:%d" % [ips[0], Net.DEFAULT_PORT]) if not ips.is_empty() else Game.server_addr))

const DIFFS := ["easy", "normal", "hard"]
static var _difficulty := "normal"

func _diff_label(d: String) -> String:
	return {"easy": "EASY", "normal": "MEDIUM", "hard": "HARD"}.get(d, d.to_upper())

func _is_tour() -> bool:
	return str(Net.lobby.get("settings", {}).get("mode", "")) == "tournament"

## The original's one-player contest: a one-player tournament lobby on the server (this computer's
## own server on the desktop), then vehicle select, the begin-battle screen and the six levels.
func _start_tournament() -> void:
	_pending_tournament = true
	if Net.state == "browser":
		_create_tournament()
	elif Net.state == "lobby":
		Net.leave_lobby()
	elif OS.has_feature("web"):
		_say("CONNECTING...")
		Net.web_connect()
	else:
		_say("STARTING...")
		if Net.state == "offline" and Net.start_local_server() != OK:
			_pending_tournament = false
			_say("COULD NOT START THE SERVER")

func _create_tournament() -> void:
	_pending_tournament = false
	tournament = true
	Net.create_lobby({"name": "Tournament", "mode": "tournament", "difficulty": _difficulty, "start": false})

func _begin_battle() -> void:
	Game.player_vid = _my_vid()   # the car shown is the one the lobby holds for us
	_start_when_ready = true
	Net.set_me(true)
	if not tournament and not _is_tour():
		_say("WAITING FOR ALL PLAYERS TO BE READY")

func _on_web_failed(url: String) -> void:
	menu.call("classic_closed", "")
	menu.call("_on_web_connect_failed", url)
	queue_free()

func _on_net_state() -> void:
	if Net.state in ["browser", "lobby"] and msg.ends_with("..."):
		msg = ""
	match Net.state:
		"browser":
			if _pending_tournament:
				_create_tournament()
			elif screen in ["lan", "driver", "main", "lobby", "battle", "carinfo"]:
				if tournament:
					tournament = false
					Net.disconnect_from_server()
					_go("main")
				else:
					_go("lobbies")
		"lobby":
			if not (screen in ["lobby", "results", "battle", "carinfo", "begin", "tour_opts", "gameover"]):
				_go("lobby")
		"offline":
			_pending_tournament = false
			if screen in ["lobbies", "lobby", "battle", "results", "carinfo"]:
				var was := tournament
				tournament = false
				_go("main" if was else "lan")

var _pref_sent := false

func _on_lobby_changed() -> void:
	if Net.lobby.is_empty():
		_pref_sent = false
		return
	var lb := Net.lobby
	# ask once for the saved favourite car when this lobby offers it
	var me := Net.me_in_lobby()
	if not _pref_sent and not me.is_empty():
		_pref_sent = true
		if Game.player_vid in _choices() and str(me.get("vid", "")) != Game.player_vid:
			Net.set_me(bool(me.get("ready", false)))
	if _start_when_ready and Net.is_lobby_host():
		var all_ready := true
		for m in lb.get("members", []):
			all_ready = all_ready and bool(m.ready)
		if all_ready and str(lb.get("state", "")) == "waiting":
			_start_when_ready = false
			Net.start_match()
	if screen in ["lobby", "battle"]:
		_build_items(true)
	queue_redraw()

# ---------------- lobby (vehicle select) ----------------
func _choices() -> PackedStringArray:
	var offered: Array = Net.lobby.get("vehicles", [])
	var out := PackedStringArray()
	for id in Game.disc_vehicle_ids():
		if offered.is_empty() or id in offered:
			out.append(id)
	if out.is_empty():
		for id in Game.builtin_vehicle_ids():
			if offered.is_empty() or id in offered:
				out.append(id)
	return out

func _my_vid() -> String:
	var me := Net.me_in_lobby()
	var vid := str(me.get("vid", Game.player_vid))
	if not _pref_sent or (Game.player_vid != vid and Game.player_vid in _choices()):
		vid = Game.player_vid if Game.player_vid != "" else vid   # our request is on its way
	var ch := _choices()
	if not (vid in ch) and not ch.is_empty():
		vid = ch[0]
	return vid

func _my_ready() -> bool:
	return bool(Net.me_in_lobby().get("ready", false))

func _cycle_vehicle(d: int) -> void:
	var ch := _choices()
	if ch.is_empty():
		return
	Game.player_vid = ch[posmod(ch.find(_my_vid()) + d, ch.size())]
	Game.save_profile()
	Net.set_me(_my_ready())
	sounds.move()
	queue_redraw()

func _lobby_items() -> Array:
	if _is_tour():
		return [_item("SELECT", func(): _go("begin")),
			_item(UI.text("car_info", "CAR INFO"), func():
				bio_page = 0
				_go("carinfo")),
			_item("EXIT", _leave_lobby)]
	var host := Net.is_lobby_host()
	var first: Dictionary
	if host:
		first = _item("BEGIN BATTLE", _begin_battle)
	else:
		first = _item(func(): return "NOT READY" if _my_ready() else "READY", func(): Net.set_me(not _my_ready()))
	return [first, _item(UI.text("car_info", "CAR INFO"), func():
			bio_page = 0
			_go("carinfo")),
		_item("BATTLE SETTINGS", func(): _go("battle")),
		_item("EXIT", _leave_lobby)]

func _leave_lobby() -> void:
	_start_when_ready = false
	Net.leave_lobby()
	if tournament:
		tournament = false
		Net.disconnect_from_server()
		_go("main")
	else:
		_go("lobbies")

func _next_bio() -> void:
	bio_page += 1
	if bio_page >= UI.bio_pages(_my_vid()).size():
		_go("lobby", true)
		sel = 1
	queue_redraw()

func _arenas() -> Array:
	var mine := Game.local_arena_ids()
	var out: Array = []
	for a in Net.lobby.get("arenas", [Game.TEST_YARD]):
		if str(a) in mine:
			out.append(str(a))
	return out

func _settings() -> Dictionary:
	return Net.lobby.get("settings", {})

func _set_rule(k: String, v) -> void:
	var s := _settings().duplicate()
	s[k] = v
	Net.set_settings({"arena": str(s.get("arena", Game.TEST_YARD)), "score_limit": int(s.get("score_limit", 15)),
		"time_limit": int(s.get("time_limit", 300)), "bots": int(s.get("bots", 4))})

func _battle_items() -> Array:
	var off := not Net.is_lobby_host()
	return [
		_item(func(): return "ARENA: %s" % _arena_short(str(_settings().get("arena", Game.TEST_YARD))), Callable(), _lr_arena, off),
		_item(func(): return "OPPONENTS: %d" % int(_settings().get("bots", 4)), Callable(), _lr_bots, off),
		_item(func(): return "KILLS TO WIN: %d" % int(_settings().get("score_limit", 15)), Callable(), _lr_kills, off),
		_item(func(): return "TIME: %d MIN" % (int(_settings().get("time_limit", 300)) / 60), Callable(), _lr_time, off),
		_item(func(): return "DIFFICULTY: %s" % _diff_label(str(_settings().get("difficulty", "normal"))), Callable(),
			func(d): Net.set_settings({"difficulty": DIFFS[posmod(DIFFS.find(str(_settings().get("difficulty", "normal"))) + d, 3)]}), off),
		_item(func(): return "PICKUPS RETURN: %d S" % int(_settings().get("pickup_respawn", 96)), Callable(),
			func(d): Net.set_settings({"pickup_respawn": [30, 60, 96][posmod([30, 60, 96].find(int(_settings().get("pickup_respawn", 96))) + d, 3)]}), off),
		_item("EXIT", func(): _go("lobby", true))]

func _lr_arena(d: int) -> void:
	var ar := _arenas()
	if not ar.is_empty():
		_set_rule("arena", ar[posmod(ar.find(str(_settings().get("arena", ""))) + d, ar.size())])

func _lr_bots(d: int) -> void:
	_set_rule("bots", clampi(int(_settings().get("bots", 4)) + d, 0, 7))

func _lr_kills(d: int) -> void:
	_set_rule("score_limit", clampi(int(_settings().get("score_limit", 15)) + d, 1, 99))

func _lr_time(d: int) -> void:
	_set_rule("time_limit", clampi(int(_settings().get("time_limit", 300)) / 60 + d, 1, 60) * 60)

func _arena_short(a: String) -> String:
	if a == Game.TEST_YARD or a == "":
		return "TEST YARD"
	var lines := UI.stage_lines(a)
	var n := " ".join(lines).replace("'", "").to_upper()
	var kv := a.split("/")
	if kv.size() == 2 and Game.local_arena_ids().has(kv[0] + "/part2"):
		n += " " + kv[1].trim_prefix("part")
	return n

func _setup_preview() -> void:
	preview = SubViewport.new()
	preview.size = Vector2i(640, 480)
	preview.own_world_3d = true
	preview.transparent_bg = true
	preview.msaa_3d = Viewport.MSAA_2X
	preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(preview)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.85)
	env.ambient_light_energy = 0.75
	var we := WorldEnvironment.new()
	we.environment = env
	preview.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 1.1
	preview.add_child(key)
	turntable = Node3D.new()
	preview.add_child(turntable)
	cam = Camera3D.new()
	cam.fov = 30.0
	preview.add_child(cam)
	cam.current = true

func _clear_preview() -> void:
	preview_vid = ""
	if preview != null:
		preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if turntable != null:
		for c in turntable.get_children():
			c.queue_free()

func _ensure_preview(vid: String) -> void:
	var st := _stage()
	var want := Vector2i(clampi(int(SW * st.x.x), 320, 2560), clampi(int(SH * st.y.y), 240, 1920))
	if preview.size != want:
		preview.size = want
	preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if vid == preview_vid:
		return
	_clear_preview()
	preview.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	preview_vid = vid
	var model := Game.build_vehicle_model(vid, Game.player_color)
	turntable.add_child(model)
	var sz: Vector3 = model.get_meta("size_m", Vector3(2.0, 1.5, 4.2))
	var r := maxf(Vector2(sz.x, sz.z).length() * 0.5, 1.0)
	# the original shows the car from slightly above, filling about half the screen's width
	# measured: the car spans about 155 of 320 pixels, centred near (157, 145)
	var dist := r * 4.7
	cam.position = Vector3(0, sz.y * 0.5 + dist * 0.36, dist)
	cam.look_at(Vector3(0, sz.y * 0.3, 0))
	cam.v_offset = 0.056 * dist

# ---------------- results ----------------
func _leave_results() -> void:
	Game.last_results = {}
	if tournament or _is_tour():
		Net.tour_last = {}
		_leave_lobby()
	else:
		_go("lobby" if Net.state == "lobby" else "lan")

# ---------------- input ----------------
var _last_enter := 0

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	# the web build can deliver one Enter press twice (key and text input); take the first
	if event is InputEventKey and event.pressed and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		if event.echo or Time.get_ticks_msec() - _last_enter < 180:
			get_viewport().set_input_as_handled()
			return
		_last_enter = Time.get_ticks_msec()
	if editing != "" and event is InputEventKey and event.pressed:
		var k: int = event.keycode
		if k == KEY_ENTER or k == KEY_KP_ENTER:
			_commit_edit()
			sounds.select()
		elif k == KEY_ESCAPE:
			editing = ""
		elif k == KEY_BACKSPACE:
			edit_buf = edit_buf.left(edit_buf.length() - 1)
		elif event.unicode >= 32 and event.unicode < 127 and edit_buf.length() < 24:
			edit_buf += char(event.unicode)
		_build_items(true)
		queue_redraw()
		accept_event()
		get_viewport().set_input_as_handled()
		return
	var handled := true
	if event.is_action_pressed("ui_up", true):
		_move(-1)
	elif event.is_action_pressed("ui_down", true):
		_move(1)
	elif event.is_action_pressed("ui_left", true):
		_lr(-1)
	elif event.is_action_pressed("ui_right", true):
		_lr(1)
	elif event.is_action_pressed("ui_accept"):
		_accept()
	elif event.is_action_pressed("ui_cancel"):
		_back()
	elif screen == "title" and (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton) and event.is_pressed():
		_go("main")
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()

func _move(d: int) -> void:
	if screen == "title":
		_go("main")
		return
	if items.size() <= 1:
		return
	var n := sel
	for _i in items.size():
		n = posmod(n + d, items.size())
		if not items[n].off:
			break
	if n != sel:
		sel = n
		sounds.move()
	if screen == "lobbies":
		lobby_scroll = clampi(lobby_scroll, sel - 6, sel)
	queue_redraw()

func _lr(d: int) -> void:
	if screen == "lobby":
		_cycle_vehicle(d)
		return
	if items.is_empty():
		return
	var it: Dictionary = items[sel]
	if it.lr.is_valid() and not it.off:
		it.lr.call(d)
		sounds.move()
		_build_items(true)
	queue_redraw()

func _accept() -> void:
	if Time.get_ticks_msec() < _guard_until:
		return
	if screen == "title":
		_go("main")
		sounds.select()
		return
	if items.is_empty():
		return
	var it: Dictionary = items[sel]
	if it.off:
		return
	sounds.select()
	if it.do.is_valid():
		it.do.call()
	elif it.lr.is_valid():
		it.lr.call(1)
		_build_items(true)
	queue_redraw()

func _back() -> void:
	sounds.select()
	match screen:
		"main":
			_go("title")
		"options", "lan":
			_go("main")
		"controls", "audio", "video", "driver":
			_go("options" if screen != "driver" or Game.has_saved_name() else "main", true)
		"lobbies":
			Net.disconnect_from_server()
			_go("lan")
		"lobby":
			_leave_lobby()
		"battle":
			_go("lobby", true)
		"carinfo":
			_go("lobby", true)
		"results":
			_leave_results()
		"tourney":
			_go("main", true)
		"begin":
			_go("lobby")
		"tour_opts":
			_go("begin", true)

# ---------------- drawing ----------------
func _process(delta: float) -> void:
	t += delta
	fade = maxf(fade - delta, 0.0)
	if msg_t > 0.0:
		msg_t -= delta
		if msg_t <= 0.0:
			msg = ""
	if screen == "title" and t > 1.6:
		_go("main")
	if screen == "lobby" and turntable != null:
		turntable.rotation.y += delta * 0.9
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	draw_set_transform_matrix(_stage())
	match screen:
		"title":
			_bg("scrnc")
		"main":
			_bg("scrnc")
			_draw_items(Vector2(30, 143))
		"options":
			_bg("scrnf")
			_draw_items(Vector2(30, 88))
		"controls":
			_bg("scrnfb%d" % ClassicControls.preset())
			draw_rect(Rect2(0, 226, SW, 14), Color(0, 0, 0, 0.6))
			_ctext("small", 160, 228, "<  >  CHANGE LAYOUT        ENTER  DONE", C_NOTE)
		"audio":
			_draw_audio()
		"video":
			_bg("scrnf")
			_draw_items(Vector2(30, 84), 16)
		"driver":
			_bg("scrnd", 0.45)
			_ctext("big", 160, 40, "DRIVER", C_GOLD)
			_draw_items(Vector2(30, 100))
			var cw := _width("menu", "COLOUR: ")
			draw_rect(Rect2(32 + cw, 122, 24, 8), Game.player_color)
			draw_rect(Rect2(32 + cw, 122, 24, 8), Color.BLACK, false, 1.0)
			var help := ["KEYBOARD", "W S  GAS / REVERSE     A D  STEER", "SPACE  GUNS     SHIFT  FIRE WEAPON",
				"Q E  WEAPONS     ALT  TURBO", "CTRL  TIGHT TURN     TAB  SCORES", "ESC  PAUSE"]
			for i in help.size():
				_text("small", Vector2(32, 168 + 11 * i), help[i], C_GOLD if i == 0 else C_NOTE)
		"lan":
			_bg("scrnd", 0.45)
			_ctext("big", 160, 40, "LAN PLAY", C_GOLD)
			_draw_items(Vector2(30, 100))
		"lobbies":
			_draw_lobbies()
		"lobby":
			_draw_lobby()
		"battle":
			_draw_battle()
		"carinfo":
			var pages := UI.bio_pages(_my_vid())
			if bio_page < pages.size():
				draw_texture_rect(pages[bio_page], Rect2(0, 0, SW, SH), false)
		"results":
			_draw_results()
		"tourney":
			_bg("scrnf")
			_draw_items(Vector2(30, 88))
		"tour_opts":
			_bg("scrnf")
			_draw_items(Vector2(30, 88))
		"begin":
			_bg("scrne21p")
			var cd := UI.card(_my_vid())
			if cd != null:
				draw_texture_rect(cd, Rect2(94, 65, 128, 64), false)
			_draw_items(Vector2(30, 158))
		"gameover":
			_bg("scrnfd")
			_ctext("big", 160, 40, UI.text("you_lose", "YOU LOSE!"), C_GOLD)
			_ctext("big", 160, 150, UI.text("try_again", "TRY AGAIN?"), C_GOLD)
			_draw_items(Vector2(136, 180))
	if msg != "":
		_draw_note(msg)
	if fade > 0.0:
		draw_rect(Rect2(0, 0, SW, SH), Color(0, 0, 0, fade / 0.25))
	draw_set_transform_matrix(Transform2D.IDENTITY)

func _draw_note(tx: String) -> void:
	var w := _width("small", tx)
	if w > 300:
		tx = tx.left(int(tx.length() * 300.0 / w))
	draw_rect(Rect2(0, 226, SW, 14), Color(0, 0, 0, 0.6))
	_ctext("small", 160, 228, tx, C_NOTE)

func _draw_items(origin: Vector2, pitch := PITCH, from := 0, count := 99) -> void:
	var y := origin.y
	for i in range(from, mini(items.size(), from + count)):
		var it: Dictionary = items[i]
		var col := C_DIS if it.off else (C_SEL if i == sel else C_ITEM)
		_text("menu", Vector2(origin.x, y), _label_of(it), col)
		y += pitch

func _draw_audio() -> void:
	_bg("scrnfc1")
	var rows := [107.0, 127.0, 148.0, 188.0]
	for i in items.size():
		var col := C_SEL if i == sel else C_ITEM
		_text("menu", Vector2(30, rows[i]), _label_of(items[i]), col)
	for k in 2:
		var lv := MenuSounds.level(["music", "effects"][k])
		var col2 := C_SEL if k == sel else C_ITEM
		var bar := "|".repeat(lv) + "{".repeat(MenuSounds.STEPS - lv)
		_text("menu", Vector2(160, rows[k]), bar, col2)
	var names := GameData.music_paths()
	_text("menu", Vector2(66, 162), "''TRACK %d''" % (_track + 2) if not names.is_empty() else "''NONE''", C_SEL if sel == 2 else C_ITEM)

func _draw_lobbies() -> void:
	_bg("scrnd", 0.45)
	_ctext("big", 160, 14, "LOBBIES", C_GOLD)
	var n_lobbies := Net.lobbies.size()
	var first := clampi(lobby_scroll, 0, maxi(n_lobbies - 7, 0))
	var y := 44.0
	if n_lobbies == 0:
		_ctext("small", 160, y + 4, "NO LOBBIES YET", C_NOTE)
		y += 22
	for i in range(first, mini(n_lobbies, first + 7)):
		var e: Dictionary = Net.lobbies[i]
		var it: Dictionary = items[i]
		var col := C_DIS if it.off else (C_SEL if i == sel else C_ITEM)
		_text("menu", Vector2(30, y), _label_of(it).left(14), col)
		var info := "%d/%d %s" % [int(e.players), int(e.max), "PLAYING" if str(e.state) == "match" else "WAITING"]
		var arena := str(e.get("arena", Game.TEST_YARD))
		if not (arena in Game.local_arena_ids()):
			info += " NO DATA"
		_text("small", Vector2(290 - _width("small", info), y + 2), info, C_NOTE)
		y += 20
	y += 8
	for i in range(n_lobbies, items.size()):
		var col := C_SEL if i == sel else C_ITEM
		_text("menu", Vector2(30, y), _label_of(items[i]), col)
		y += 20
	if Net.server_host != "":
		_text("small", Vector2(30, 32), "SERVER %s" % Net.server_host.to_upper(), C_NOTE)

func _draw_lobby() -> void:
	_bg("scrnd")
	var vid := _my_vid()
	var p := UI.portrait(vid)
	if p != null:
		draw_texture_rect(p, Rect2(10, 35, 64, 90), false)
	if int(t * 2.5) % 2 == 0:
		_text("small", Vector2(17, 20), Game.player_name, C_NOTE)
	_ensure_preview(vid)
	draw_texture_rect(preview.get_texture(), Rect2(0, 0, SW, SH), false)
	_draw_items(Vector2(110, 28))
	_ctext("menu", 160, 203, UI.vehicle_name(vid), C_ITEM)
	var sf = _f("small")
	if sf != null:
		sf.draw(self, Vector2(13, 208), "<", C_ARROW)
		sf.draw(self, Vector2(284, 208), ">", C_ARROW)
	# who is here: the other players and the bots, in the small font on the right
	var y := 20.0
	for m in Net.lobby.get("members", []):
		var nm := str(m.name)
		var me := int(m.peer) == Net.my_id
		var line := "%s%s" % [nm.left(10), " *" if bool(m.ready) else ""]
		if not me:
			_text("small", Vector2(306 - _width("small", line), y), line, Color.html(str(m.color)).lightened(0.35))
			y += 11
	for b in Net.lobby.get("bots", []):
		var bl := UI.vehicle_name(str(b.get("vid", ""))) if Game.has_disc_model(str(b.get("vid", ""))) else str(b.name)
		_text("small", Vector2(306 - _width("small", bl.left(12)), y), bl.left(12), C_NOTE.darkened(0.3))
		y += 11
	var s := _settings()
	var arena := str(s.get("arena", Game.TEST_YARD))
	var line2 := "%s   %d KILLS   %d MIN" % [_arena_short(arena), int(s.get("score_limit", 15)), int(s.get("time_limit", 300)) / 60]
	if _is_tour():
		line2 = "LEVEL %d   %s   %d LIVES" % [int(s.get("level", 1)), _diff_label(str(s.get("difficulty", "normal"))), int(s.get("lives_left", 4))]
	if msg == "":
		_draw_note(line2)

func _draw_battle() -> void:
	var arena := str(_settings().get("arena", Game.TEST_YARD))
	var lv := arena.split("/")[0]
	var tex := UI.screen(str(UI.ARENA_PREVIEW.get(lv, "scrne3")))
	if tex == null:
		tex = UI.screen("scrne3")
	if tex != null:
		draw_texture_rect(tex, Rect2(0, 0, SW, SH), false)
	draw_rect(Rect2(36, 72, 248, 120), Color(0, 0, 0, 0.62))
	_draw_items(Vector2(42, 76), 16)
	if not Net.is_lobby_host():
		_draw_note("THE HOST CHOOSES THE BATTLE")

func _draw_results() -> void:
	_bg("scrnd2")
	var res := Game.last_results
	var won := str(res.get("winner", "")) == str(res.get("me", "-")) or bool(Net.tour_last.get("won", false))
	_ctext("big", 160, 62, UI.text("congratulations", "CONGRATULATIONS!") if won else UI.text("you_lose", "YOU LOSE!"), C_GOLD)
	var y := 94.0
	var rank := 1
	_text("small", Vector2(40, y), "DRIVER", C_GOLD)
	_text("small", Vector2(200, y), "KILLS", C_GOLD)
	_text("small", Vector2(244, y), "DEATHS", C_GOLD)
	y += 13
	for row in res.get("rows", []):
		if y > 196:
			break
		var me := str(row[0]) == str(res.get("me", ""))
		var col := C_SEL if me else C_NOTE
		_text("small", Vector2(30, y), "%d" % rank, col)
		_text("small", Vector2(40, y), str(row[0]).left(18), col)
		_text("small", Vector2(214, y), str(row[2]), col)
		_text("small", Vector2(262, y), str(row[3]), col)
		y += 12
		rank += 1
	_draw_items(Vector2(30, 206))
