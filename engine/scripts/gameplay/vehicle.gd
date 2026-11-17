class_name Vehicle
extends CharacterBody3D
## One vehicle. Driving is a kinematic simulation (sim_step) so the server and the client's
## prediction run the exact same code, and the client can rewind and replay inputs.
##
## Modes: SERVER (authoritative, collides with world + vehicles), PREDICTED (the local player's
## vehicle on a client, collides with the world only), PROXY (everyone else on a client,
## no collision, drawn from interpolated snapshots).

enum Mode { SERVER, PREDICTED, PROXY }

const MAX_ARMOR := 100.0
## Vertical motion follows the original's four wheel corners (games/twisted-metal/data/TUNING.md "Jumps"): each
## corner rides the ground or falls on its own; gravity grows with time in the air,
## GRAV0 + GRAV1 x ticks airborne (world units per tick per tick), falls are capped at
## MAX_FALL units per tick; the body's height, pitch and roll come from the four corners.
static var GRAV0 := 0.6
static var GRAV1 := 0.4
const MAX_FALL := 56.0
const STEP := 2.0               # m above the body origin: the corner ray starts here
const RISE := 0.6               # m: a corner steps up at most this far in one step; a higher surface is a wall
const SLOPE_MIN := 0.1           # rad (~5.7 deg); 2.3 deg had no effect, 9.8 deg the full one
static var MOVE_LIFT := 0.5      # m: the hull sweeps this high for walls and cars
const BODY_LEAD := 0.7          # ticks
const BOUNCE_PITCH := 20.0      # yaw units, nose up first
const BOUNCE_ROLL := 80.0
const BOUNCE_PITCH_T := 16.0    # ticks per swing
const BOUNCE_ROLL_T := 20.0
const BOUNCE_DAMP := 0.086      # per tick (about 0.65 left after each half swing)
const GHOST_LAYER := 4          # client: stand-ins for the other cars, for car-to-car prediction
const STICK := 6.0              # world units: a corner keeps contact when the ground drops less than this in a tick
const RADIUS := 0.6
const RAY_OFFSETS: Array[Vector3] = [Vector3(0.8, 0, 1.4), Vector3(-0.8, 0, 1.4), Vector3(0.8, 0, -1.4), Vector3(-0.8, 0, -1.4)]
const HALF_EXTENTS := Vector3(0.95, 0.55, 1.9)   # default hit box for lag-compensated hitscan

var mode := Mode.PROXY
var pid := 0                   # slot 0..7
var info: Dictionary = {}
var vid := ""                   # vehicle id: builtin_N or a game-data id (tuning.json key)
var half_extents := HALF_EXTENTS
var collision_kind := "capsule"
var profile: VehicleProfile
var veh_mass := 1.0
var max_hp := 100.0
var hp := 100.0
var armor := 0.0
var alive := true
var weapon := 1                 # selected weapon slot (Weapons.FIRE .. Weapons.SPECIAL)
var ammo: Array = Weapons.START_AMMO.duplicate()
var energy := Weapons.ENERGY_MAX
var energy_timer := 0.0
var heat := 0.0
var mg_locked := false
var protect := 0.0
var firing := false             # machine gun firing (for remote tracers)
var boosting := false           # turbo burning (cosmetic for remote vehicles)
var flame_time := 0.0           # server: flame special still burning (s)

# simulation state (SERVER and PREDICTED)
var yaw := 0.0
var yaw_rate := 0.0
var grounded := false
var ground_normal := Vector3.UP
var tilt := Vector2.ZERO        # pitch, roll (radians), from the wheel corners
# wheel corners FL, FR, RL, RR: height (m, world y), vertical speed (m/s), ticks in the air (< 0: on the ground)
var wh := PackedFloat32Array([0, 0, 0, 0])
var wv := PackedFloat32Array([0, 0, 0, 0])
var wn := PackedFloat32Array([-1, -1, -1, -1])
var _wheels_init := false
var _all_down_flag := true
var _wheels_landed_from_air := false
var bounce_p := 0.0             # landing rock, cosmetic (yaw units and units per tick)
var bounce_pv := 0.0
var bounce_r := 0.0
var bounce_rv := 0.0
var turbo_fuel := 6.0           # seconds left over all tanks (2 tanks x 3 s)
var frozen := 0.0               # seconds the vehicle cannot move (freeze missile)
var rams: Array = []            # [other Vehicle, normal, closing speed] from the last step
# the original's driving state (see _drive_tick): signed speed in raw units (1/32 world unit
# per game tick), steering angle, direction of travel (Godot yaw; differs from yaw in a slide),
# slide flag, reverse mode, and the pause after braking to a stop (ticks)
var spd := 0.0
var steer_s := 0.0
var travel := 0.0
var sliding := false
var reverse_mode := false
var stop_ticks := 0.0
var _grip_copy := false
var drive_phase := 0.0          # fraction of a 20 Hz game tick carried between our steps

