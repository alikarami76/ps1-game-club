extends Control
## In-match HUD in the original's layout, drawn with the disc's fonts (game data only).
## Layout measured from emulator frames of the original (320x240), anchored to the window's
## corners: left items keep their distance from the left edge, right items from the right edge,
## centre items from the centre, all scaled by window height / 240.
##
##  top left      radar box (enemies as dots, turned with your heading)
##  top centre    the targeted opponent: name banner whose fill is its health, your kills (green)
##                and its kills (red)
##  bottom left   speed, large thin red digits
##  bottom right  health bar, "Turbo: n" with the tank blocks, "Gun Tmp" with a burning fuse
##                (machine-gun heat), the selected weapon's label and its ammo
## Match start: the original's "WELCOME! Prepare for... '<STAGE>'" and "Meet Your Opponents"
## card. Death: a red flash. Match end: "CONGRATULATIONS!" or "YOU LOSE!". Tab: scores.
## Esc: "BATTLE PAUSED" with CONTINUE / ABORT BATTLE.

const UI := preload("res://scripts/ui/disc_ui.gd")
const C_TEXT := Color8(48, 160, 48)
const C_SHEET := Color8(70, 232, 70)        # sheet grey 176 drawn in this gives C_TEXT
const C_BANNER_TEXT := Color8(56, 232, 64)
const C_SPEED := Color8(192, 0, 56)
const C_LABEL := Color8(160, 40, 16)
const C_GOLD := Color8(216, 160, 64)
const C_ITEM := Color8(176, 56, 40)
const C_SEL := Color8(216, 112, 48)
const C_NOTE := Color8(208, 200, 248)
const WEAPON_LABELS := ["GUNS", "FIRE", "HOMING", "POWER", "FREEZE", "MINE", "SPECIAL"]

var hud: Hud
var fonts := {}
var me: Vehicle = null
var kills := 0
var limit := 0
var time_left := 0.0
var center := ""
var target_slot := -1
var t := 0.0
var intro_t := 0.0
var intro_done := false
var red_flash := 0.0
var was_alive := true
var pause_sel := 0
var _route_acc := 0.0

func _init(owner: Hud) -> void:
	hud = owner

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# original pixels stay square-cut; upscaled art is close to 1:1 on screen, so filter it
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if UI.scale() == 1 else CanvasItem.TEXTURE_FILTER_LINEAR
	for f in ["menu", "big", "small", "digits"]:
		fonts[f] = UI.font(f)
	get_tree().create_timer(4.0).timeout.connect(func():
		print("[ui] memory after match load: static %d MB, video %d MB, texture upscale 3D x%d UI x%d" % [
			int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0),
			int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
			DiscSettings.texture_upscale(), UI.scale()]))

func _match() -> Node:
	return hud.get_parent()

func _mget(k: String, d = null):
	var m := _match()
	if m == null:
		return d
	var v = m.get(k)
	return d if v == null else v

# ---------------- layout helpers ----------------
func _k() -> float:
	return size.y / 240.0

## Screen position of a 320x240 point anchored "l" (left), "c" (centre) or "r" (right).
func _p(x: float, y: float, a := "l") -> Vector2:
	var k := _k()
	match a:
		"r":
			return Vector2(size.x - (320.0 - x) * k, y * k)
		"c":
			return Vector2(size.x * 0.5 + (x - 160.0) * k, y * k)
	return Vector2(x * k, y * k)

func _rect(x: float, y: float, w: float, h: float, col: Color, a := "l") -> void:
	draw_rect(Rect2(_p(x, y, a), Vector2(w, h) * _k()), col)

func _txt(font: String, x: float, y: float, tx: String, col: Color, a := "l", s := 1.0) -> void:
	var f = fonts.get(font)
	if f != null:
		f.draw(self, _p(x, y, a), tx, col, _k() * s)

func _ctxt(font: String, y: float, tx: String, col: Color, s := 1.0) -> void:
	var f = fonts.get(font)
	if f != null:
		f.draw_centered(self, size.x * 0.5, y * _k(), tx, col, _k() * s)

func _health_col(f: float) -> Color:
	if f > 0.5:
		return Color8(16, 112, 16)
	if f > 0.25:
		return Color8(176, 104, 16)
	return Color8(176, 24, 16)

