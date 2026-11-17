extends Control
## Front end, built in code (original design for this game): game data -> driver -> server ->
## lobby browser -> lobby (vehicle and arena select) -> match -> results -> lobby. A step rail
## on the left shows where you are. Keyboard: Tab/arrows move, Enter selects, Esc goes back,
## F2 opens settings, PgUp/PgDn change vehicle in the lobby.
##
## Vehicle previews are rendered at run time from the player's own game data (or the built-in
## stand-ins); nothing from the game data is stored or sent.

const DiscSettingsS := preload("res://scripts/disc/disc_settings.gd")
const DiscArenaS := preload("res://scripts/disc/disc_arena_provider.gd")
const BG := Color(0.055, 0.06, 0.075)
const RAIL := Color(0.085, 0.09, 0.11)
const PANEL := Color(0.11, 0.12, 0.145)
const ROW := Color(0.15, 0.16, 0.195)
const ROW_HI := Color(0.2, 0.21, 0.26)
const ACCENT := Color(1.0, 0.55, 0.16)
const ACCENT2 := Color(0.27, 0.78, 0.86)
const TEXT := Color(0.93, 0.94, 0.96)
const MUTED := Color(0.6, 0.63, 0.7)
const GOOD := Color(0.42, 0.88, 0.52)
const BAD := Color(1.0, 0.42, 0.38)
const PALETTE := ["#d9382b", "#2f7de1", "#f2b632", "#3cb371", "#9b59d0", "#ef7f2e", "#2bc4c4", "#e05297"]
const STEPS := [["data", "Game data"], ["name", "Driver"], ["server", "Server"], ["browser", "Lobbies"], ["lobby", "Lobby"]]

var pages := {}
var current := ""
var _before_settings := ""
var step_rows := {}
var page_title: Label
var page_sub: Label
var status: Label
var footer: Label
# data
var data_path_edit: LineEdit
var data_status: Label
var data_audio_check: CheckBox
var data_dialog: FileDialog
var skip_music_check: CheckBox
var importer: WebDataImport
var no_data_banner: PanelContainer
var data_save_btn: Button
var import_bar: ProgressBar
var data_first: Control
# name
var name_edit: LineEdit
var swatches: HBoxContainer
# server
var addr_edit: LineEdit
var server_first: Control
var web_help: VBoxContainer      # web: shown when the browser refused the game connection
var web_help_link: LinkButton
# browser
var lobby_rows: VBoxContainer
var new_lobby_edit: LineEdit
# lobby
var member_rows: VBoxContainer
var vehicle_name: Label
var vehicle_special: Label
var vehicle_index_label: Label
var stat_bars := {}
var preview: SubViewport
var preview_turntable: Node3D
var preview_cam: Camera3D
var preview_vid := ""
var prev_btn: Button
var next_btn: Button
var ready_btn: Button
var start_btn: Button
var arena_list: ItemList
var arena_label: Label
var host_box: Control
var score_spin: SpinBox
var time_spin: SpinBox
var bots_spin: SpinBox
var lobby_hint: Label
var _settings_lock := false
var _sent_pref := false
# results
var results_title: Label
var results_sub: Label
var results_rows: VBoxContainer
var results_btn: Button
# settings
var tex_opt: OptionButton
var win_opt: OptionButton
var res_opt: OptionButton
var scale_opt: OptionButton
var menus_opt: OptionButton
# original-style front end (built from the player's disc), used instead of these pages when present
var classic: ClassicFront
var classic_off := false

func _ready() -> void:
	theme = _make_theme()
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_draw_backdrop(bg)
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	_build_rail(root)
	var main := MarginContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.clip_contents = true
	for side in ["left", "right"]:
		main.add_theme_constant_override("margin_" + side, 28)
	main.add_theme_constant_override("margin_top", 26)
	main.add_theme_constant_override("margin_bottom", 22)
	root.add_child(main)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_child(col)
	page_title = _label("", 34, TEXT)
	col.add_child(page_title)
	page_sub = _label("", 15, MUTED)
	page_sub.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(page_sub)
	var bar := ColorRect.new()
	bar.color = ACCENT
	bar.custom_minimum_size = Vector2(64, 3)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.add_child(bar)
	# pages live in a scroll area so narrow or short windows scroll instead of clipping
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	col.add_child(scroll)
	var body := MarginContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("margin_top", 14)
	scroll.add_child(body)
	_build_data(body)
	_build_name(body)
	_build_server(body)
	_build_browser(body)
	_build_lobby(body)
	_build_results(body)
	_build_settings(body)
	status = _label("", 15, MUTED)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(status)
	footer = _label("Tab / arrows move    Enter select    Esc back    F2 settings", 13, Color(MUTED, 0.75))
	col.add_child(footer)

	Net.state_changed.connect(_on_net_state)
	Net.lobbies_changed.connect(_rebuild_lobbies)
	Net.lobby_changed.connect(_rebuild_lobby)
	Net.error_message.connect(func(t): _set_status(t, true))
	if Game.last_message != "":
		_set_status(Game.last_message, true)
		Game.last_message = ""
	if Net.state == "lobby":
		_show("results" if not Game.last_results.is_empty() else "lobby")
	elif Net.state == "browser":
		_show("browser")
	elif Net.state == "connecting":
		_show("server")
		_set_status("Connecting...")
	elif OS.has_feature("web") and not _web_checked:
		_web_start()
	else:
		_go_first_page()

func _go_first_page() -> void:
	if OS.has_feature("web") and Game.args.has("lobby"):
		_show("server")       # ?lobby=... test automation: connect straight away
		_on_connect()
		return
	if _needs_data_page():
		_show("data")
	elif not Game.has_saved_name():
		_show("name")
	else:
		_show("server")

## Desktop: the saved folder, else ../gamedata beside the project; the game-data page only shows
## when neither has a manifest.json. Web: data already copied into this browser (IndexedDB) or
## an earlier "play without" choice skips it.
func _needs_data_page() -> bool:
	if Game.args.has("connect"):
		return false
	if OS.has_feature("web"):
		return not GameData.has_data() and not _cfg_flag("data_skipped")
	return not GameData.has_data() and not GameData.is_configured()

static var _web_checked := false
var _auto_data_id := ""

## Web start: a browser on the server machine itself is offered the server's game data
## (/server.json local_data). Copy it into this browser automatically when it has none yet or the
## server's manifest changed, then go straight on. Other machines get the folder picker.
func _web_start() -> void:
	_web_checked = true
	_show("data")
	data_status.text = "Checking for game data on this computer..."
	Net.web_server_info(func(info: Dictionary):
		var did := str(info.get("data_id", ""))
		if bool(info.get("local_data", false)) and did != "" and (not GameData.has_data() or _cfg_str("local_data_id") != did):
			print("[menu] game data found on this computer's server: importing it into the browser")
			_auto_data_id = did
			_ensure_importer()
			importer.skip_music = not bool(info.get("import_music", false))
			importer.start_url("/local-gamedata/")
			return
		print("[menu] web start: local_data=%s, browser has game data=%s" % [str(info.get("local_data", false)), str(GameData.has_data())])
		_refresh_data_status()
		_go_first_page())

func _cfg_str(k: String) -> String:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return str(c.get_value("game_data", k, ""))