# server-only
var mg_cd := 0.0
var sp_cd := 0.0
var respawn_timer := 0.0
var flip_cd := 0.0
var last_buttons := 0
var ram_cd := {}                # other slot -> seconds left
var odometer := 0.0             # metres driven while alive (diagnostics)

# visuals
var model: Node3D
var label: Label3D
var engine_player: AudioStreamPlayer3D
var _prev_xf := Transform3D.IDENTITY   # predicted: transform at the previous tick
var _cur_xf := Transform3D.IDENTITY
var vis_offset := Vector3.ZERO          # predicted: smoothed reconciliation correction
var vis_yaw_offset := 0.0
var _vis_tilt := Vector2.ZERO
var _buf: Array = []                    # proxy: [tick, pos, yaw, pitch, roll]
var _proxy_speed := 0.0
var _last_vis_pos := Vector3.ZERO
var visual_xf := Transform3D.IDENTITY

func setup(slot: int, player_info: Dictionary, m: Mode) -> void:
	pid = slot
	info = player_info
	mode = m
	name = "Vehicle_%d" % slot
	vid = str(info.get("vid", "builtin_1"))
	profile = Game.profile_for(vid)
	veh_mass = profile.mass
	max_hp = profile.max_health
	hp = max_hp
	turbo_fuel = profile.turbo_tanks * profile.turbo_tank_time
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.0   # height comes from the wheel corners (_update_wheels)
	floor_constant_speed = true
	floor_stop_on_slope = true
	floor_block_on_wall = true
	max_slides = 4
	safe_margin = 0.02
	var col: Dictionary = Game.vehicle_collision(vid) if mode != Mode.PROXY else {}
	if not col.is_empty():
		for sh in col.shapes:
			var cs := CollisionShape3D.new()
			cs.shape = sh[0]
			cs.transform = sh[1]
			add_child(cs)
		half_extents = col.half_extents
		collision_kind = col.kind
	match mode:
		Mode.SERVER:
			collision_layer = 2
			collision_mask = 3
		Mode.PREDICTED:
			collision_layer = 0
			collision_mask = 1 | GHOST_LAYER   # the world, and the other cars where the server will have them
		Mode.PROXY:
			collision_layer = 0
			collision_mask = 0
	if not Game.is_server:
		model = Game.build_vehicle_model(vid, info.get("color", Color.WHITE))
		model.top_level = true
		add_child(model)
		label = Label3D.new()
		label.text = str(info.get("name", "?"))
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = 0.012
		label.font_size = 40
		label.outline_size = 10
		var sz = model.get_meta("size_m", Vector3(2, 1.6, 4))
		label.position = Vector3(0, maxf((sz as Vector3).y + 1.0, 2.6), 0)
		label.modulate = (info.get("color", Color.WHITE) as Color).lightened(0.3)
		model.add_child(label)
		_setup_engine_audio()

func update_info(player_info: Dictionary) -> void:
	info = player_info
	if label != null:
		label.text = str(info.get("name", "?"))

func place(xf: Transform3D) -> void:
	var f := -xf.basis.z
	yaw = atan2(-f.x, -f.z)
	global_transform = Transform3D(Basis(Vector3.UP, yaw), xf.origin)
	velocity = Vector3.ZERO
	yaw_rate = 0.0
	spd = 0.0
	steer_s = 0.0
	travel = yaw
	sliding = false
	reverse_mode = false
	stop_ticks = 0.0
	_wheels_init = false
	tilt = Vector2.ZERO
	_prev_xf = global_transform
	_cur_xf = global_transform
	visual_xf = global_transform
	vis_offset = Vector3.ZERO
	vis_yaw_offset = 0.0
	_buf.clear()

func _setup_engine_audio() -> void:
	if DisplayServer.get_name() == "headless" or Game.audio_provider == null:
		return
	var st := Game.audio_provider.get_engine()
	if st == null:
		return
	engine_player = AudioStreamPlayer3D.new()
	engine_player.stream = st
	engine_player.unit_size = 8.0
	engine_player.max_distance = 90.0
	engine_player.volume_db = -8.0
	engine_player.autoplay = true   # starts when the vehicle enters the tree (setup() runs before that)
	model.add_child(engine_player)

## Shots left for a weapon slot (the special is energy / cost).
func ammo_count(w: int) -> int:
	if w == Weapons.SPECIAL:
		return energy / maxi(profile.special_cost, 1)
	return ammo[w] if w > 0 and w < ammo.size() else 0

func is_bot() -> bool:
	return bool(info.get("bot", false))

func speed() -> float:
	return _proxy_speed if mode == Mode.PROXY else Vector2(velocity.x, velocity.z).length()

func forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

