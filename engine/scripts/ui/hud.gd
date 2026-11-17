class_name Hud
extends CanvasLayer
## In-match HUD: bars, weapon, score, timer, kill feed, scoreboard, pause menu, centre message.

signal resume_pressed
signal leave_pressed

var hp_bar: ProgressBar
var heat_bar: ProgressBar
var turbo_bar: ProgressBar
var weapon_label: Label
var score_label: Label
var time_label: Label
var speed_label: Label
var center_label: Label
var feed_box: VBoxContainer
var board_panel: PanelContainer
var board_grid: GridContainer
var pause_panel: PanelContainer
# original-style HUD from the player's game data (scripts/ui/classic_hud.gd); null otherwise
var classic: Control
var board_rows: Array = []

func _bar(color: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(260, 20)
	b.show_percentage = false
	b.max_value = 100
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	b.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	b.add_theme_stylebox_override("background", bg)
	return b

func _label(size: int, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = align
	return l

func _ready() -> void:
	ClassicControls.apply()
	MenuSounds.apply_volumes()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bl := VBoxContainer.new()
	bl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bl.position = Vector2(24, -140)
	bl.size = Vector2(300, 120)
	bl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(bl)
	hp_bar = _bar(Color(0.85, 0.2, 0.2))
	heat_bar = _bar(Color(0.95, 0.55, 0.15))
	heat_bar.max_value = Weapons.HEAT_LOCK
	heat_bar.custom_minimum_size = Vector2(260, 8)
	turbo_bar = _bar(Color(0.3, 0.75, 1.0))
	turbo_bar.custom_minimum_size = Vector2(260, 8)
	weapon_label = _label(22)
	speed_label = _label(18)
	bl.add_child(weapon_label)
	bl.add_child(hp_bar)
	bl.add_child(heat_bar)
	bl.add_child(turbo_bar)
	bl.add_child(speed_label)

	var tc := VBoxContainer.new()
	tc.set_anchors_preset(Control.PRESET_CENTER_TOP)
	tc.position = Vector2(-120, 12)
	tc.size = Vector2(240, 60)
	root.add_child(tc)
	time_label = _label(32, HORIZONTAL_ALIGNMENT_CENTER)
	score_label = _label(20, HORIZONTAL_ALIGNMENT_CENTER)
	tc.add_child(time_label)
	tc.add_child(score_label)

	if not Game.has_disc_data():
		# persistent: the player is on stand-in content (no game data or the import failed)
		var nd := _label(15, HORIZONTAL_ALIGNMENT_CENTER)
		nd.text = "No game data loaded: you're seeing built-in stand-in arenas and cars. Load your game data folder on the first screen to play with your own disc's content."
		nd.autowrap_mode = TextServer.AUTOWRAP_WORD
		nd.add_theme_color_override("font_color", Color(1.0, 0.75, 0.6))
		nd.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		nd.position = Vector2(-330, -64)
		nd.size = Vector2(660, 52)
		nd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(nd)

	feed_box = VBoxContainer.new()
	feed_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	feed_box.position = Vector2(-420, 12)
	feed_box.size = Vector2(400, 200)
	feed_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(feed_box)

	center_label = _label(40, HORIZONTAL_ALIGNMENT_CENTER)
	center_label.set_anchors_preset(Control.PRESET_CENTER)
	center_label.position = Vector2(-400, -120)
	center_label.size = Vector2(800, 80)
	root.add_child(center_label)

	board_panel = PanelContainer.new()
	board_panel.set_anchors_preset(Control.PRESET_CENTER)
	board_panel.position = Vector2(-260, -200)
	board_panel.custom_minimum_size = Vector2(520, 300)
	board_panel.visible = false
	root.add_child(board_panel)
	var bv := VBoxContainer.new()
	board_panel.add_child(bv)
	var bt := _label(26, HORIZONTAL_ALIGNMENT_CENTER)
	bt.text = "Scoreboard"
	bv.add_child(bt)
	board_grid = GridContainer.new()
	board_grid.columns = 3
	board_grid.add_theme_constant_override("h_separation", 40)
	bv.add_child(board_grid)

	pause_panel = PanelContainer.new()
	pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	pause_panel.position = Vector2(-120, -80)
	pause_panel.visible = false
	root.add_child(pause_panel)
	var pv := VBoxContainer.new()
	pv.custom_minimum_size = Vector2(240, 0)
	pause_panel.add_child(pv)
	var pt := _label(26, HORIZONTAL_ALIGNMENT_CENTER)
	pt.text = "Menu"
	pv.add_child(pt)
	var rb := Button.new()
	rb.text = "Resume"
	rb.pressed.connect(func(): resume_pressed.emit())
	pv.add_child(rb)
	var lb := Button.new()
	lb.text = "Leave match"
	lb.pressed.connect(func(): leave_pressed.emit())
	pv.add_child(lb)
	if DiscUI.classic_enabled() and not Game.args.has("modern-menus"):
		_use_classic(root)

## Original layout: the modern widgets stay (the match sets their visibility, which the classic
## HUD reads) but are not drawn.
func _use_classic(root: Control) -> void:
	for c in root.get_children():
		if c is CanvasItem:
			c.modulate.a = 0.0
	for b in [pause_panel, board_panel]:
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for c in b.find_children("*", "Button", true, false):
			(c as Button).focus_mode = Control.FOCUS_NONE
			(c as Button).mouse_filter = Control.MOUSE_FILTER_IGNORE
	classic = load("res://scripts/ui/classic_hud.gd").new(self)
	add_child(classic)

func update_local(v: Vehicle, kills: int, limit: int, time_left: float) -> void:
	if classic != null:
		classic.update(v, kills, limit, time_left)
		return
	if v != null:
		hp_bar.max_value = v.max_hp
		hp_bar.value = v.hp
		heat_bar.value = v.heat
		var fill: StyleBoxFlat = heat_bar.get_theme_stylebox("fill")
		fill.bg_color = Color(0.9, 0.15, 0.1) if v.mg_locked else Color(0.95, 0.55, 0.15)
		turbo_bar.max_value = v.profile.turbo_tanks * v.profile.turbo_tank_time
		turbo_bar.value = v.turbo_fuel
		var w: String = Weapons.NAMES[v.weapon] if v.weapon < Weapons.NAMES.size() else "?"
		if v.weapon == Weapons.SPECIAL:
			w = "%s (special)" % v.profile.special_name
		weapon_label.text = "%s x%d   energy %d/%d" % [w, v.ammo_count(v.weapon), v.energy, Weapons.ENERGY_MAX]
		speed_label.text = "%d km/h%s%s%s" % [int(v.speed() * 3.6), "   SHIELD" if v.protect > 0.0 else "", "   FROZEN" if v.frozen > 0.0 else "", "   GUN HOT" if v.mg_locked else ""]
	var t := maxi(int(time_left), 0)
	time_label.text = "%d:%02d" % [t / 60, t % 60]
	score_label.text = "Kills %d / %d" % [kills, limit]

func set_center(text: String) -> void:
	if classic != null:
		# death and match end have their own presentation in the original layout
		classic.center = text if text.begins_with("Waiting") or text.begins_with("Joining") else ""
	center_label.text = text

func add_feed(text: String) -> void:
	if classic != null:
		return   # the original has no text feed; scores are on Tab
	var l := _label(18, HORIZONTAL_ALIGNMENT_RIGHT)
	l.text = text
	feed_box.add_child(l)
	while feed_box.get_child_count() > 6:
		feed_box.get_child(0).queue_free()
		feed_box.remove_child(feed_box.get_child(0))
	get_tree().create_timer(7.0).timeout.connect(l.queue_free)

# rows: Array of [name, color, kills, deaths]
func update_board(rows: Array) -> void:
	board_rows = rows
	if classic != null:
		return
	for c in board_grid.get_children():
		c.queue_free()
		board_grid.remove_child(c)
	for h in ["Player", "Kills", "Deaths"]:
		var hl := _label(18)
		hl.text = h
		board_grid.add_child(hl)
	for r in rows:
		var nl := _label(18)
		nl.text = r[0]
		nl.add_theme_color_override("font_color", r[1])
		var kl := _label(18)
		kl.text = str(r[2])
		var dl := _label(18)
		dl.text = str(r[3])
		board_grid.add_child(nl)
		board_grid.add_child(kl)
		board_grid.add_child(dl)