func _cfg_flag(k: String) -> bool:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return bool(c.get_value("game_data", k, false))

func _set_cfg_flag(k: String, v) -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value("game_data", k, v)
	c.save("user://settings.cfg")

func _set_status(t: String, bad := false) -> void:
	status.text = t
	status.add_theme_color_override("font_color", BAD if bad else MUTED)

# ---------------- look ----------------
func _sb(c: Color, radius := 6, border := Color(0, 0, 0, 0), bw := 0, pad := Vector4(14, 8, 14, 8)) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = c
	b.set_corner_radius_all(radius)
	if bw > 0:
		b.border_color = border
		b.set_border_width_all(bw)
	b.content_margin_left = pad.x
	b.content_margin_top = pad.y
	b.content_margin_right = pad.z
	b.content_margin_bottom = pad.w
	return b

func _make_theme() -> Theme:
	var t := Theme.new()
	t.set_stylebox("panel", "PanelContainer", _sb(PANEL, 10, Color(1, 1, 1, 0.05), 1, Vector4(18, 16, 18, 16)))
	t.set_stylebox("normal", "Button", _sb(ROW))
	t.set_stylebox("hover", "Button", _sb(ROW_HI))
	t.set_stylebox("pressed", "Button", _sb(ACCENT.darkened(0.45)))
	t.set_stylebox("disabled", "Button", _sb(Color(0.1, 0.105, 0.125)))
	t.set_stylebox("focus", "Button", _sb(Color(0, 0, 0, 0), 6, ACCENT, 2))
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", Color(MUTED, 0.5))
	for cls in ["LineEdit", "SpinBox"]:
		t.set_stylebox("normal", cls, _sb(Color(0.07, 0.075, 0.095), 6, Color(1, 1, 1, 0.08), 1, Vector4(10, 7, 10, 7)))
		t.set_stylebox("focus", cls, _sb(Color(0, 0, 0, 0), 6, ACCENT, 2))
	t.set_stylebox("normal", "OptionButton", _sb(ROW))
	t.set_stylebox("hover", "OptionButton", _sb(ROW_HI))
	t.set_stylebox("focus", "OptionButton", _sb(Color(0, 0, 0, 0), 6, ACCENT, 2))
	t.set_stylebox("panel", "ItemList", _sb(Color(0.075, 0.08, 0.1), 8, Color(1, 1, 1, 0.06), 1, Vector4(6, 6, 6, 6)))
	t.set_stylebox("focus", "ItemList", _sb(Color(0, 0, 0, 0), 8, ACCENT, 2))
	t.set_stylebox("selected", "ItemList", _sb(ACCENT.darkened(0.55), 5))
	t.set_stylebox("selected_focus", "ItemList", _sb(ACCENT.darkened(0.45), 5))
	t.set_stylebox("cursor", "ItemList", _sb(Color(0, 0, 0, 0), 5, ACCENT, 1))
	t.set_stylebox("cursor_unfocused", "ItemList", _sb(Color(0, 0, 0, 0), 5))
	t.set_constant("v_separation", "ItemList", 8)
	t.set_font_size("font_size", "Label", 16)
	t.set_font_size("font_size", "Button", 16)
	t.set_font_size("font_size", "LineEdit", 16)
	t.set_font_size("font_size", "ItemList", 16)
	t.set_font_size("font_size", "OptionButton", 16)
	t.set_font_size("font_size", "CheckBox", 15)
	return t

func _draw_backdrop(bg: Control) -> void:
	# a faint perspective grid in the lower right, purely decorative
	var grid := Control.new()
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.draw.connect(func():
		var s := grid.size
		var horizon := s.y * 0.58
		var vp := Vector2(s.x * 0.72, horizon)
		for i in range(-14, 15):
			grid.draw_line(vp, Vector2(vp.x + i * s.x * 0.09, s.y), Color(1, 1, 1, 0.025), 1.0)
		for k in 12:
			var f := pow(float(k) / 12.0, 1.8)
			var y := horizon + (s.y - horizon) * f
			grid.draw_line(Vector2(s.x * 0.3, y), Vector2(s.x, y), Color(1, 1, 1, 0.02 + 0.02 * f), 1.0))
	bg.add_child(grid)

func _label(text: String, size := 16, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _button(text: String, cb: Callable, primary := false) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	if primary:
		b.add_theme_color_override("font_color", Color(0.09, 0.06, 0.02))
		b.add_theme_color_override("font_hover_color", Color(0.09, 0.06, 0.02))
		b.add_theme_color_override("font_focus_color", Color(0.09, 0.06, 0.02))
		b.add_theme_color_override("font_pressed_color", Color(0.09, 0.06, 0.02))
		b.add_theme_stylebox_override("normal", _sb(ACCENT))
		b.add_theme_stylebox_override("hover", _sb(ACCENT.lightened(0.15)))
		b.add_theme_stylebox_override("pressed", _sb(ACCENT.darkened(0.15)))
		b.add_theme_stylebox_override("focus", _sb(Color(0, 0, 0, 0), 6, Color(1, 1, 1, 0.9), 2))
	return b

func _row(parent: Control, label: String, w := 150) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	if label != "":
		var l := _label(label, 16, MUTED)
		l.custom_minimum_size = Vector2(w, 0)
		h.add_child(l)
	parent.add_child(h)
	return h

func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _spin(min_v: float, max_v: float, val: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.value = val
	s.custom_minimum_size = Vector2(120, 0)
	return s

func _page(id: String, parent: Control) -> VBoxContainer:
	var p := VBoxContainer.new()
	p.add_theme_constant_override("separation", 14)
	p.visible = false
	parent.add_child(p)
	pages[id] = p
	return p

# ---------------- step rail ----------------
func _build_rail(root: Control) -> void:
	var rail := PanelContainer.new()
	rail.custom_minimum_size = Vector2(230, 0)
	rail.add_theme_stylebox_override("panel", _sb(RAIL, 0, Color(0, 0, 0, 0), 0, Vector4(24, 30, 20, 20)))
	root.add_child(rail)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	rail.add_child(v)
	var logo := _label("ARENA", 40, TEXT)
	v.add_child(logo)
	var logo2 := _label("WHEELS", 40, ACCENT)
	logo2.add_theme_constant_override("line_spacing", -8)
	v.add_child(logo2)
	v.add_child(_label("LAN car combat for up to 8", 14, MUTED))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 30)
	v.add_child(gap)
	for i in STEPS.size():
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 12)
		var num := Label.new()
		num.text = str(i + 1)
		num.custom_minimum_size = Vector2(30, 30)
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		h.add_child(num)
		var l := _label(STEPS[i][1], 18, MUTED)
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(l)
		v.add_child(h)
		step_rows[STEPS[i][0]] = [num, l]
		var line := ColorRect.new()
		line.color = Color(1, 1, 1, 0.06)
		line.custom_minimum_size = Vector2(2, 14)
		line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var lm := MarginContainer.new()
		lm.add_theme_constant_override("margin_left", 14)
		lm.add_child(line)
		if i < STEPS.size() - 1:
			v.add_child(lm)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(fill)
	var sb := _button("Settings  (F2)", func(): _show("settings"))
	sb.focus_mode = Control.FOCUS_NONE
	v.add_child(sb)
	if not OS.has_feature("web"):
		var qb := _button("Quit", get_tree().quit)
		qb.focus_mode = Control.FOCUS_NONE
		v.add_child(qb)