# ---------------- simulation ----------------
func _corners() -> Array:
	var b := Basis(Vector3.UP, yaw)
	var t := profile.wheel_track
	return [b * Vector3(-t, 0, -profile.wheel_front), b * Vector3(t, 0, -profile.wheel_front),
		b * Vector3(-t, 0, profile.wheel_rear), b * Vector3(t, 0, profile.wheel_rear)]

## Landing rock (cosmetic, original yaw units): a damped spring on pitch and roll.
func _bounce(k: float) -> void:
	var wp := TAU / BOUNCE_PITCH_T
	var wr := TAU / BOUNCE_ROLL_T
	for _i in roundi(maxf(k * 3.0, 1.0)):   # integrate in thirds of a tick
		var h := k / maxf(roundi(k * 3.0), 1.0)
		bounce_pv += (-wp * wp * bounce_p - BOUNCE_DAMP * bounce_pv) * h
		bounce_p += bounce_pv * h
		bounce_rv += (-wr * wr * bounce_r - BOUNCE_DAMP * bounce_rv) * h
		bounce_r += bounce_rv * h

func _all_down() -> bool:
	return wn[0] < 0.0 and wn[1] < 0.0 and wn[2] < 0.0 and wn[3] < 0.0

## Ground under a corner: the first surface below STEP above the body (higher is a wall).
func _ground_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, STEP, 0), p - Vector3(0, 8.0, 0), 1)
	var r := space.intersect_ray(q)
	return (r.position as Vector3).y if not r.is_empty() else -INF

## Wheel corners and the body's height, pitch and roll (one step). Returns the body's target y.
func _update_wheels(dt: float) -> float:
	var space := get_world_3d().direct_space_state
	var k := dt * VehicleProfile.TICK_RATE
	var u := VehicleProfile.metres_per_unit
	var base_y := global_position.y - RADIUS
	var cs := _corners()
	var g := PackedFloat32Array([0, 0, 0, 0])
	for i in 4:
		g[i] = _ground_at(space, global_position + cs[i])
		if _wheels_init and wn[i] < 0.0 and g[i] > wh[i] + RISE:
			g[i] = wh[i]   # the side of a wall or a box, not ground to climb onto
	if not _wheels_init:
		for i in 4:
			wh[i] = g[i] if is_finite(g[i]) else base_y
			wv[i] = 0.0
			wn[i] = -1.0
		_wheels_init = true
	var stick := STICK * u
	for i in 4:
		if wn[i] < 0.0:
			if g[i] >= wh[i] - stick * k:
				# riding the ground: its rise or drop is the corner's vertical speed
				wv[i] = (g[i] - wh[i]) / dt if g[i] > wh[i] else 0.0
				wh[i] = g[i]
				continue
			wn[i] = 0.0          # the ground fell away: the corner flies on with its last vertical speed
		var a := (GRAV0 + GRAV1 * wn[i]) * u * VehicleProfile.TICK_RATE * VehicleProfile.TICK_RATE
		wv[i] = maxf(wv[i] - a * dt, -MAX_FALL * u * VehicleProfile.TICK_RATE)
		wh[i] += wv[i] * dt
		wn[i] += k
		if wh[i] <= g[i]:
			wh[i] = g[i]
			wv[i] = 0.0
			wn[i] = -1.0
	# rigid body through the corners: height, pitch (nose up +), roll (left side up +)
	var front := (wh[0] + wh[1]) * 0.5
	var rear := (wh[2] + wh[3]) * 0.5
	var left := (wh[0] + wh[2]) * 0.5
	var right := (wh[1] + wh[3]) * 0.5
	var fr := profile.wheel_front + profile.wheel_rear
	var pitch := atan2(front - rear, fr)
	var roll := atan2(left - right, 2.0 * profile.wheel_track)
	var avg := (front + rear) * 0.5
	var fw := profile.wheel_rear / fr      # the body origin sits this far along from rear to front
	var mid := rear + (front - rear) * fw
	# keep the corners on that plane (a corner lifted off the ground by the body flies)
	for i in 4:
		var plane := avg + (0.5 if i < 2 else -0.5) * (front - rear) + (0.5 if i % 2 == 0 else -0.5) * (left - right)
		if wn[i] < 0.0 and plane > g[i] + stick:
			wn[i] = 0.0
		wh[i] = maxf(plane, g[i]) if wn[i] < 0.0 else plane
	var was_down := _all_down_flag
	grounded = wn[0] < 0.0 or wn[1] < 0.0 or wn[2] < 0.0 or wn[3] < 0.0
	_all_down_flag = _all_down()
	if _all_down_flag and not was_down and _wheels_landed_from_air:
		# landing: the body rocks on its springs (measured: nose up ~20 units first, roll ~80 units,
		# periods ~16 and ~20 ticks, damped to ~0.65 per half swing)
		bounce_pv = -BOUNCE_PITCH * TAU / BOUNCE_PITCH_T
		bounce_rv = BOUNCE_ROLL * TAU / BOUNCE_ROLL_T * (1.0 if left - right >= 0.0 else -1.0)
	_wheels_landed_from_air = not _all_down_flag and (wn[0] > 2.0 or wn[1] > 2.0 or wn[2] > 2.0 or wn[3] > 2.0) or (_wheels_landed_from_air and not _all_down_flag)
	_bounce(k)
	var bu := TAU / VehicleProfile.YAW_UNITS
	tilt = Vector2(pitch - bounce_p * bu, -roll - bounce_r * bu)   # Godot: positive roll lowers the left side
	# the original reports the body about 0.7 tick ahead of its corners (fit over 12 ramp runs)
	var vmid := (wv[2] + (wv[0] - wv[2]) * fw + wv[3] + (wv[1] - wv[3]) * fw) * 0.5
	mid += vmid * BODY_LEAD / VehicleProfile.TICK_RATE
	ground_normal = Basis(Vector3.UP, yaw) * Vector3(sin(roll), 1.0, sin(pitch)).normalized()
	return mid + RADIUS

