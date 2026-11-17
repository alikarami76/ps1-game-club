class_name ChaseCamera
extends Camera3D
## Third-person chase camera, measured from the original in the headless emulator (camera
## matrix at 0x80191750, translation 0x80191764, GTE H = 228; see scripts/render/ps1_settings.gd):
##  - it is computed once per game tick (20 per second) from the vehicle's position and heading
##    of the tick before, so at speed it trails by one tick of travel (7.5 m at rest, about
##    9 m at top speed);
##  - it stays 240 units (7.5 m) away on the ground plane, like a trailer on a string: each
##    tick the direction from the camera to the vehicle turns about 60% of the way towards the
##    vehicle's heading (40% of the angle is left), so the vehicle swings out to the side in
##    a turn and drifts back after;
##  - its height is the vehicle's origin + 111.5 units (3.48 m) with no smoothing (airborne
##    included), pitch is a fixed 16 degrees down, roll 0;
##  - it looks along the vehicle's heading of the tick before (not at the vehicle), so a
##    reversing car keeps the camera behind it;
##  - vertical field of view 55.5 degrees on a 4:3 picture, drawn 1.11 times wider than tall
##    (the shader stretch, Ps1Settings.X_STRETCH).
## Extra (not in the original): the camera is pulled in along the line from the vehicle when
## arena walls are in the way.

const Ps1SettingsScript := preload("res://scripts/render/ps1_settings.gd")

const TICK := 0.05
const BACK := 240.0 / 32.0
const HEIGHT := 111.5 / 32.0
const PITCH_DEG := -16.0
const CHASE_LEFT := 0.35            # angle error left after one tick (fit: 0.35-0.4)
const DEFAULT_ORIGIN_UP := -0.1     # the game's vehicle origin above visual_xf (16 units - 0.6 m)
const BODY_RADIUS := 0.6            # visual_xf is this far above the model's ground point

## Height of the game's vehicle origin above the followed transform; NAN = find it from the
## match's own vehicle model (meta "game_origin"), else DEFAULT_ORIGIN_UP.
var origin_up := NAN
var collide := true
var dir := Vector3.FORWARD          # the look direction on the ground (read by others)
var focus = null                    # the followed vehicle point (Vector3; the sky centres on it)

var _hist: Array = []               # [time, base point, heading]
var _time := 0.0
var _ang := 0.0
var _first := true
var _bars: CanvasLayer
var _bar_l: ColorRect
var _bar_r: ColorRect

func _ready() -> void:
	Ps1SettingsScript.apply()
	keep_aspect = Camera3D.KEEP_HEIGHT
	fov = Ps1SettingsScript.VFOV
	_bars = CanvasLayer.new()
	_bars.layer = -1
	_bar_l = ColorRect.new()
	_bar_r = ColorRect.new()
	for b in [_bar_l, _bar_r]:
		b.color = Color.BLACK
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bars.add_child(b)
	add_child(_bars)
	get_viewport().size_changed.connect(_layout_bars)
	_layout_bars()

## 4:3 picture with black side bars unless the player chose widescreen.
func _layout_bars() -> void:
	var vp := get_viewport()
	if vp == null or _bars == null:
		return
	var sz := vp.get_visible_rect().size
	var w43 := sz.y * 4.0 / 3.0
	var on := not Ps1SettingsScript.get_value("widescreen") and sz.x > w43 + 1.0
	_bars.visible = on
	if on:
		var side := (sz.x - w43) * 0.5
		_bar_l.position = Vector2.ZERO
		_bar_l.size = Vector2(side, sz.y)
		_bar_r.position = Vector2(sz.x - side, 0)
		_bar_r.size = Vector2(side + 1.0, sz.y)

static func heading_of(xf: Transform3D) -> float:
	var f := -xf.basis.z
	return atan2(f.x, -f.z)

func _origin_up() -> float:
	if not is_nan(origin_up):
		return origin_up
	var m = get_parent()
	if m != null and "vehicles" in m and "my_slot" in m:
		var v = m.vehicles.get(m.my_slot)
		if v != null and "model" in v and v.model != null and v.model.has_meta("game_origin"):
			return float(v.model.get_meta("game_origin").y) - BODY_RADIUS
	return DEFAULT_ORIGIN_UP

## target: the vehicle's visual transform (origin BODY_RADIUS above its ground point).
func follow(target: Transform3D, dt: float) -> void:
	_time += maxf(dt, 0.0)
	var base := target.origin + Vector3.UP * _origin_up()
	var head := heading_of(target)
	if _first:
		_hist.clear()
	_hist.append([_time, base, head])
	while _hist.size() > 2 and _hist[1][0] <= _time - TICK:
		_hist.pop_front()
	# the vehicle one tick ago
	var t0 := _time - TICK
	var car: Vector3 = _hist[0][1]
	var yaw: float = _hist[0][2]
	if _hist.size() >= 2 and _hist[0][0] < t0:
		var a: Array = _hist[0]
		var b: Array = _hist[1]
		var f := clampf((t0 - a[0]) / maxf(b[0] - a[0], 1e-6), 0.0, 1.0)
		car = (a[1] as Vector3).lerp(b[1], f)
		yaw = lerp_angle(a[2], b[2], f)
	if _first:
		_ang = yaw
		_first = false
	else:
		var u := car - global_position
		if Vector2(u.x, u.z).length() > 0.01:
			_ang = atan2(u.x, -u.z)
		var keep := pow(CHASE_LEFT, clampf(dt, 0.0, 0.25) / TICK)
		_ang += (1.0 - keep) * wrapf(yaw - _ang, -PI, PI)
	var pos := car - Vector3(sin(_ang), 0.0, -cos(_ang)) * BACK
	pos.y = car.y + HEIGHT
	if collide and is_inside_tree():
		pos = _clear_view(car + Vector3.UP * 1.2, pos)
	focus = car
	global_position = pos
	global_basis = Basis(Vector3.UP, -yaw) * Basis(Vector3.RIGHT, deg_to_rad(PITCH_DEG))
	dir = Vector3(sin(yaw), 0.0, -cos(yaw))

## Pulls the camera towards the vehicle when arena geometry (collision layer 1) is in the way.
func _clear_view(from: Vector3, to: Vector3) -> Vector3:
	var w := get_world_3d()
	if w == null:
		return to
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	q.hit_back_faces = true
	var hit := w.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return to
	var p: Vector3 = hit.position
	p += (from - to).normalized() * 0.3
	p.y = maxf(p.y, from.y)
	return p