# ---------------- state ----------------
func update(v: Vehicle, k: int, lim: int, tl: float) -> void:
	me = v
	kills = k
	limit = lim
	time_left = tl

func _pick_target() -> int:
	var vs: Dictionary = _mget("vehicles", {})
	var my := int(_mget("my_slot", -1))
	if me == null or not is_instance_valid(me):
		return target_slot
	var fwd := -me.global_transform.basis.z
	var best := -1
	var best_score := INF
	for slot in vs:
		var v: Vehicle = vs[slot]
		if int(slot) == my or v == null or not is_instance_valid(v) or not v.alive:
			continue
		var d: Vector3 = v.global_position - me.global_position
		var dist := d.length()
		var ahead := fwd.dot(d / maxf(dist, 0.01))
		var score := dist * (1.0 if ahead > 0.7 else 2.5)   # prefer cars in front, like a lock-on
		if score < best_score:
			best_score = score
			best = int(slot)
	if best >= 0:
		target_slot = best
	return target_slot

func _process(delta: float) -> void:
	t += delta
	intro_t += delta
	red_flash = maxf(red_flash - delta, 0.0)
	if me != null and is_instance_valid(me):
		if was_alive and not me.alive:
			red_flash = 0.7
		was_alive = me.alive
	if not intro_done and (intro_t > 3.4 and bool(_mget("started", false)) or bool(_mget("over", false))):
		intro_done = true
	_route_acc -= delta
	if _route_acc <= 0.0:
		_route_acc = 1.0
		_route_audio_and_tags()
	queue_redraw()

## Hides the floating name tags (the original has none; [video] name_tags turns them on) and
## puts the match's sounds on the Effects / Music buses of the audio settings.
func _route_audio_and_tags() -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	var tags := bool(c.get_value("video", "name_tags", false))
	for v in _mget("vehicles", {}).values():
		if v == null or not is_instance_valid(v):
			continue
		if v.label != null:
			# the vehicle sets the tag's visibility every frame, so hide it by transparency
			v.label.modulate.a = 1.0 if tags else 0.0
			v.label.outline_modulate.a = 1.0 if tags else 0.0
		if v.engine_player != null:
			v.engine_player.bus = "Effects"
	if Game.sfx != null and is_instance_valid(Game.sfx):
		for ch in Game.sfx.get_children():
			if ch is AudioStreamPlayer or ch is AudioStreamPlayer3D:
				ch.bus = "Music" if ch == Game.sfx.music else "Effects"

func _input(event: InputEvent) -> void:
	if not intro_done and intro_t > 0.6 and (event is InputEventKey or event is InputEventJoypadButton) and event.is_pressed() \
			and not event.is_action("accelerate") and not event.is_action("steer_left") and not event.is_action("steer_right"):
		intro_done = true
	if not hud.pause_panel.visible:
		return
	if event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down"):
		pause_sel = 1 - pause_sel
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		if pause_sel == 0:
			hud.resume_pressed.emit()
		else:
			hud.leave_pressed.emit()

# ---------------- drawing ----------------
func _draw() -> void:
	if not intro_done:
		_draw_intro()
		return
	if red_flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.75, 0.0, 0.0, 0.55 * minf(red_flash / 0.4, 1.0)))
	if me != null and is_instance_valid(me) and not me.alive:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.25))
	_draw_radar()
	_draw_target()
	_draw_panel()
	if hud.board_panel.visible:
		_draw_board()
	if bool(_mget("over", false)):
		_draw_over()
	elif center != "":
		_draw_center_note(center)
	if hud.pause_panel.visible:
		_draw_pause()

func _draw_radar() -> void:
	_rect(16, 32, 74, 46, Color(0.16, 0.32, 0.08, 0.42))
	if me == null or not is_instance_valid(me):
		return
	var c := Vector2(53, 55)
	var inv := me.global_transform.affine_inverse()
	for slot in _mget("vehicles", {}):
		var v: Vehicle = _mget("vehicles", {})[slot]
		if v == null or not is_instance_valid(v) or v == me or not v.alive:
			continue
		var l: Vector3 = inv * v.global_position
		var p := c + Vector2(l.x, l.z) * 0.33
		if p.x < 17 or p.x > 88 or p.y < 33 or p.y > 76:
			continue
		var col := Color8(232, 40, 32) if int(slot) == target_slot else Color8(200, 200, 64)
		_rect(p.x - 1, p.y - 1, 2, 2, col)
	_rect(c.x - 1, c.y - 1, 2, 2, C_BANNER_TEXT)