## One fixed tick of driving. Same code on the server and in client prediction/replay.
func sim_step(buttons: int, steer: float, dt: float) -> void:
	rams.clear()
	if not alive:
		return
	var target_y := _update_wheels(dt)
	var throttle := 0.0
	if buttons & Proto.B_ACCEL:
		throttle = 1.0
	elif buttons & Proto.B_BRAKE:
		throttle = -1.0
	if Proto.is_reset(buttons):
		throttle = 0.0
	var hb := (buttons & Proto.B_HANDBRAKE) != 0
	var turbo := (buttons & Proto.B_TURBO) != 0 and turbo_fuel > 0.0 and frozen <= 0.0
	boosting = turbo
	if turbo:
		turbo_fuel = maxf(turbo_fuel - dt, 0.0)
	var vh := Vector3(velocity.x, 0.0, velocity.z)
	var vy := velocity.y
	if frozen > 0.0:
		frozen = maxf(frozen - dt, 0.0)
		vh = Vector3.ZERO
		yaw_rate = 0.0
		spd = 0.0
		steer_s = 0.0
		travel = yaw
		sliding = false
	else:
		# the original keeps steering and its speed rules in the air (only a corner touching drives)
		# the original's driving rules run once per game tick (20 Hz) whatever our step is
		drive_phase += dt * VehicleProfile.TICK_RATE
		while drive_phase >= 1.0 - 1e-4:
			drive_phase -= 1.0
			_drive_tick(throttle if grounded else 0.0, steer, hb, turbo and grounded, 1.0 / VehicleProfile.TICK_RATE)
	yaw = wrapf(yaw + yaw_rate * dt, -PI, PI)
	if frozen <= 0.0:
		if _grip_copy:
			travel = yaw   # grip: the car moves where it points
		vh = _dir(travel) * VehicleProfile.raw_to_ms(spd)
	vy = (target_y - global_position.y) / dt
	velocity = vh   # horizontal only: the wheel corners set the height (below, after the move)
	global_transform.basis = Basis(Vector3.UP, yaw)
	var v_before := velocity
	# move_and_slide() moves by velocity x the ENGINE's delta: the physics delta inside a physics
	# frame, but the render-frame delta anywhere else. Client reconciliation replays run from the
	# packet callback, which often fires in _process, so without this a replayed tick moved the car
	# by speed x frame time instead of speed x dt (the zero-latency prediction errors).
	var ed := get_physics_process_delta_time() if Engine.is_in_physics_frame() else get_process_delta_time()
	var k := dt / ed if ed > 0.0 else 1.0
	if k != 1.0:
		velocity *= k
	global_position.y = target_y + MOVE_LIFT   # slopes and kerbs belong to the wheel corners, not the hull
	move_and_slide()
	if k != 1.0:
		velocity /= k
	global_position.y = target_y
	velocity.y = vy
	_after_move(v_before)
	if mode == Mode.SERVER:
		for i in get_slide_collision_count():
			var c := get_slide_collision(i)
			var o = c.get_collider()
			if o is Vehicle and o != self:
				var n := c.get_normal()
				var closing := (v_before - (o as Vehicle).velocity).dot(-n)
				if closing > 0.0:
					rams.append([o, n, closing])
	elif mode == Mode.PREDICTED:
		for i in get_slide_collision_count():
			var c := get_slide_collision(i)
			var o = c.get_collider()
			if o is Node and (o as Node).has_meta("ghost_slot"):
				var n := c.get_normal()
				var closing := (v_before - ((o as Node).get_meta("ghost_vel") as Vector3)).dot(-n)
				if closing > 0.0:
					rams.append([o, n, closing])
	if not velocity.is_finite() or not global_position.is_finite():
		push_warning("[vehicle] non-finite state on slot %d" % pid)
		velocity = Vector3.ZERO
	if Game.args.has("quantize-state"):   # experiment, off by default (see README)
		quantize_state()
	_prev_xf = _cur_xf
	_cur_xf = global_transform