## Draws a small vector icon (no font glyphs, which the web font may lack) over a control.
func _icon(parent: Control, kind: String, color: Color) -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(_draw_icon.bind(c, kind, color))
	parent.add_child(c)
	return c

func _draw_icon(c: Control, kind: String, color: Color) -> void:
	var s := c.size
	var m := minf(s.x, s.y)
	var o := (s - Vector2(m, m)) * 0.5
	if kind == "check":
		c.draw_polyline(PackedVector2Array([o + Vector2(m * 0.28, m * 0.52), o + Vector2(m * 0.43, m * 0.68), o + Vector2(m * 0.74, m * 0.33)]), color, maxf(2.0, m * 0.1), true)
	elif kind == "left":
		c.draw_colored_polygon(PackedVector2Array([o + Vector2(m * 0.62, m * 0.25), o + Vector2(m * 0.62, m * 0.75), o + Vector2(m * 0.32, m * 0.5)]), color)
	elif kind == "right":
		c.draw_colored_polygon(PackedVector2Array([o + Vector2(m * 0.38, m * 0.25), o + Vector2(m * 0.38, m * 0.75), o + Vector2(m * 0.68, m * 0.5)]), color)
	elif kind == "dot":
		c.draw_circle(o + Vector2(m, m) * 0.5, m * 0.2, color)

func _update_rail() -> void:
	var idx := -1
	for i in STEPS.size():
		if STEPS[i][0] == current or (current == "results" and STEPS[i][0] == "lobby"):
			idx = i
	for i in STEPS.size():
		var row: Array = step_rows[STEPS[i][0]]
		var num: Label = row[0]
		var l: Label = row[1]
		var st := "todo" if i > idx else ("now" if i == idx else "done")
		if idx < 0:
			st = "todo"
		var circle := _sb(ACCENT if st == "now" else (Color(1, 1, 1, 0.08) if st == "done" else Color(0, 0, 0, 0)), 15,
			ACCENT if st == "now" else Color(1, 1, 1, 0.18), 0 if st == "now" else 1, Vector4(0, 0, 0, 0))
		num.add_theme_stylebox_override("normal", circle)
		num.add_theme_color_override("font_color", Color(0.09, 0.06, 0.02) if st == "now" else (GOOD if st == "done" else MUTED))
		num.text = str(i + 1) if st != "done" else ""
		var old := num.get_node_or_null("Tick")
		if old != null:
			old.free()
		if st == "done":
			_icon(num, "check", GOOD).name = "Tick"
		l.add_theme_color_override("font_color", TEXT if st == "now" else (Color(TEXT, 0.75) if st == "done" else Color(MUTED, 0.7)))

# ---------------- navigation ----------------
const TITLES := {
	"data": ["Game data", "Use content from your own copy of the original disc, read at run time on this computer."],
	"name": ["Who's driving?", "Your name and colour as other players will see them."],
	"server": ["Find a server", "Join a server on your network, or run one on this computer."],
	"browser": ["Lobbies", ""],
	"lobby": ["Lobby", ""],
	"results": ["Results", ""],
	"settings": ["Settings", "Picture and texture quality. Changes apply right away; texture quality applies to the next match."],
}

## Hands the menus to the original-style front end when the game data has its images and fonts.
## The game-data page stays here (it is how the data gets loaded in the first place).
func _show(page: String) -> void:
	if classic != null and is_instance_valid(classic):
		return
	if page != "data" and page != "settings" and not classic_off and not Game.is_server and DiscUI.classic_enabled() \
			and not Game.args.has("lobby") and not Game.args.has("connect") and not Game.args.has("modern-menus"):
		classic = ClassicFront.new(self)
		add_child(classic)
		classic.start(page)
		print("[menu] original-style menus from the game data")
		return
	_show_modern(page)

## The original-style front end closed itself (menus set to modern, or the game-data page).
func classic_closed(page: String) -> void:
	classic = null
	classic_off = true
	if page != "":
		_show_modern(page)
	elif current == "":
		_show_modern("server")

func _show_modern(page: String) -> void:
	if page == "settings" and current != "settings":
		_before_settings = current
	current = page
	for k in pages:
		pages[k].visible = k == page
	var t: Array = TITLES.get(page, [page, ""])
	page_title.text = t[0]
	page_sub.text = t[1]
	page_sub.visible = t[1] != ""
	match page:
		"data":
			_refresh_data_status()
			_focus.call_deferred(data_first)
		"name":
			_focus.call_deferred(name_edit)
		"server":
			_focus.call_deferred(server_first)
		"browser":
			_rebuild_lobbies()
		"lobby":
			_sent_pref = false
			_rebuild_lobby()
			_focus.call_deferred(ready_btn)
		"results":
			_rebuild_results()
			_focus.call_deferred(results_btn)
		"settings":
			_refresh_settings()
			_focus.call_deferred(tex_opt)
	if page != "lobby" and preview != null:
		_clear_preview()
	_update_rail()

func _focus(c: Control) -> void:
	if c != null and is_instance_valid(c) and c.is_visible_in_tree():
		c.grab_focus()

func _go_back() -> void:
	match current:
		"settings":
			_show(_before_settings if _before_settings != "" else "server")
		"name":
			_show("data")
		"server":
			_show("name")
		"browser":
			Net.disconnect_from_server()
			_show("server")
		"lobby":
			Net.leave_lobby()
			_show("browser")
		"results":
			_continue_from_results()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k: int = event.keycode
	if k == KEY_ESCAPE:
		_go_back()
		get_viewport().set_input_as_handled()
	elif k == KEY_F2:
		_show("settings" if current != "settings" else (_before_settings if _before_settings != "" else "server"))
		get_viewport().set_input_as_handled()
	elif current == "lobby" and (k == KEY_PAGEUP or k == KEY_PAGEDOWN):
		_cycle_vehicle(-1 if k == KEY_PAGEUP else 1)
		get_viewport().set_input_as_handled()