func _draw_target() -> void:
	var slot := _pick_target()
	var vs: Dictionary = _mget("vehicles", {})
	if slot < 0 or not vs.has(slot):
		return
	var v: Vehicle = vs[slot]
	if v == null or not is_instance_valid(v):
		return
	var frac := clampf(v.hp / maxf(v.max_hp, 1.0), 0.0, 1.0)
	_rect(103, 22, 87, 13, Color(0.03, 0.2, 0.03, 0.65), "c")
	_rect(103, 22, 87 * frac, 13, Color(_health_col(frac), 0.55), "c")
	var vid := v.vid
	var nm := UI.vehicle_name(vid) if Game.has_disc_model(vid) else str(v.info.get("name", "?")).to_upper()
	var f = fonts.get("small")
	if f != null:
		f.draw(self, _p(146.5 - f.width(nm) * 0.5, 24, "c"), nm, C_BANNER_TEXT, _k())
	var sc: Dictionary = _mget("scores", {})
	_txt("small", 136, 40, str(kills), C_BANNER_TEXT, "c")
	_txt("small", 182, 40, str(sc.get(slot, [0, 0])[0]), Color8(232, 40, 32), "c")

# Sprites of the arena's HUD sheet (128x128), measured from the sheet: labels, digits, icons.
const S_GUN := Rect2(0, 45, 37, 9)
const S_TURBO := Rect2(0, 55, 25, 7)
const S_BLOCK := Rect2(2, 36, 7, 4)
const S_SMALL := {"0": [27, 55], "1": [32, 55], "2": [42, 65], "3": [42, 55], "4": [53, 65], "5": [54, 55], "6": [66, 65], "7": [66, 55], "8": [73, 55], "9": [79, 55]}
const S_BIG := {"0": [42, 7], "1": [51, 4], "2": [57, 7], "3": [65, 7], "4": [74, 8], "5": [84, 7], "6": [93, 7], "7": [101, 8], "8": [110, 7], "9": [118, 7]}
const S_ICONS := {Weapons.POWER: Rect2(33, 0, 30, 15)}
var _sheet: Texture2D
var _sheet_tried := false

func _sheet_tex() -> Texture2D:
	if not _sheet_tried:
		_sheet_tried = true
		_sheet = UI.hud_sheet(str(_mget("arena_id", "")))
	return _sheet

func _sprite(src: Rect2, x: float, y: float, a: String, col := Color.WHITE) -> void:
	var sh := _sheet_tex()
	if sh != null:
		draw_texture_rect_region(sh, Rect2(_p(x, y, a), src.size * _k()), UI.region(src), col)

## Turbo's number in the sheet's small digits (5 px apart, like the original's "Turbo: 20").
func _small_num(n: int, x: float, y: float, a: String, col: Color) -> void:
	var tx := str(n)
	for i in tx.length():
		var d: Array = S_SMALL[tx[i]]
		_sprite(Rect2(d[0], d[1], 6, 7), x + i * 6, y, a, col)

func _big_num(n: int, x: float, y: float, a: String, col: Color) -> void:
	var tx := str(n)
	var cx := x
	for i in tx.length():
		var d: Array = S_BIG[tx[i]]
		_sprite(Rect2(d[0], 45, d[1], 9), cx, y, a, col)
		cx += d[1] + 1