static func _dir(y: float) -> Vector3:
	return Vector3(-sin(y), 0.0, -cos(y))

## Heading (Godot yaw) to the original's yaw units (4096 per turn, clockwise seen from above).
static func _hd(y: float) -> float:
	return -y / TAU * VehicleProfile.YAW_UNITS

## One step of the original's ground driving (disassembled from the game: steering, speed and
## grip/slide routines; games/twisted-metal/data/TUNING.md "Driving model"), in its own units, scaled from its
## 20 Hz tick to dt. Sets spd, steer_s, yaw_rate, travel, sliding.
func _drive_tick(throttle: float, steer: float, hb: bool, turbo: bool, dt: float) -> void:
	var D: Dictionary = profile.drive
	var k := dt * VehicleProfile.TICK_RATE      # game ticks in this step
	var v := spd
	# --- steering angle: ramps at a speed-dependent rate (twice as fast from centre or when
	# countersteering), springs back by halves when released, x hb_mult with the handbrake
	var sgn := signf(steer) if absf(steer) > 0.05 else 0.0
	var smax: float = D.steer_max * (D.hb_mult if hb else 1.0)
	if sgn != 0.0:
		var rate: float = D.steer_fast if absf(v) > 1440.0 else D.steer_slow - (D.steer_slow - D.steer_fast) * v / 1440.0
		if sgn * steer_s <= 0.0:
			rate *= 2.0
		if hb:
			rate *= D.hb_mult
		var lim := smax * minf(absf(steer), 1.0)
		var ns := steer_s + sgn * rate * k
		steer_s = clampf(ns, -lim, lim) if absf(ns) > lim and absf(ns) > absf(steer_s) else clampf(ns, -smax, smax)
	elif steer_s != 0.0:
		if absf(steer_s) < D.steer_slow:
			steer_s = 0.0
		else:
			steer_s *= pow(0.5 if _all_down() else 15.0 / 16.0, k)   # with a wheel off the ground it lets go slowly (the original: S - S/16)
	var yaw_tick := v / 32.0 * steer_s / float(D.steer_div)          # yaw units per tick
	yaw_rate = -yaw_tick / VehicleProfile.YAW_UNITS * TAU * VehicleProfile.TICK_RATE
	# --- speed
	var top: float = D.top
	var accel_a: float = D.accel_rest
	var fwd_in := throttle > 0.01 or turbo
	if turbo:
		top *= 1.5
		accel_a *= 4.0
	elif v > top:
		fwd_in = false            # above top speed without turbo: no drive, coast back down
	var fp := maxf(v, top)
	var accelerating := false
	if throttle < -0.01 and not turbo:
		if v > 0.0 and not reverse_mode:
			v -= (D.brake + _coast(v, fp)) * k   # brake plus rolling drag
			if v < D.accel_rest:
				v = 0.0
				stop_ticks = 8.0               # the original waits 22 frames before reversing
		elif stop_ticks > 0.0:
			stop_ticks -= k
			v = 0.0
		else:
			reverse_mode = true
			accelerating = true
			if v > -D.reverse_top and not sliding:
				v -= (accel_a - (accel_a - D.accel_top) * absf(v) / fp) * k
	else:
		reverse_mode = false
		stop_ticks = 0.0
		if fwd_in:
			accelerating = true
			if v < fp and not sliding:   # no drive while sliding
				var a: float = accel_a - (accel_a - D.accel_top) * absf(v) / fp if v > 0.0 else accel_a
				v += a * k
		elif v != 0.0:
			var c := _coast(v, fp) * k
			v = maxf(v - c, 0.0) if v > 0.0 else minf(v + c, 0.0)
	# --- slopes (measured on all 12 cars): with all four corners on a slope steeper than ~5 deg,
	# the speed loses accel_rest / 3 per tick going up and gains it going down
	if _all_down() and absf(tilt.x) > SLOPE_MIN and v != 0.0:
		v -= signf(tilt.x) * signf(v) * float(D.accel_rest) / 3.0 * k
	# --- grip / slide
	_grip_copy = false
	if not _all_down() and absf(v) > D.accel_rest:
		# a wheel off the ground (the original's airborne routine): the direction of travel holds,
		# and a car that comes down pointing elsewhere lands in a slide
		sliding = sliding or (absf(wrapf(_hd(yaw) - _hd(travel), -2048.0, 2048.0)) > 114.0 and v > D.slide_exit)
	elif sliding:
		var slip := wrapf(_hd(yaw) - _hd(travel), -2048.0, 2048.0)
		if true:   # (the original's handbrake-hold flag never set in any recorded run; see TUNING.md)
			if absf(v) < D.slide_exit:
				sliding = false
			elif not (absf(slip) >= 1366.0 and v > 352.0):
				var s1 := 0.0
				if sgn != 0.0:
					s1 = 15.0 if sgn * slip < 0.0 else 0.0     # countersteer recovers fast, steering in holds the slide
				else:
					s1 = 6.0
				var s0 := 0.0
				if s1 > 0.0 and v <= D.slide_speed:
					s0 = 6.0 if v > D.slide_speed * 0.5 else 15.0
				var rec := floorf((s0 + s1) / 2.0) * VehicleProfile.YAW_UNITS / 360.0 * (2.0 if accelerating else 1.0) * k
				if absf(slip) <= rec:
					sliding = false
				else:
					travel -= signf(slip) * rec / VehicleProfile.YAW_UNITS * TAU
		if sliding:
			# friction grows with the slip angle
			var fr: float = D.brake * (0.25 if absf(slip) < 682.0 else (0.5 if absf(slip) < 1024.0 else (1.0 if absf(slip) < 1365.0 else (3.0 if accelerating else 2.0))))
			if v > 0.0:
				v -= fr * k
				if v <= 0.0:
					v = 0.0
					sliding = false
			else:
				v += fr * k
				if v >= 0.0:
					v = 0.0
					sliding = false
		if not sliding:
			_grip_copy = true
	else:
		if v > D.slide_speed and absf(yaw_tick) > D.slide_yaw:
			sliding = true
		elif not hb:
			_grip_copy = true
		# hard steering at speed scrubs speed
		var m: float = D.steer_max * (D.hb_mult if hb else 2.0)
		if absf(v) > D.slide_speed and absf(steer_s) > m - (m - D.scrub) * absf(v) / fp:
			v = v - D.brake * k if v > 0.0 else v + D.brake * k
	spd = v