# ---------------- 1. game data ----------------
func _build_data(parent: Control) -> void:
	var p := _page("data", parent)
	var info := _label("This game ships no artwork, models, sound or music from any other game. If you own the original disc, choose the folder made from your own copy (the one holding manifest.json): its arenas, vehicles, sounds and music are then read from that folder while you play. It stays on your computer and is never sent to the server or to other players. Without it you play the built-in arena and vehicles.", 15, MUTED)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	info.custom_minimum_size = Vector2(560, 0)
	p.add_child(info)
	var panel := PanelContainer.new()
	p.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	if OS.has_feature("web"):
		skip_music_check = CheckBox.new()
		skip_music_check.text = "Skip music (saves a lot of browser storage)"
		box.add_child(skip_music_check)
		var r0 := _row(box, "")
		data_first = _button("Choose folder...", _on_web_pick, true)
		data_first.custom_minimum_size = Vector2(260, 52)
		data_first.add_theme_font_size_override("font_size", 22)
		r0.add_child(data_first)
		import_bar = ProgressBar.new()
		import_bar.max_value = 1.0
		import_bar.visible = false
		box.add_child(import_bar)
	else:
		var r := _row(box, "Folder", 80)
		data_path_edit = LineEdit.new()
		data_path_edit.text = GameData.root()
		data_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		data_path_edit.text_changed.connect(func(_t): _refresh_data_status())
		data_path_edit.text_submitted.connect(func(_t): _save_data())
		r.add_child(data_path_edit)
		r.add_child(_button("Browse...", func(): data_dialog.popup_centered_ratio(0.6)))
		data_first = data_path_edit
		data_dialog = FileDialog.new()
		data_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		data_dialog.access = FileDialog.ACCESS_FILESYSTEM
		data_dialog.title = "Choose the folder that holds manifest.json"
		data_dialog.dir_selected.connect(func(d): data_path_edit.text = d; _refresh_data_status())
		add_child(data_dialog)
	data_audio_check = CheckBox.new()
	data_audio_check.text = "Use sounds and music from the game data"
	data_audio_check.button_pressed = GameData.use_disc_audio()
	box.add_child(data_audio_check)
	data_status = _label("", 15, TEXT)
	data_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(data_status)
	var r2 := _row(p, "")
	data_save_btn = _button("Save and continue", _save_data, not OS.has_feature("web"))
	r2.add_child(data_save_btn)
	# secondary: a small link, with a confirmation
	var skip := LinkButton.new()
	skip.text = "Play without game data"
	skip.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	skip.add_theme_font_size_override("font_size", 14)
	skip.add_theme_color_override("font_color", MUTED)
	skip.focus_mode = Control.FOCUS_ALL
	var confirm := ConfirmationDialog.new()
	confirm.title = "Play without game data?"
	confirm.dialog_text = "Without your game data you get only the built-in stand-in arena and cars,\nnot your disc's arenas, vehicles, sounds and music. You can load it later on this page."
	confirm.ok_button_text = "Play without"
	confirm.cancel_button_text = "Go back"
	confirm.confirmed.connect(_skip_data)
	add_child(confirm)
	skip.pressed.connect(func(): confirm.popup_centered())
	p.add_child(skip)

func _skip_data() -> void:
	if OS.has_feature("web"):
		_set_cfg_flag("data_skipped", true)
	else:
		data_audio_check.button_pressed = false
		GameData.set_root(data_path_edit.text.strip_edges())
		GameData.set_use_disc_audio(false)
		Game.select_providers()
		Game.reload_audio()
	_show("name")

func _describe_data() -> String:
	var m := GameData.manifest()
	if m.is_empty():
		return ""
	var arenas := 0
	for lv in m.get("arenas", {}):
		arenas += (m.arenas[lv] as Dictionary).size()
	return "Found game data: %d arenas, %d vehicles, %d music tracks." % [arenas, m.get("vehicles", {}).size(), m.get("audio", {}).get("music", []).size()]

func _refresh_data_status() -> void:
	if data_status == null:
		return
	if data_path_edit != null:
		var saved := GameData.root_override
		GameData.root_override = data_path_edit.text.strip_edges()
		GameData.reset_cache()
		var msg := _describe_data()
		data_status.text = msg if msg != "" else "No manifest.json in this folder. The built-in arena and vehicles will be used."
		data_status.add_theme_color_override("font_color", GOOD if msg != "" else MUTED)
		GameData.root_override = saved
		GameData.reset_cache()
	else:
		data_status.text = _describe_data() + " Stored in this browser." if GameData.has_data() else "No game data in this browser yet."
		if data_save_btn != null:
			data_save_btn.visible = GameData.has_data()   # without data, only the confirmed link skips

func _ensure_importer() -> void:
	if importer != null:
		return
	importer = WebDataImport.new()
	add_child(importer)
	importer.progress.connect(func(t, f): data_status.text = t; import_bar.visible = true; import_bar.value = f)
	importer.finished.connect(_on_import_done)

func _on_import_done(ok: bool, t: String) -> void:
	import_bar.visible = false
	data_status.text = t
	var auto := _auto_data_id != ""
	if ok:
		if auto:
			_set_cfg_flag("local_data_id", _auto_data_id)
			t = "Loaded the game data from this computer (music not copied; Choose folder adds it). " + t
		_set_cfg_flag("data_skipped", false)
		GameData.reset_cache()
		Game.select_providers()
		Game.reload_audio()
		print("[menu] game data import finished: %s (%s)" % [t, _describe_data()])
		_auto_data_id = ""
		if auto:
			_go_first_page()
		else:
			_show("name")
		_set_status(t)
	elif auto:
		_auto_data_id = ""
		print("[menu] automatic game data import failed: %s" % t)
		_set_status("Could not load the game data from this computer: %s Choose your folder instead." % t, true)
		_show("data")

func _on_web_pick() -> void:
	_ensure_importer()
	_auto_data_id = ""
	importer.skip_music = skip_music_check.button_pressed
	importer.start()

func _save_data() -> void:
	if data_path_edit != null:
		GameData.set_root(data_path_edit.text.strip_edges())
	GameData.set_use_disc_audio(data_audio_check.button_pressed)
	GameData.reset_cache()
	Game.select_providers()
	Game.reload_audio()
	_show("name")
	var d := _describe_data()
	_set_status(d if d != "" else "No game data: playing with the built-in content.")

# ---------------- 2. driver ----------------
func _build_name(parent: Control) -> void:
	var p := _page("name", parent)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var r1 := _row(box, "Name", 80)
	name_edit = LineEdit.new()
	name_edit.text = Game.player_name
	name_edit.max_length = 16
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(func(_t): _save_name())
	r1.add_child(name_edit)
	var r2 := _row(box, "Colour", 80)
	swatches = HBoxContainer.new()
	swatches.add_theme_constant_override("separation", 8)
	r2.add_child(swatches)
	for c in PALETTE:
		var b := Button.new()
		b.custom_minimum_size = Vector2(34, 34)
		b.tooltip_text = c
		var col := Color.html(c)
		b.add_theme_stylebox_override("normal", _sb(col, 17, Color(1, 1, 1, 0.0), 0, Vector4(0, 0, 0, 0)))
		b.add_theme_stylebox_override("hover", _sb(col.lightened(0.2), 17, Color(1, 1, 1, 0.0), 0, Vector4(0, 0, 0, 0)))
		b.add_theme_stylebox_override("pressed", _sb(col, 17, Color(1, 1, 1, 0.0), 0, Vector4(0, 0, 0, 0)))
		b.add_theme_stylebox_override("focus", _sb(Color(0, 0, 0, 0), 17, Color.WHITE, 2, Vector4(0, 0, 0, 0)))
		b.pressed.connect(func():
			Game.player_color = col
			Game.save_profile()
			_mark_swatch()
			if Net.state == "lobby":
				Net.set_me(ready_btn.button_pressed, false))
		swatches.add_child(b)
	_mark_swatch()
	var r3 := _row(p, "")
	r3.add_child(_button("Continue", _save_name, true))
	var help := _label("Driving: W/S drive, A/D steer, Ctrl handbrake, Alt turbo, Space machine gun, Shift fire weapon, Q/E change weapon, R unstuck, Tab scores, F3 network, Esc menu.", 14, MUTED)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	help.custom_minimum_size = Vector2(560, 0)
	p.add_child(help)

