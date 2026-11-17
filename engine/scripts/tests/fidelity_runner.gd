extends Node3D
## Fidelity harness, engine side. Replays per-tick input scripts (20 game ticks per second, the
## original's logic rate) through Vehicle.sim_step on a disc arena and logs the state in the
## original's units, so the result can be compared with the same script run in the emulator.
## Run (headless): Godot --headless --path game res://scenes/tests/fidelity_runner.tscn --
##   --data=../gamedata --scenarios=IN.json --out=OUT.json [--dt=0.0333]
## IN.json: [{name, arena ("XARENA/part1"), vehicle ("ICE"), start {x, y, z, hd}, script [[ticks, "UL"], ...]}]
## Keys: U accel, D brake/reverse, L/R steer, H handbrake, T turbo.
## OUT.json: {name: [[t_s, x, y, z, hd, speed_raw], ...]} sampled after every physics step.

var u := 1.0 / 32.0
var arenas := {}      # id -> [root, level offset]

func _ready() -> void:
	_run.call_deferred()

func _arena(id: String) -> Array:
	if arenas.has(id):
		return arenas[id]
	for k in arenas:
		arenas[k][0].queue_free()
	arenas.clear()
	var prov = Game.make_arena_provider(id)
	prov.collision_only = true
	var root: Node3D = prov.build_arena()
	add_child(root)
	var off: Vector3 = (root.get_node("Level") as Node3D).position
	arenas[id] = [root, off]
	return arenas[id]

func to_godot(off: Vector3, x: float, y: float, z: float) -> Vector3:
	return off + Vector3(x, z, -y) * u

func _run() -> void:
	var path := str(Game.args.get("scenarios", ""))
	var dt := float(Game.args.get("dt", str(1.0 / 30.0)))
	var scen = JSON.parse_string(FileAccess.get_file_as_string(path))
	if Game.args.has("mpu"):   # A/B the unit scale (e.g. 0.015625 = the old 1/64)
		VehicleProfile.metres_per_unit = float(Game.args.mpu)
		Game.profiles.load_disc_tuning(Game.TUNING_RES)
	if Game.args.has("grav"):
		var gp := str(Game.args.grav).split(",")
		Vehicle.GRAV0 = float(gp[0])
		Vehicle.GRAV1 = float(gp[1])
	if Game.args.has("lift"):
		Vehicle.MOVE_LIFT = float(Game.args.lift)
	var out := {}
	for s in scen:
		var a := _arena(str(s.arena))
		var off: Vector3 = a[1]
		await get_tree().physics_frame
		await get_tree().physics_frame
		var vid := str(s.vehicle)
		var v := Vehicle.new()
		v.setup(0, {"name": "t", "color": Color.WHITE, "vid": vid, "bot": false}, Vehicle.Mode.SERVER)
		add_child(v)
		var st: Dictionary = s.start
		var yaw := -float(st.hd) / 4096.0 * TAU
		var p0 := to_godot(off, float(st.x), float(st.y), float(st.get("z", 0)))
		if not st.has("z"):   # stand on the highest ground there (ROOF is 7760 units up)
			var top := to_godot(off, float(st.x), float(st.y), 20000.0)
			var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(top, top - Vector3(0, 1000, 0), 1))
			if not hit.is_empty():
				p0.y = (hit.position as Vector3).y
		v.place(Transform3D(Basis(Vector3.UP, yaw), p0 + Vector3(0, Vehicle.RADIUS + 0.05, 0)))
		await get_tree().physics_frame
		for i in 6:   # settle onto the ground without moving
			v.sim_step(0, 0.0, dt)
			v.velocity.x = 0.0
			v.velocity.z = 0.0
		v.global_position.x = p0.x
		v.global_position.z = p0.z
		v.spd = float(st.get("sp", 0.0))
		v.steer_s = float(st.get("S", 0.0))
		v.travel = v.yaw
		v.velocity = Vehicle._dir(v.yaw) * VehicleProfile.raw_to_ms(v.spd)
		# expand the script into per-tick keys
		var keys: Array = []
		for step in s.script:
			for i in int(step[0]):
				keys.append(str(step[1]))
		var rows: Array = []
		var t := 0.0
		var total := keys.size() / 20.0
		var prev_yaw := v.yaw
		var hd_unwrapped := float(st.hd)
		rows.append(_row(v, off, 0.0, hd_unwrapped))
		while t < total - 1e-6:
			var k: String = keys[clampi(int(ceil((t + dt) * 20.0 - 1e-3)) - 1, 0, keys.size() - 1)]   # the game tick that completes in this step
			var b := 0
			var steer := 0.0
			if k.contains("U"): b |= Proto.B_ACCEL
			if k.contains("D"): b |= Proto.B_BRAKE
			if k.contains("H"): b |= Proto.B_HANDBRAKE
			if k.contains("T"): b |= Proto.B_TURBO
			if k.contains("L"): steer -= 1.0
			if k.contains("R"): steer += 1.0
			v.sim_step(b, steer, dt)
			t += dt
			hd_unwrapped += -angle_difference(prev_yaw, v.yaw) / TAU * 4096.0
			prev_yaw = v.yaw
			rows.append(_row(v, off, t, hd_unwrapped))
			if Game.args.has("dbgwheels"):
				print("[w] t=%.3f y=%.1f wh=%s wn=%s vy=%.2f gnd=%s" % [t, (v.global_position.y - off.y) / u, str(Array(v.wh).map(func(x): return snappedf((x - off.y) / u, 0.1))), str(v.wn), v.velocity.y / u / 20.0, v.grounded])
		out[str(s.name)] = rows
		v.queue_free()
	var f := FileAccess.open(str(Game.args.get("out", "user://fidelity_out.json")), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("[fidelity] %d scenarios -> %s" % [out.size(), Game.args.get("out", "")])
	get_tree().quit(0)

func _row(v: Vehicle, off: Vector3, t: float, hd: float) -> Array:
	var g := (v.global_position - Vector3(0, Vehicle.RADIUS, 0) - off) / u
	var fs := VehicleProfile.raw_to_ms(v.spd)
	return [snappedf(t, 0.0001), snappedf(g.x, 0.01), snappedf(-g.z, 0.01), snappedf(g.y, 0.01), snappedf(hd, 0.01), snappedf(fs / u / 20.0 * 32.0, 0.1), 0, snappedf(-v.tilt.x / TAU * 4096.0, 0.1), snappedf(v.tilt.y / TAU * 4096.0, 0.1)]