## Rolling drag per tick when not driving (raw units).
func _coast(v: float, fp: float) -> float:
	var D: Dictionary = profile.drive
	return maxf((D.brake - D.accel_top) * absf(v) / fp / 2.0, D.accel_top)

## After move_and_slide. A wall hit works like the original (measured, games/twisted-metal/data/TUNING.md "Walls"):
## speed x0.51 when the hit is within 47.5 degrees of head-on, x0.68 up to 67.5, x0.78 beyond;
## below 62 degrees the direction of travel is mirrored off the wall, beyond it the car is
## turned along the wall, and the car slides (slide friction then slows it by the slip angle).
func _after_move(v_before: Vector3) -> void:
	var vb := Vector3(v_before.x, 0.0, v_before.z)
	if vb.length() < 0.05 or not grounded:
		return
	var n := Vector3.ZERO
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c.get_collider() is Vehicle:
			continue
		var cn := c.get_normal()
		if absf(cn.y) < 0.5:
			n = Vector3(cn.x, 0.0, cn.z).normalized()
			break
	if n == Vector3.ZERO:
		return
	var d := vb.normalized()          # direction of motion
	var cos_a := -d.dot(n)
	if cos_a < 0.17:                  # grazing (beyond ~80 degrees) or moving away
		return
	var a := rad_to_deg(acos(clampf(cos_a, 0.0, 1.0)))
	var f := 0.508 if a < 47.5 else (0.68 if a < 67.5 else 0.78)
	var nd := d - 2.0 * d.dot(n) * n if a < 62.0 else (d - d.dot(n) * n).normalized()
	var mag := absf(spd) * f
	travel = atan2(-nd.x, -nd.z)
	spd = mag
	reverse_mode = false
	if mag > profile.drive.slide_exit:
		sliding = true
	velocity = Vector3(nd.x * VehicleProfile.raw_to_ms(mag), velocity.y, nd.z * VehicleProfile.raw_to_ms(mag))

## Rounds the simulated state to exactly what the owner's snapshot carries (mm position,
## 16-bit yaw, mrad/s yaw rate, velocity and turbo steps). The server does this after every
## tick and client prediction and replay do the same, so a client that resets to a received
## state starts from the very numbers the server continued from. Without it the reset state
## is off by up to half a millimetre, and a body sliding along floor-triangle seams or wall
## corners can end up a tick ahead or behind (seen as steady 0.3-0.6 m errors far from any
## other vehicle).
func quantize_state() -> void:
	var p := global_position
	var q := Proto.OWN_POS_Q
	p = Vector3(roundf(p.x * q) / q, roundf(p.y * q) / q, roundf(p.z * q) / q)
	yaw = Proto.dq_yaw(Proto.q_yaw(yaw))
	yaw_rate = clampi(roundi(yaw_rate * Proto.YAWRATE_Q), -32768, 32767) / Proto.YAWRATE_Q
	var vq := Proto.VEL_Q
	velocity = Vector3(clampi(roundi(velocity.x * vq), -32768, 32767), clampi(roundi(velocity.y * vq), -32768, 32767),
		clampi(roundi(velocity.z * vq), -32768, 32767)) / vq
	turbo_fuel = clampi(roundi(turbo_fuel * 30.0), 0, 255) / 30.0
	global_transform = Transform3D(Basis(Vector3.UP, yaw), p)