func _mark_swatch() -> void:
	for i in swatches.get_child_count():
		var b: Button = swatches.get_child(i)
		var on := Color.html(PALETTE[i]).is_equal_approx(Game.player_color)
		b.text = ""
		var old := b.get_node_or_null("Dot")
		if old != null:
			old.free()
		if on:
			_icon(b, "dot", Color(0, 0, 0, 0.7)).name = "Dot"
		b.add_theme_color_override("font_color", Color(0, 0, 0, 0.7))

func _save_name() -> void:
	var n := name_edit.text.strip_edges()
	Game.player_name = n if n != "" else "Driver"
	Game.save_profile()
	_show("server")

# ---------------- 3. server ----------------
func _build_server(parent: Control) -> void:
	var p := _page("server", parent)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	if OS.has_feature("web"):
		box.add_child(_label("You opened the game from a server on your network; its lobbies are one click away.", 15, MUTED))
		server_first = _button("Find lobbies", _on_connect, true)
		var r := _row(box, "")
		r.add_child(server_first)
		# fallback when the browser refuses the game connection (certificate not accepted)
		web_help = VBoxContainer.new()
		web_help.add_theme_constant_override("separation", 10)
		web_help.visible = false
		box.add_child(web_help)
		var t := _label("Your browser refused the connection to the game server, probably because it has not accepted the server's certificate for the game connection. Open the link below; Chrome warns that the connection is not private: click Advanced, then Proceed. That tab then shows an error or a blank page, which is expected. Close it, come back here and press Retry.", 15, TEXT)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD
		web_help.add_child(t)
		web_help_link = LinkButton.new()
		web_help_link.add_theme_font_size_override("font_size", 16)
		web_help_link.add_theme_color_override("font_color", ACCENT)
		web_help_link.focus_mode = Control.FOCUS_ALL
		web_help.add_child(web_help_link)
		var r3 := _row(web_help, "")
		r3.add_child(_button("Retry", _on_connect, true))
		Net.web_connect_failed.connect(_on_web_connect_failed)
		return
	var r1 := _row(box, "Address", 90)
	addr_edit = LineEdit.new()
	addr_edit.text = Game.server_addr
	addr_edit.placeholder_text = "address:port, e.g. 192.168.1.20:8910"
	addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addr_edit.text_submitted.connect(func(_t): _on_connect())
	r1.add_child(addr_edit)
	server_first = addr_edit
	var r2 := _row(box, "")
	r2.add_child(_button("Connect", _on_connect, true))
	r2.add_child(_button("Start local server", _on_local_server))
	var hint := _label("\"Start local server\" runs a server on this computer, using your game data for the arenas. Friends on the same network can then join from this app, or open the https address it shows in Chrome. The first time, Chrome warns that the connection is not private: click Advanced, then Proceed. That is expected with the server's self-signed certificate.", 14, MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(hint)

func _on_connect() -> void:
	_set_status("Connecting...")
	if OS.has_feature("web"):
		if web_help != null:
			web_help.visible = false
		Net.web_connect()
		return
	Game.server_addr = addr_edit.text.strip_edges()
	Game.save_profile()
	if Game.server_addr == "":
		_set_status("Enter the server address", true)
		return
	var err2 := Net.connect_to_server(Game.server_addr)
	if err2 != OK:
		_set_status("Could not connect: %s" % error_string(err2), true)

## Web: neither the page's own address (/ws) nor the game port worked.
func _on_web_connect_failed(cert_url: String) -> void:
	_show("server")
	if web_help == null:
		return
	web_help.visible = true
	web_help_link.visible = cert_url != ""
	web_help_link.text = "Open %s to accept the certificate" % cert_url
	web_help_link.uri = cert_url
	print("[menu] web connection failed; offering %s" % cert_url)

func _on_local_server() -> void:
	if Net.start_local_server() != OK:
		_set_status("Could not start the server process", true)
		return
	Game.server_addr = "127.0.0.1:%d" % Net.DEFAULT_PORT
	_set_status("Starting a local server... Desktop players join at %s. In Chrome, open https://%s:%d/ (the first time, click Advanced, then Proceed: the certificate is self-signed)." % [
		", ".join(GameServer.lan_addresses().map(func(a): return "%s:%d" % [a, Net.DEFAULT_PORT])), GameServer.lan_addresses()[0], Net.DEFAULT_HTTPS_PORT])

func _on_net_state() -> void:
	match Net.state:
		"browser":
			if current != "browser":
				_show("browser")
			_set_status("")
		"lobby":
			if current != "lobby" and current != "results":
				_show("lobby")
			_set_status("")
		"offline":
			if current in ["browser", "lobby", "results"]:
				_show("server")

# ---------------- 4. lobby browser ----------------
func _build_browser(parent: Control) -> void:
	var p := _page("browser", parent)
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	lobby_rows = VBoxContainer.new()
	lobby_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lobby_rows.add_theme_constant_override("separation", 8)
	scroll.add_child(lobby_rows)
	var r := _row(p, "New lobby", 110)
	new_lobby_edit = LineEdit.new()
	new_lobby_edit.placeholder_text = "Lobby name"
	new_lobby_edit.max_length = 16
	new_lobby_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_lobby_edit.text_submitted.connect(func(_t): Net.create_lobby(new_lobby_edit.text))
	r.add_child(new_lobby_edit)
	r.add_child(_button("Create", func(): Net.create_lobby(new_lobby_edit.text), true))
	r.add_child(_button("Refresh", Net.request_list))
	r.add_child(_button("Tournament (vs bots)", func(): Net.create_tournament("normal", true)))
	r.add_child(_button("Disconnect", func(): Net.disconnect_from_server(); _show("server")))

func _rebuild_lobbies() -> void:
	if lobby_rows == null or current != "browser":
		return
	page_sub.text = "On %s. The list refreshes by itself." % (Net.server_host if Net.server_host != "" else "the server")
	page_sub.visible = true
	var had_focus := get_viewport().gui_get_focus_owner()
	var focus_idx := -1
	for i in lobby_rows.get_child_count():
		if lobby_rows.get_child(i) == had_focus:
			focus_idx = i
	for c in lobby_rows.get_children():
		lobby_rows.remove_child(c)
		c.queue_free()
	if Net.lobbies.is_empty():
		lobby_rows.add_child(_label("No lobbies yet. Create one and your friends will see it here.", 16, MUTED))
		if had_focus == null or not had_focus.is_visible_in_tree():
			_focus.call_deferred(new_lobby_edit)
		return
	var mine := Game.local_arena_ids()
	for e in Net.lobbies:
		var playing: bool = str(e.state) == "match"
		var full: bool = int(e.players) >= int(e.max)
		var arena := str(e.get("arena", Game.TEST_YARD))
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 46)
		b.text = "%s      %d/%d players    %s    %s    host %s%s" % [e.name, int(e.players), int(e.max), "in match" if playing else "waiting",
			Game.arena_label(arena), e.host, "" if arena in mine else "    (needs game data)"]
		b.disabled = full
		b.pressed.connect(func(): Net.join_lobby(int(e.id)))
		if playing:
			b.add_theme_color_override("font_color", ACCENT2)
		lobby_rows.add_child(b)
	if focus_idx >= 0 and focus_idx < lobby_rows.get_child_count():
		_focus.call_deferred(lobby_rows.get_child(focus_idx))
	elif had_focus == null or not had_focus.is_visible_in_tree():
		_focus.call_deferred(lobby_rows.get_child(0))

