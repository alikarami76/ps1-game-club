extends Node3D
## Headless driving test. Drives every vehicle profile with Vehicle.sim_step (the same code the
## server and client prediction run) on flat ground and compares with the profile's targets.
## Run: Godot --headless --path game res://scenes/tests/vehicle_tuning.tscn -- [--disc]
## --disc also tests every measured profile from tuning.json (if present).
## Exits with code 0 when every measurement is within TOL of its target, else 1.

const TOL := 0.10
const DT := 1.0 / 30.0

var profiles: Array[VehicleProfile] = []
var results: Array = []
var any_fail := false

func _ready() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(6000, 2, 6000)
	cs.shape = bs
	cs.position.y = -1.0
	ground.add_child(cs)
	add_child(ground)
	for i in 8:
		profiles.append(Game.profiles.get_profile(i))
	if Game.args.has("disc"):
		print("[test] %d measured profiles" % Game.profiles.disc.size())
		for k in Game.profiles.disc:
			profiles.append(Game.profiles.disc[k])
	print("[test] metres per world unit = %.6f" % VehicleProfile.metres_per_unit)
	_run.call_deferred()

func _vehicle(p: VehicleProfile) -> Vehicle:
	var v := Vehicle.new()
	v.setup(0, {"name": "t", "color": Color.WHITE, "vid": p.id, "bot": false}, Vehicle.Mode.SERVER)
	v.profile = p
	add_child(v)
	return v

func _reset(v: Vehicle, speed: float) -> void:
	v.place(Transform3D(Basis.IDENTITY, Vector3(0, 0.62, 0)))
	v.velocity = Vector3(0, 0, -speed)
	v.spd = VehicleProfile.ms_to_raw(speed)
	v.travel = v.yaw
	v.turbo_fuel = 6.0

func _fs(v: Vehicle) -> float:
	return v.velocity.dot(v.forward())

func _run() -> void:
	await get_tree().physics_frame
	for p in profiles:
		var v := _vehicle(p)
		await get_tree().physics_frame
		# settle onto the ground
		_reset(v, 0.0)
		for i in 10:
			v.sim_step(0, 0.0, DT)
		# top speed and time to 90 %
		var t := 0.0
		var t90 := -1.0
		var peak := 0.0
		while t < 8.0:
			v.sim_step(Proto.B_ACCEL, 0.0, DT)
			t += DT
			peak = maxf(peak, _fs(v))
			if t90 < 0.0 and _fs(v) >= 0.9 * p.top_speed:
				t90 = t
		_row(p, "top speed m/s", peak, p.top_speed)
		_row(p, "time to 90% s", t90, p.time_to_90())
		# braking distance from top speed
		_reset(v, p.top_speed)
		v.sim_step(0, 0.0, DT)
		var x0 := v.global_position
		var tb := 0.0
		while _fs(v) > 0.05 and tb < 6.0:
			v.sim_step(Proto.B_BRAKE, 0.0, DT)
			tb += DT
		_row(p, "brake distance m", x0.distance_to(v.global_position), _brake_dist(p))
		# steady turn: radius at half speed (yaw rate ramps in first)
		_reset(v, p.top_speed * 0.5)
		var tt := 0.0
		var yaw_sum := 0.0
		var dist := 0.0
		while tt < 4.0:
			var b := Proto.B_ACCEL if _fs(v) < p.top_speed * 0.5 else 0
			var y0 := v.yaw
			var pos0 := v.global_position
			v.sim_step(b, 1.0, DT)
			tt += DT
			if tt > 2.5:
				yaw_sum += absf(angle_difference(y0, v.yaw))
				dist += Vector2(v.global_position.x - pos0.x, v.global_position.z - pos0.z).length()
		_row(p, "turn radius m", dist / maxf(yaw_sum, 0.0001), p.turn_radius)
		# turbo top speed
		_reset(v, p.top_speed)
		var peak2 := 0.0
		for i in 60:
			v.sim_step(Proto.B_ACCEL | Proto.B_TURBO, 0.0, DT)
			peak2 = maxf(peak2, _fs(v))
		_row(p, "turbo top speed m/s", peak2, p.top_speed * p.turbo_speed_mult)
		v.queue_free()
		await get_tree().physics_frame
	_report()

## Stopping distance from top speed under the original's braking (brake + rolling drag per
## tick, and the stop snap below accel_rest).
func _brake_dist(p: VehicleProfile) -> float:
	var vr: float = p.drive.top
	var d := 0.0
	while vr >= float(p.drive.accel_rest):
		vr -= float(p.drive.brake) + p.coast_raw(vr)
		d += maxf(vr, 0.0) / 32.0
	return VehicleProfile.u_to_m(d)

func _row(p: VehicleProfile, metric: String, measured: float, target: float) -> void:
	results.append([p.display_name, metric, measured, target])

func _report() -> void:
	print("")
	print("%-10s %-22s %10s %10s %8s" % ["vehicle", "metric", "measured", "target", "error"])
	var worst := 0.0
	for r in results:
		var err: float = (r[2] - r[3]) / maxf(absf(r[3]), 0.0001)
		worst = maxf(worst, absf(err))
		var bad := absf(err) > TOL
		any_fail = any_fail or bad
		print("%-10s %-22s %10.2f %10.2f %7.1f%%%s" % [r[0], r[1], r[2], r[3], err * 100.0, "  <--" if bad else ""])
	print("worst error %.1f%%  -> %s" % [worst * 100.0, "FAIL" if any_fail else "PASS"])
	get_tree().quit(1 if any_fail else 0)