func _update_tilt() -> void:
	var b := Basis(Vector3.UP, yaw)
	if grounded:
		var ln := b.inverse() * ground_normal
		tilt = Vector2(atan2(ln.z, ln.y), atan2(-ln.x, ln.y))
	else:
		var fs := velocity.dot(-b.z)
		tilt = Vector2(clampf(atan2(velocity.y, maxf(absf(fs), 4.0)) * 0.6, -0.6, 0.6), tilt.y * 0.9)

func get_state() -> Dictionary:
	return {"pos": global_position, "yaw": yaw, "yaw_rate": yaw_rate, "vel": velocity, "grounded": grounded,
		"turbo": turbo_fuel, "frozen": frozen, "spd": spd, "steer_s": steer_s, "travel": travel, "sliding": sliding,
		"reverse_mode": reverse_mode, "stop_ticks": stop_ticks, "wh": wh.duplicate(), "wv": wv.duplicate(), "wn": wn.duplicate(), "phase": drive_phase}

func set_state(s: Dictionary) -> void:
	yaw = s.yaw
	yaw_rate = s.yaw_rate
	velocity = s.vel
	grounded = s.grounded
	turbo_fuel = s.turbo
	frozen = s.frozen
	set_drive_state(s)
	global_transform = Transform3D(Basis(Vector3.UP, yaw), s.pos)

## After a server correction (velocity only): direction of travel and signed speed from the
## corrected velocity, keeping the predicted sign (reversing or not).
func sync_travel_from_velocity() -> void:
	var vh := Vector3(velocity.x, 0.0, velocity.z)
	if vh.length() < 0.05:
		spd = 0.0
		return
	var d := vh.normalized()
	if spd < 0.0:
		d = -d
	travel = atan2(-d.x, -d.z)
	spd = signf(spd if spd != 0.0 else 1.0) * VehicleProfile.ms_to_raw(vh.length())

## Restores the original-model driving state. Keys missing from s (the network snapshot does not
## carry them) keep their current values; the speed then follows the velocity along the travel
## direction, so a server correction of the velocity still takes effect.
func set_drive_state(s: Dictionary) -> void:
	steer_s = s.get("steer_s", steer_s)
	travel = s.get("travel", travel)
	sliding = s.get("sliding", sliding)
	reverse_mode = s.get("reverse_mode", reverse_mode)
	stop_ticks = s.get("stop_ticks", stop_ticks)
	drive_phase = s.get("phase", drive_phase)
	if s.has("wh"):
		wh = PackedFloat32Array(s.wh)
		wv = PackedFloat32Array(s.wv)
		wn = PackedFloat32Array(s.wn)
		_wheels_init = true
	if s.has("spd"):
		spd = s.spd
	else:
		var vh := Vector3(velocity.x, 0.0, velocity.z)
		spd = VehicleProfile.ms_to_raw(vh.dot(_dir(travel)))

## Called after a correction so the render interpolation starts from the corrected state.
func reset_render_history() -> void:
	_prev_xf = global_transform
	_cur_xf = global_transform

## A blast: the car is sent sliding along dir at the given raw speed (the original sets the speed).
func knock(dir: Vector3, raw: float) -> void:
	if raw <= absf(spd) and sliding:
		return
	travel = atan2(-dir.x, -dir.z)
	spd = raw
	reverse_mode = false
	sliding = true
	velocity = Vector3(dir.x, 0.0, dir.z) * VehicleProfile.raw_to_ms(raw) + Vector3(0.0, velocity.y, 0.0)

func add_impulse(dv: Vector3) -> void:
	velocity += dv
	if dv.y > 0.0:   # a blast or a hit from below throws the wheel corners up
		for i in 4:
			wv[i] += dv.y
			wn[i] = maxf(wn[i], 0.0)
	var vh := Vector3(velocity.x, 0.0, velocity.z)
	if vh.length() > 0.01 and not sliding:
		spd = VehicleProfile.ms_to_raw(vh.dot(_dir(travel)))

## "Unstuck": lift the vehicle a little and stop it.
func request_upright() -> void:
	if flip_cd > 0.0 or not alive:
		return
	flip_cd = 2.0
	global_position += Vector3(0, 1.5, 0)
	for i in 4:
		wh[i] += 1.5
		wv[i] = 0.0
		wn[i] = 0.0
	velocity = Vector3.ZERO
	yaw_rate = 0.0
	spd = 0.0
	steer_s = 0.0
	travel = yaw
	sliding = false