# ---------------- 5. lobby ----------------
const NO_DATA_TEXT := "No game data loaded: you're seeing built-in stand-in arenas and cars. Load your game data folder on the first screen to play with your own disc's content."

func _build_lobby(parent: Control) -> void:
	var p := _page("lobby", parent)
	no_data_banner = PanelContainer.new()
	no_data_banner.add_theme_stylebox_override("panel", _sb(Color(0.55, 0.12, 0.1, 0.85), 6, BAD, 1, Vector4(14, 10, 14, 10)))
	var nb := _label(NO_DATA_TEXT, 16, TEXT)
	nb.autowrap_mode = TextServer.AUTOWRAP_WORD
	no_data_banner.add_child(nb)
	no_data_banner.visible = false
	p.add_child(no_data_banner)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 16)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(cols)
	# players
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(200, 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 0.8
	cols.add_child(left)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 6)
	left.add_child(lv)
	lv.add_child(_label("PLAYERS", 13, MUTED))
	member_rows = VBoxContainer.new()
	member_rows.add_theme_constant_override("separation", 6)
	lv.add_child(member_rows)
	# vehicle
	var mid := PanelContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_stretch_ratio = 1.6
	mid.custom_minimum_size = Vector2(300, 0)
	cols.add_child(mid)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 8)
	mid.add_child(mv)
	var vh := HBoxContainer.new()
	mv.add_child(vh)
	vh.add_child(_label("YOUR VEHICLE", 13, MUTED))
	vh.add_child(_spacer())
	vehicle_index_label = _label("", 13, MUTED)
	vh.add_child(vehicle_index_label)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.custom_minimum_size = Vector2(240, 180)
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mv.add_child(svc)
	preview = SubViewport.new()
	preview.own_world_3d = true
	preview.transparent_bg = true
	preview.msaa_3d = Viewport.MSAA_4X
	preview.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(preview)
	_setup_preview_world()
	var sel := HBoxContainer.new()
	sel.add_theme_constant_override("separation", 10)
	mv.add_child(sel)
	prev_btn = _button("", func(): _cycle_vehicle(-1))
	prev_btn.custom_minimum_size = Vector2(48, 44)
	_icon(prev_btn, "left", TEXT)
	sel.add_child(prev_btn)
	var namebox := VBoxContainer.new()
	namebox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel.add_child(namebox)
	vehicle_name = _label("", 26, TEXT)
	vehicle_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	namebox.add_child(vehicle_name)
	vehicle_special = _label("", 14, ACCENT2)
	vehicle_special.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	namebox.add_child(vehicle_special)
	next_btn = _button("", func(): _cycle_vehicle(1))
	next_btn.custom_minimum_size = Vector2(48, 44)
	_icon(next_btn, "right", TEXT)
	sel.add_child(next_btn)
	for k in [["speed", "Top speed"], ["turn", "Turning"], ["armor", "Health"]]:
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 10)
		var l := _label(k[1], 14, MUTED)
		l.custom_minimum_size = Vector2(90, 0)
		r.add_child(l)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 10)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_theme_stylebox_override("background", _sb(Color(1, 1, 1, 0.06), 4, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
		bar.add_theme_stylebox_override("fill", _sb(ACCENT, 4, Color(0, 0, 0, 0), 0, Vector4(0, 0, 0, 0)))
		bar.max_value = 1.0
		r.add_child(bar)
		mv.add_child(r)
		stat_bars[k[0]] = bar
	# arena and match settings
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(250, 0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	cols.add_child(right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 8)
	right.add_child(rv)
	rv.add_child(_label("ARENA", 13, MUTED))
	arena_label = _label("", 18, TEXT)
	arena_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	rv.add_child(arena_label)
	arena_list = ItemList.new()
	arena_list.custom_minimum_size = Vector2(0, 170)
	arena_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	arena_list.item_selected.connect(func(_i): _send_settings())
	rv.add_child(arena_list)
	host_box = VBoxContainer.new()
	host_box.add_theme_constant_override("separation", 6)
	rv.add_child(host_box)
	var o1 := _row(host_box, "Score limit", 110)
	score_spin = _spin(1, 100, 15)
	score_spin.value_changed.connect(func(_v): _send_settings())
	o1.add_child(score_spin)
	var o2 := _row(host_box, "Minutes", 110)
	time_spin = _spin(1, 60, 5)
	time_spin.value_changed.connect(func(_v): _send_settings())
	o2.add_child(time_spin)
	var o3 := _row(host_box, "Fill with bots", 110)
	bots_spin = _spin(0, 8, 4)
	bots_spin.suffix = "cars"
	bots_spin.value_changed.connect(func(_v): _send_settings())
	o3.add_child(bots_spin)
	lobby_hint = _label("", 14, MUTED)
	lobby_hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	p.add_child(lobby_hint)
	var r := _row(p, "")
	ready_btn = Button.new()
	ready_btn.toggle_mode = true
	ready_btn.text = "Ready"
	ready_btn.custom_minimum_size = Vector2(150, 0)
	ready_btn.toggled.connect(func(_on): Net.set_me(ready_btn.button_pressed, false))
	r.add_child(ready_btn)
	start_btn = _button("Start match", Net.start_match, true)
	r.add_child(start_btn)
	r.add_child(_spacer())
	r.add_child(_button("Leave lobby", func(): Net.leave_lobby(); _show("browser")))

func _setup_preview_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	preview.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 35, 0)
	key.light_energy = 1.2
	preview.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-20, 200, 0)
	rim.light_energy = 0.6
	rim.light_color = ACCENT2
	preview.add_child(rim)
	# an original turntable: a dark disc with an accent ring
	var plate := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 0.04
	plate.mesh = cyl
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.13, 0.14, 0.17)
	pm.roughness = 0.6
	plate.material_override = pm
	plate.name = "Plate"
	preview.add_child(plate)
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.985
	tor.outer_radius = 1.02
	ring.mesh = tor
	var rm := StandardMaterial3D.new()
	rm.albedo_color = ACCENT
	rm.emission_enabled = true
	rm.emission = ACCENT
	rm.emission_energy_multiplier = 1.5
	ring.material_override = rm
	ring.name = "Ring"
	preview.add_child(ring)
	preview_turntable = Node3D.new()
	preview.add_child(preview_turntable)
	preview_cam = Camera3D.new()
	preview_cam.fov = 32.0
	preview.add_child(preview_cam)
	preview_cam.current = true

func _clear_preview() -> void:
	preview_vid = ""
	if preview_turntable != null:
		for c in preview_turntable.get_children():
			c.queue_free()

