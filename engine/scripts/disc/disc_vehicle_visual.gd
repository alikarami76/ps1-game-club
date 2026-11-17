extends Node3D
## Root of a disc vehicle model with damage states and wheel frames (DiscVehicleModels).
## Children: "Body" (meshes outside the body switch, always drawn) and "D0", "D1", "D2" (the
## body switch's states: intact, damaged, wrecked), each holding "Hull" and "W<frame>" (the wheel
## switches of that state, merged per frame). Client-side only; driven by
## scripts/gameplay/vehicle_damage.gd through set_damage_level() and set_wheel_speed().

const WHEEL_FRAMES_PER_M := 1.5   # wheel frame steps per metre driven (not measured)
const WHEEL_MAX_RATE := 20.0      # steps per second at most: the game draws 20 frames a second

var level := 0
var _states: Array = []   # per damage level: Node3D
var _wheels: Array = []   # per damage level: Array of Node3D, one per wheel frame
var _frame := 0
var _acc := 0.0

func setup_parts(states: Array, wheels: Array) -> void:
	_states = states
	_wheels = wheels
	for i in _states.size():
		_states[i].visible = i == 0
	_show_frame(0)

func has_damage_states() -> bool:
	return _states.size() >= 2

## 0 intact, 1 damaged, 2 wrecked (clamped to the states the model has).
func set_damage_level(l: int) -> void:
	l = clampi(l, 0, maxi(_states.size() - 1, 0))
	if l == level or _states.is_empty():
		return
	_states[level].visible = false
	_states[l].visible = true
	level = l

## Cycles the wheel frames with the distance driven (speed in m/s, any sign).
func set_wheel_speed(speed: float, delta: float) -> void:
	var s := absf(speed)
	if s < 0.3 or _wheels.is_empty():
		return
	_acc += minf(s * WHEEL_FRAMES_PER_M, WHEEL_MAX_RATE) * delta
	if _acc >= 1.0:
		var steps := int(_acc)
		_acc -= steps
		_show_frame(_frame + steps)

func _show_frame(f: int) -> void:
	for frames in _wheels:
		if frames.is_empty():
			continue
		var n: int = frames.size()
		for i in n:
			frames[i].visible = i == posmod(f, n)
	_frame = f

# --- feedback tints and turbo flames (client side; reads the parent Vehicle's state) ---
const DiscFxScript := preload("res://scripts/render/disc_fx.gd")
const FREEZE_TINT := Color(0.55, 1.05, 1.35, 0.9)   # the original shows a frozen car blue (emulator frame)
const HIT_TINT := Color(1.6, 0.45, 0.35, 0.6)      # short red flash when it takes damage (requested; not seen in the emulator)
const HIT_TIME := 0.12

var _last_hp := -1.0
var _hit := 0.0
var _tint := Color(0, 0, 0, 0)
var _flame_t := 0.0

var _menu_done := false

func _process(delta: float) -> void:
	var v := get_parent()
	if v == null or not ("hp" in v):
		# not driven by a Vehicle: a menu turntable. Neutral light like the original's
		# select screen instead of the in-game lights (which tint some faces green).
		if not _menu_done and v != null:
			_menu_done = true
			_set_param(self, "menu_light", 1.0)
		return
	var hp: float = v.hp
	if _last_hp >= 0.0 and hp < _last_hp - 0.01:
		_hit = HIT_TIME
	_last_hp = hp
	_hit = maxf(_hit - delta, 0.0)
	var want := Color(0, 0, 0, 0)
	if "frozen" in v and float(v.frozen) > 0.0:
		want = FREEZE_TINT
	elif _hit > 0.0:
		want = HIT_TINT
	if want != _tint:
		_tint = want
		_set_tint(self, want)
	if "boosting" in v and v.boosting and visible and DiscFxScript.has_frames("fire"):
		_flame_t -= delta
		if _flame_t <= 0.0:
			_flame_t = 0.08
			var size: Vector3 = get_meta("size_m", Vector3(2, 1.5, 4.5))
			var xf := global_transform
			var rear := xf * Vector3(randf_range(-0.25, 0.25) * size.x, size.y * 0.35, size.z * 0.5 + 0.2)
			DiscFxScript.spawn(get_tree().current_scene if get_tree() else null, "fire", rear, 0.9, 0.25, 0.3)

func _set_tint(n: Node, c: Color) -> void:
	_set_param(n, "tint", c)

## Sets a shader value on every surface of this model (own copies of the shared materials,
## made on first use).
func _set_param(n: Node, key: String, c) -> void:
	for ch in n.get_children():
		var mi := ch as MeshInstance3D
		if mi != null and mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				var m := mi.get_surface_override_material(i) as ShaderMaterial
				if m == null:
					var src := mi.mesh.surface_get_material(i) as ShaderMaterial
					if src == null:
						continue
					m = src.duplicate() as ShaderMaterial
					mi.set_surface_override_material(i, m)
				m.set_shader_parameter(key, c)
		_set_param(ch, key, c)