## Returns true when the vehicle died from this hit.
func apply_damage(amount: float) -> bool:
	var absorbed := minf(armor, amount * 0.5)
	armor -= absorbed
	hp -= amount - absorbed
	return hp <= 0.0

func die() -> void:
	alive = false
	hp = 0.0
	velocity = Vector3.ZERO
	collision_layer = 0
	set_visual_alive(false)

func respawn(xf: Transform3D) -> void:
	place(xf)
	alive = true
	if mode == Mode.SERVER:
		collision_layer = 2
	hp = max_hp
	armor = 0.0
	ammo = Weapons.START_AMMO.duplicate()
	weapon = Weapons.FIRE
	energy = Weapons.ENERGY_MAX
	heat = 0.0
	mg_locked = false
	frozen = 0.0
	turbo_fuel = profile.turbo_tanks * profile.turbo_tank_time   # assumed: refilled on respawn
	protect = 2.5
	set_visual_alive(true)

func set_visual_alive(a: bool) -> void:
	if model != null:
		model.visible = a

# ---------------- client visuals ----------------
## Proxy: store one snapshot sample (tick in server ticks).
func push_sample(tick: float, pos: Vector3, y: float, pitch: float, roll: float) -> void:
	if not _buf.is_empty() and tick <= _buf[-1][0]:
		return
	_buf.append([tick, pos, y, pitch, roll])
	if _buf.size() == 1:
		visual_xf = Transform3D(Basis.from_euler(Vector3(pitch, y, roll)), pos)
		global_position = pos
	while _buf.size() > 40:
		_buf.pop_front()

## Proxy: interpolate at render tick rt (extrapolates up to 0.25 s if samples run out).
func render_at(rt: float) -> void:
	if _buf.is_empty():
		return
	while _buf.size() >= 3 and _buf[1][0] <= rt:
		_buf.pop_front()
	var a: Array = _buf[0]
	var pos: Vector3 = a[1]
	var y: float = a[2]
	var pitch: float = a[3]
	var roll: float = a[4]
	if _buf.size() >= 2:
		var c: Array = _buf[1]
		var span: float = maxf(c[0] - a[0], 0.001)
		var k: float = (rt - a[0]) / span
		if (a[1] as Vector3).distance_to(c[1]) > 12.0:   # teleport (respawn)
			k = 1.0 if k > 0.5 else 0.0
		k = clampf(k, 0.0, 1.0 + 7.5 / span)   # extrapolate at most 7.5 ticks (0.25 s)
		pos = (a[1] as Vector3).lerp(c[1], k)
		y = lerp_angle(a[2], c[2], k)
		var kc := clampf(k, 0.0, 1.0)
		pitch = lerpf(a[3], c[3], kc)
		roll = lerpf(a[4], c[4], kc)
	yaw = y
	global_transform = Transform3D(Basis(Vector3.UP, y), pos)
	visual_xf = Transform3D(Basis.from_euler(Vector3(pitch, y, roll)), pos)

func add_correction(dpos: Vector3, dyaw: float) -> void:
	vis_offset += dpos
	vis_yaw_offset = wrapf(vis_yaw_offset + dyaw, -PI, PI)
	if vis_offset.length() > 6.0:
		vis_offset = Vector3.ZERO
		vis_yaw_offset = 0.0

## Called by the match every frame, in order (proxies first, camera last).
func update_visual(delta: float) -> void:
	if model == null:
		return
	if mode == Mode.PREDICTED:
		var f := Engine.get_physics_interpolation_fraction()
		var p := _prev_xf.origin.lerp(_cur_xf.origin, f)
		var y0 := atan2(_prev_xf.basis.z.x, _prev_xf.basis.z.z)
		var y1 := atan2(_cur_xf.basis.z.x, _cur_xf.basis.z.z)
		var py := lerp_angle(y0, y1, f)
		var decay := exp(-delta / 0.1)
		vis_offset *= decay
		vis_yaw_offset *= decay
		_vis_tilt = _vis_tilt.lerp(tilt, 1.0 - exp(-delta * 10.0))
		visual_xf = Transform3D(Basis.from_euler(Vector3(_vis_tilt.x, py + vis_yaw_offset, _vis_tilt.y)), p + vis_offset)
	if delta > 0.0:
		var sp := Vector2(visual_xf.origin.x - _last_vis_pos.x, visual_xf.origin.z - _last_vis_pos.z).length() / delta
		_proxy_speed = lerpf(_proxy_speed, minf(sp, 60.0), 0.2)
		_last_vis_pos = visual_xf.origin
	model.global_transform = visual_xf.translated_local(Vector3(0, -RADIUS, 0))
	label.visible = alive and mode != Mode.PREDICTED
	if engine_player != null:
		engine_player.stream_paused = not alive
		engine_player.pitch_scale = lerpf(0.7, 2.0, clampf(speed() / maxf(profile.top_speed, 1.0), 0.0, 1.2))