func _draw_panel() -> void:
	if me == null or not is_instance_valid(me):
		return
	var sheet := _sheet_tex() != null
	# speed (bottom left)
	# the original shows raw speed / 22 (raw = 1/32 world unit per tick): about 60-70 at full speed
	var spd := me.speed() / maxf(VehicleProfile.speed_to_ms(1.0), 0.0001) * 32.0 / 22.0
	var f = fonts.get("digits")
	if f != null:
		f.draw(self, _p(120, 196), str(int(spd)), C_SPEED, _k() * 1.3)
	# tournament: spare lives as the three squares right of the health bar
	var st: Dictionary = _mget("settings", {})
	if str(st.get("mode", "")) == "tournament":
		var deaths := int(_mget("scores", {}).get(int(_mget("my_slot", -1)), [0, 0])[1])
		var spare := int(st.get("lives_left", 4)) - deaths - 1
		for i in clampi(spare, 0, 3):
			_rect(311, 190 + 5 * i, 5, 4, Color8(32, 152, 32), "r")
	# health bar
	var frac := clampf(me.hp / maxf(me.max_hp, 1.0), 0.0, 1.0)
	_rect(217, 191, 88, 8, Color(0.03, 0.2, 0.03, 0.55), "r")
	_rect(217, 191, 88 * frac, 8, _health_col(frac), "r")
	# turbo: "Turbo:" and the number, then one block per tank
	var full := float(me.profile.turbo_tanks) * me.profile.turbo_tank_time
	var turbo := roundi(20.0 * me.turbo_fuel / maxf(full, 0.01))
	if sheet:
		_sprite(S_TURBO, 216, 203, "r", C_SHEET)
		_small_num(turbo, 245, 203, "r", C_SHEET)
	else:
		_txt("small", 216, 202, "Turbo: %d" % turbo, C_TEXT, "r")
	var tanks := ceili(me.turbo_fuel / maxf(me.profile.turbo_tank_time, 0.01) - 0.001)
	for i in me.profile.turbo_tanks:
		var col := Color8(40, 112, 32) if i < tanks else Color(0.05, 0.2, 0.05, 0.6)
		if sheet:
			_sprite(S_BLOCK, 263 + 10 * i, 203, "r", Color.WHITE if i < tanks else Color(0.3, 0.3, 0.3, 0.6))
		else:
			_rect(263 + 10 * i, 203, 7, 4, col, "r")
	# gun temperature: the fuse burns towards the spark as the guns heat up
	if sheet:
		_sprite(S_GUN, 216, 216, "r", C_SHEET)
	else:
		_txt("small", 216, 215, "Gun Tmp", C_TEXT, "r")
	var heat := clampf(me.heat / Weapons.HEAT_LOCK, 0.0, 1.0)
	var hot := me.mg_locked and int(t * 6) % 2 == 0
	_rect(256, 213, 30, 1, Color8(96, 24, 8), "r")
	_rect(256, 213, 30 * heat, 1, Color8(255, 160, 32) if not hot else Color8(255, 40, 16), "r")
	_rect(255 + 30 * heat, 211, 3, 3, Color8(255, 220, 96), "r")
	# weapon label (or the sheet's icon) and ammo
	var w: int = me.weapon
	if sheet and S_ICONS.has(w):
		_sprite(S_ICONS[w], 256, 214, "r")
	else:
		_txt("small", 256, 218, WEAPON_LABELS[w] if w < WEAPON_LABELS.size() else "?", C_LABEL, "r", 0.75)
	if sheet:
		_big_num(me.ammo_count(w), 292, 213, "r", C_SHEET)
	else:
		_txt("small", 292, 213, str(me.ammo_count(w)), C_TEXT, "r")

func _draw_center_note(tx: String) -> void:
	_ctxt("small", 150, tx, C_NOTE)

func _draw_over() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	var roster: Dictionary = _mget("roster", {})
	var my := int(_mget("my_slot", -1))
	var best := -1
	var bk := -1
	for slot in _mget("scores", {}):
		var k: int = _mget("scores", {})[slot][0]
		if k > bk:
			bk = k
			best = int(slot)
	var won := best == my and my >= 0
	_ctxt("big", 104, UI.text("congratulations", "CONGRATULATIONS!") if won else UI.text("you_lose", "YOU LOSE!"), C_GOLD)
	if not won and best >= 0:
		_ctxt("small", 132, "%s WINS" % str(_match().call("_name_of", best)).to_upper(), C_NOTE)