func _set_preview(vid: String) -> void:
	if vid == preview_vid or preview_turntable == null:
		return
	_clear_preview()
	preview_vid = vid
	var model := Game.build_vehicle_model(vid, Game.player_color)
	preview_turntable.add_child(model)
	var size: Vector3 = model.get_meta("size_m", Vector3(2.0, 1.5, 4.2))
	var r := maxf(Vector2(size.x, size.z).length() * 0.5, 1.0)
	var plate_r := r * 1.12
	for n in ["Plate", "Ring"]:
		(preview.get_node(n) as Node3D).scale = Vector3(plate_r, 1, plate_r)
	var dist := r * 3.4 + size.y
	preview_cam.position = Vector3(0, size.y * 0.5 + dist * 0.38, dist)
	preview_cam.look_at(Vector3(0, size.y * 0.35, 0))

func _process(delta: float) -> void:
	if preview_turntable != null and current == "lobby":
		preview_turntable.rotation.y += delta * 0.6

## Vehicles to choose from: the game-data ones when this computer and the server both have
## them, else the eight built-in stand-ins.
func _vehicle_choices() -> PackedStringArray:
	var offered: Array = Net.lobby.get("vehicles", [])
	var out := PackedStringArray()
	for id in Game.disc_vehicle_ids():
		if id in offered:
			out.append(id)
	if out.is_empty():
		for id in Game.builtin_vehicle_ids():
			if offered.is_empty() or id in offered:
				out.append(id)
	return out

func _my_vid() -> String:
	var me := Net.me_in_lobby()
	return str(me.get("vid", Game.player_vid))

func _cycle_vehicle(d: int) -> void:
	var ch := _vehicle_choices()
	if ch.is_empty():
		return
	var i := ch.find(_my_vid())
	var vid := ch[posmod(i + d, ch.size())]
	Game.player_vid = vid
	Game.save_profile()
	Net.set_me(ready_btn.button_pressed)
	_show_vehicle(vid)

func _show_vehicle(vid: String) -> void:
	var ch := _vehicle_choices()
	var pf := Game.profile_for(vid)
	vehicle_name.text = Game.vehicle_name(vid)
	vehicle_special.text = "Special: %s" % pf.special_name.capitalize()
	vehicle_index_label.text = "%d / %d    PgUp / PgDn" % [ch.find(vid) + 1, ch.size()]
	var max_speed := 1.0
	var min_r := 99.0
	var max_r := 0.0
	var max_hp := 1.0
	for id in ch:
		var q := Game.profile_for(id)
		max_speed = maxf(max_speed, q.top_speed)
		min_r = minf(min_r, q.turn_radius)
		max_r = maxf(max_r, q.turn_radius)
		max_hp = maxf(max_hp, q.max_health)
	stat_bars.speed.value = pf.top_speed / max_speed
	stat_bars.turn.value = 1.0 - 0.75 * (pf.turn_radius - min_r) / maxf(max_r - min_r, 0.01)
	stat_bars.armor.value = pf.max_health / max_hp
	_set_preview(vid)

func _send_settings() -> void:
	if _settings_lock or not Net.is_lobby_host():
		return
	var arena := str(Net.lobby.get("settings", {}).get("arena", Game.TEST_YARD))
	var sel := arena_list.get_selected_items()
	if not sel.is_empty():
		arena = str(arena_list.get_item_metadata(sel[0]))
	Net.set_settings({"arena": arena, "score_limit": int(score_spin.value), "time_limit": int(time_spin.value) * 60, "bots": int(bots_spin.value)})

func _rebuild_lobby() -> void:
	if member_rows == null or Net.lobby.is_empty():
		return
	if current == "results":
		return
	if current != "lobby":
		return
	var lb := Net.lobby
	no_data_banner.visible = not Game.has_disc_data()
	page_title.text = str(lb.get("name", "Lobby"))
	var host := Net.is_lobby_host()
	var s: Dictionary = lb.get("settings", {})
	var arena := str(s.get("arena", Game.TEST_YARD))
	for c in member_rows.get_children():
		member_rows.remove_child(c)
		c.queue_free()
	var all_ready := true
	var missing: Array = []
	for m in lb.get("members", []):
		all_ready = all_ready and bool(m.ready)
		if not bool(m.get("has_arena", true)):
			missing.append(str(m.name))
		var pc := PanelContainer.new()
		pc.add_theme_stylebox_override("panel", _sb(ROW, 6, Color(0, 0, 0, 0), 0, Vector4(10, 7, 10, 7)))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		pc.add_child(h)
		var sw := ColorRect.new()
		sw.color = Color.html(str(m.color))
		sw.custom_minimum_size = Vector2(6, 30)
		h.add_child(sw)
		var nv := VBoxContainer.new()
		nv.add_theme_constant_override("separation", 0)
		nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(nv)
		var tag := "  HOST" if int(m.peer) == int(lb.host) else ""
		var n := _label("%s%s" % [m.name, "  (you)" if int(m.peer) == Net.my_id else ""], 16, TEXT)
		nv.add_child(n)
		var sub := _label("%s%s" % [Game.vehicle_name(str(m.get("vid", ""))), tag], 13, ACCENT if tag != "" else MUTED)
		if not bool(m.get("has_arena", true)):
			sub.text += "  no game data for this arena"
			sub.add_theme_color_override("font_color", BAD)
		nv.add_child(sub)
		var rd := _label("READY" if bool(m.ready) else "not ready", 13, GOOD if bool(m.ready) else MUTED)
		rd.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(rd)
		member_rows.add_child(pc)
	for b in lb.get("bots", []):
		member_rows.add_child(_label("  + bot %s (%s)" % [b.name, Game.vehicle_name(str(b.get("vid", "")))], 13, MUTED))
	var me := Net.me_in_lobby()
	if not me.is_empty():
		ready_btn.set_pressed_no_signal(bool(me.ready))
		ready_btn.text = "Ready: ON" if bool(me.ready) else "Ready"
	# vehicle: ask once for the saved favourite if this lobby offers it
	var ch := _vehicle_choices()
	if not _sent_pref and not me.is_empty():
		_sent_pref = true
		if Game.player_vid in ch and str(me.get("vid", "")) != Game.player_vid:
			Net.set_me(bool(me.ready))
	var vid := _my_vid()
	if not (vid in ch) and not ch.is_empty():
		vid = ch[0]
	_show_vehicle(vid)
	# arena
	var mine := Game.local_arena_ids()
	arena_label.text = Game.arena_label(arena) + ("" if arena in mine else "\nYou need game data for this arena.")
	arena_label.add_theme_color_override("font_color", TEXT if arena in mine else BAD)
	_settings_lock = true
	arena_list.visible = host
	if host:
		arena_list.clear()
		for a in lb.get("arenas", [Game.TEST_YARD]):
			if not (str(a) in mine):
				continue
			var idx := arena_list.add_item(Game.arena_label(str(a)))
			arena_list.set_item_metadata(idx, str(a))
			if str(a) == arena:
				arena_list.select(idx)
				arena_list.ensure_current_is_visible()
	host_box.visible = host
	start_btn.visible = host
	var waiting: bool = str(lb.get("state", "")) == "waiting"
	start_btn.disabled = not (all_ready and waiting and missing.is_empty())
	score_spin.value = int(s.get("score_limit", 15))
	time_spin.value = int(s.get("time_limit", 300)) / 60
	bots_spin.value = int(s.get("bots", 4))
	_settings_lock = false
	var n_members: int = lb.get("members", []).size()
	var sub_text := "%d/8 players    score limit %d    %d min    bots up to %d" % [n_members, int(s.get("score_limit", 15)), int(s.get("time_limit", 300)) / 60, int(s.get("bots", 4))]
	page_sub.text = sub_text
	page_sub.visible = true
	lobby_hint.add_theme_color_override("font_color", MUTED)
	if not waiting:
		lobby_hint.text = "A match is running in this lobby; you join it when it loads."
	elif not missing.is_empty():
		lobby_hint.text = "Start is disabled: %s %s no game data for %s (the arena is built on each computer from its own game data). They can load their game data folder on the first screen, or the host can pick another arena." % [
			", ".join(missing), "has" if missing.size() == 1 else "have", Game.arena_label(arena)]
		lobby_hint.add_theme_color_override("font_color", BAD)
	elif host:
		lobby_hint.text = "Start when everyone is ready. Empty places are filled with bots up to %d cars." % int(s.get("bots", 4))
	else:
		lobby_hint.text = "Waiting for the host to start."

