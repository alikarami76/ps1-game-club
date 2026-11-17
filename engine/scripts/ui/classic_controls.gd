class_name ClassicControls
extends RefCounted
## Gamepad layouts named after the original's four controller set-ups (the controls screen shows
## the disc's picture of each). Stored in user://settings.cfg [controls] preset (0-3). Keyboard
## bindings are not changed. Applied to the input map at start-up of the menus and of a match.
## Buttons use the PlayStation names: cross = A (0), circle = B (1), square = X (2),
## triangle = Y (3), L1 = 9, R1 = 10; L2 / R2 are the trigger axes.

const CROSS := JOY_BUTTON_A
const CIRCLE := JOY_BUTTON_B
const SQUARE := JOY_BUTTON_X
const TRIANGLE := JOY_BUTTON_Y
const L1 := JOY_BUTTON_LEFT_SHOULDER
const R1 := JOY_BUTTON_RIGHT_SHOULDER
const L2 := -1   # axis JOY_AXIS_TRIGGER_LEFT
const R2 := -2   # axis JOY_AXIS_TRIGGER_RIGHT

const NAMES := ["CONTROL FREAK", "STANDARD", "DEADLY FORCE", "RUN 'N GUN"]
const PRESETS := [
	{L2: "brake", L1: "weapon_prev", R2: "handbrake", R1: "weapon_next", SQUARE: "fire_mg", TRIANGLE: "turbo", CIRCLE: "fire_special", CROSS: "accelerate"},
	{L2: "fire_special", L1: "weapon_prev", R2: "fire_mg", R1: "weapon_next", SQUARE: "accelerate", TRIANGLE: "turbo", CIRCLE: "brake", CROSS: "handbrake"},
	{L2: "brake", L1: "weapon_prev", R2: "handbrake", R1: "weapon_next", SQUARE: "fire_special", TRIANGLE: "turbo", CIRCLE: "fire_mg", CROSS: "accelerate"},
	{L2: "handbrake", L1: "turbo", R2: "accelerate", R1: "brake", SQUARE: "fire_mg", TRIANGLE: "weapon_next", CIRCLE: "weapon_prev", CROSS: "fire_special"},
]
const ACTIONS := ["accelerate", "brake", "steer_left", "steer_right", "fire_mg", "fire_special", "weapon_next",
	"weapon_prev", "turbo", "handbrake", "pause_menu", "scoreboard"]

static func preset() -> int:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return clampi(int(c.get_value("controls", "preset", 1)), 0, 3)

static func set_preset(i: int) -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value("controls", "preset", clampi(i, 0, 3))
	c.save("user://settings.cfg")
	apply()

static func _button(b: int) -> InputEvent:
	if b == L2 or b == R2:
		var m := InputEventJoypadMotion.new()
		m.axis = JOY_AXIS_TRIGGER_LEFT if b == L2 else JOY_AXIS_TRIGGER_RIGHT
		m.axis_value = 1.0
		return m
	var e := InputEventJoypadButton.new()
	e.button_index = b
	return e

static func _add(action: String, ev: InputEvent) -> void:
	if InputMap.has_action(action):
		InputMap.action_add_event(action, ev)

static func _axis(axis: int, v: float) -> InputEvent:
	var m := InputEventJoypadMotion.new()
	m.axis = axis
	m.axis_value = v
	return m

## Replaces the gamepad events of the driving actions with the chosen layout.
static func apply() -> void:
	for a in ACTIONS:
		if not InputMap.has_action(a):
			continue
		for ev in InputMap.action_get_events(a):
			if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
				InputMap.action_erase_event(a, ev)
	var p: Dictionary = PRESETS[preset()]
	for b in p:
		_add(p[b], _button(b))
	# the direction pad and the left stick are the same in every layout
	var up := InputEventJoypadButton.new()
	up.button_index = JOY_BUTTON_DPAD_UP
	_add("accelerate", up)
	var dn := InputEventJoypadButton.new()
	dn.button_index = JOY_BUTTON_DPAD_DOWN
	_add("brake", dn)
	var lt := InputEventJoypadButton.new()
	lt.button_index = JOY_BUTTON_DPAD_LEFT
	_add("steer_left", lt)
	var rt := InputEventJoypadButton.new()
	rt.button_index = JOY_BUTTON_DPAD_RIGHT
	_add("steer_right", rt)
	_add("steer_left", _axis(JOY_AXIS_LEFT_X, -1.0))
	_add("steer_right", _axis(JOY_AXIS_LEFT_X, 1.0))
	var st := InputEventJoypadButton.new()
	st.button_index = JOY_BUTTON_START
	_add("pause_menu", st)
	var sel := InputEventJoypadButton.new()
	sel.button_index = JOY_BUTTON_BACK
	_add("scoreboard", sel)