func _draw_board() -> void:
	var k := _k()
	var w := 220.0
	var top := 44.0
	var rows: Array = hud.board_rows
	var h := 40.0 + rows.size() * 12
	draw_rect(Rect2(_p(160 - w * 0.5, top, "c"), Vector2(w, h) * k), Color(0, 0, 0, 0.7))
	_ctxt("menu", top + 4, "SCORES", C_SEL)
	var tl := maxi(int(time_left), 0)
	_txt("small", 160 + w * 0.5 - 30, top + 6, "%d:%02d" % [tl / 60, tl % 60], C_NOTE, "c")
	_txt("small", 160 - w * 0.5 + 8, top + 22, "DRIVER", C_GOLD, "c")
	_txt("small", 160 + 30, top + 22, "KILLS", C_GOLD, "c")
	_txt("small", 160 + 66, top + 22, "DEATHS", C_GOLD, "c")
	var y := top + 34
	for r in rows:
		_txt("small", 160 - w * 0.5 + 8, y, str(r[0]).left(16), (r[1] as Color).lightened(0.3), "c")
		_txt("small", 160 + 40, y, str(r[2]), C_NOTE, "c")
		_txt("small", 160 + 80, y, str(r[3]), C_NOTE, "c")
		y += 12
	if limit > 0:
		_txt("small", 160 - w * 0.5 + 8, y + 2, "FIRST TO %d KILLS" % limit, C_NOTE, "c")

func _draw_pause() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.45))
	_ctxt("big", 84, UI.text("paused", "BATTLE PAUSED"), C_GOLD)
	var f = fonts.get("menu")
	if f == null:
		return
	var labels := ["CONTINUE", "ABORT BATTLE"]
	for i in 2:
		f.draw_centered(self, size.x * 0.5, (124 + 20 * i) * _k(), labels[i], C_SEL if i == pause_sel else C_ITEM, _k())

# ---------------- match intro ----------------
## The original's stage intro: the window screen (SCRNE21P) dimmed, "WELCOME!", "Prepare for...",
## the stage's name (from the disc), then an opponent's card tilted in the window and
## "Meet Your Opponents". Drawn on the 4:3 stage, letterboxed.
func _draw_intro() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK)
	var k := _k()
	var off := Vector2((size.x - 320 * k) * 0.5, 0)
	draw_set_transform(off, 0, Vector2(k, k))
	var bg := UI.screen("scrne21p")
	if bg != null:
		draw_texture_rect(bg, Rect2(0, 0, 320, 240), false)
	draw_rect(Rect2(0, 0, 320, 240), Color(0, 0, 0, 0.5))
	var big = fonts.get("big")
	var arena := str(_mget("arena_id", ""))
	if intro_t < 1.8:
		var slide := maxf(0.0, 1.0 - intro_t / 0.35) * 200.0
		if big != null:
			var st: Dictionary = _mget("settings", {})
			var later := str(st.get("mode", "")) == "tournament" and int(st.get("level", 1)) > 1
			big.draw_centered(self, 160 + slide, 56, UI.text("congratulations", "CONGRATULATIONS!") if later else UI.text("welcome", "WELCOME!"), C_GOLD)
			big.draw_centered(self, 160 + slide, 86, UI.text("prepare", "Prepare for..."), C_GOLD)
			var y := 116
			for line in UI.stage_lines(arena):
				big.draw_centered(self, 160 + slide, y, str(line), C_GOLD)
				y += 30
	else:
		var opp := ""
		var roster: Dictionary = _mget("roster", {})
		var my := int(_mget("my_slot", -1))
		for slot in roster:
			if int(slot) != my:
				opp = str(roster[slot].get("vid", ""))
				break
		var card := UI.card(opp) if opp != "" else null
		if card != null:
			var a := deg_to_rad(-8.0)
			draw_set_transform(off + Vector2(160, 97) * k, a, Vector2(k, k))
			draw_texture_rect(card, Rect2(-64, -32, 128, 64), false)
			draw_set_transform(off, 0, Vector2(k, k))
		var slide2 := maxf(0.0, 1.0 - (intro_t - 1.8) / 0.35) * -220.0
		if big != null:
			var meet := UI.text("meet", "Meet Your Opponents")
			if roster.size() <= 2 and meet.ends_with("s"):
				meet = meet.left(meet.length() - 1)
			big.draw_centered(self, 158 + slide2, 199, meet, C_GOLD)
		if intro_t > 3.4 and not bool(_mget("started", false)):
			var sf = fonts.get("small")
			if sf != null:
				sf.draw_centered(self, 160, 228, "WAITING FOR PLAYERS...", C_NOTE)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