# ---------------- results ----------------
func _build_results(parent: Control) -> void:
	var p := _page("results", parent)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	results_title = _label("", 30, ACCENT)
	box.add_child(results_title)
	results_sub = _label("", 14, MUTED)
	box.add_child(results_sub)
	results_rows = VBoxContainer.new()
	results_rows.add_theme_constant_override("separation", 4)
	box.add_child(results_rows)
	var r := _row(p, "")
	results_btn = _button("Back to the lobby", _continue_from_results, true)
	r.add_child(results_btn)

func _rebuild_results() -> void:
	var res := Game.last_results
	results_title.text = "%s wins" % str(res.get("winner", "?")) if str(res.get("winner", "?")) != "?" else "Match over"
	results_sub.text = "Arena: %s" % Game.arena_label(str(res.get("arena", Game.TEST_YARD)))
	for c in results_rows.get_children():
		c.queue_free()
	var head := HBoxContainer.new()
	for t in [["#", 40], ["Driver", 300], ["Kills", 90], ["Deaths", 90]]:
		var l := _label(t[0], 13, MUTED)
		l.custom_minimum_size = Vector2(t[1], 0)
		head.add_child(l)
	results_rows.add_child(head)
	var rank := 1
	for row in res.get("rows", []):
		var pc := PanelContainer.new()
		var is_me: bool = str(row[0]) == str(res.get("me", ""))
		pc.add_theme_stylebox_override("panel", _sb(ROW_HI if is_me else ROW, 5, ACCENT if is_me else Color(0, 0, 0, 0), 1 if is_me else 0, Vector4(0, 6, 0, 6)))
		var h := HBoxContainer.new()
		pc.add_child(h)
		var cells := [[str(rank), 40], [str(row[0]), 300], [str(row[2]), 90], [str(row[3]), 90]]
		for i in cells.size():
			var l := _label(cells[i][0], 17, (row[1] as Color).lightened(0.25) if i == 1 else TEXT)
			l.custom_minimum_size = Vector2(cells[i][1], 0)
			if i == 0:
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			h.add_child(l)
		results_rows.add_child(pc)
		rank += 1

func _continue_from_results() -> void:
	Game.last_results = {}
	_show("lobby" if Net.state == "lobby" else "server")

# ---------------- settings ----------------
func _build_settings(parent: Control) -> void:
	var p := _page("settings", parent)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var r0 := _row(box, "Texture quality", 170)
	tex_opt = OptionButton.new()
	for i in DiscSettingsS.UPSCALE_CHOICES.size():
		tex_opt.add_item("%s%s" % [["Original (no upscaling)", "Sharp (2x upscale)", "Sharpest (4x upscale)"][i],
			"  default" if DiscSettingsS.UPSCALE_CHOICES[i] == DiscSettingsS.default_upscale() else ""])
	tex_opt.item_selected.connect(func(i):
		DiscSettingsS.set_texture_upscale(DiscSettingsS.UPSCALE_CHOICES[i])
		DiscArenaS.clear_cache())
	r0.add_child(tex_opt)
	box.add_child(_hint("Game-data textures are upscaled once and cached on this computer. 4x looks best at 1080p and above; the first load of each arena takes about a second longer."))
	if not OS.has_feature("web"):
		var r1 := _row(box, "Window", 170)
		win_opt = OptionButton.new()
		win_opt.add_item("Windowed")
		win_opt.add_item("Fullscreen")
		win_opt.item_selected.connect(func(i):
			Game.set_display_setting("fullscreen", i == 1)
			Game.apply_display_settings()
			_refresh_settings())
		r1.add_child(win_opt)
		var r2 := _row(box, "Window size", 170)
		res_opt = OptionButton.new()
		for res in Game.RESOLUTIONS:
			res_opt.add_item("%d x %d" % [res.x, res.y])
		res_opt.item_selected.connect(func(i):
			Game.set_display_setting("resolution", Game.RESOLUTIONS[i])
			Game.apply_display_settings())
		r2.add_child(res_opt)
	var r3 := _row(box, "3D render scale", 170)
	scale_opt = OptionButton.new()
	for sc in Game.RENDER_SCALES:
		scale_opt.add_item("%d%%" % roundi(sc * 100.0))
	scale_opt.item_selected.connect(func(i):
		Game.set_display_setting("render_scale", Game.RENDER_SCALES[i])
		Game.apply_display_settings())
	r3.add_child(scale_opt)
	box.add_child(_hint("Render scale draws the 3D view at a lower resolution and scales it up; the menus and HUD stay sharp. Lower it if the game stutters."))
	var r4 := _row(box, "Menus and HUD", 170)
	menus_opt = OptionButton.new()
	menus_opt.add_item("Original (from your game data)")
	menus_opt.add_item("Modern")
	menus_opt.item_selected.connect(func(i):
		var c := ConfigFile.new()
		c.load("user://settings.cfg")
		c.set_value("video", "menus", "original" if i == 0 else "modern")
		c.save("user://settings.cfg")
		if i == 0 and DiscUI.available():
			classic_off = false
			_show("server"))
	r4.add_child(menus_opt)
	var r := _row(p, "")
	r.add_child(_button("Done", _go_back, true))

func _hint(t: String) -> Label:
	var l := _label(t, 13, MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	return l

func _refresh_settings() -> void:
	tex_opt.selected = maxi(DiscSettingsS.UPSCALE_CHOICES.find(DiscSettingsS.texture_upscale()), 0)
	if win_opt != null:
		var fs := bool(Game.display_setting("fullscreen", false))
		win_opt.selected = 1 if fs else 0
		res_opt.disabled = fs
		var res: Vector2i = Game.display_setting("resolution", Vector2i(1280, 720))
		res_opt.selected = maxi(Game.RESOLUTIONS.find(res), 0)
	var sc := float(Game.display_setting("render_scale", 1.0))
	var best := 0
	for i in Game.RENDER_SCALES.size():
		if absf(Game.RENDER_SCALES[i] - sc) < absf(Game.RENDER_SCALES[best] - sc):
			best = i
	scale_opt.selected = best
	if menus_opt != null:
		menus_opt.disabled = not DiscUI.available()
		menus_opt.selected = 0 if DiscUI.classic_enabled() else 1
