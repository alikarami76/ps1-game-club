class_name BotAI
extends RefCounted
## Bot driver. Picks a goal (an enemy, or a pickup when low on health or ammo), routes through
## ramps when the goal is on higher ground, steers around obstacles with three feeler rays,
## and backs out and detours when stuck. Produces the same input a player would send
## (buttons + steer), so it drives server bots and the --autodrive test clients alike.
##
## m must provide: vehicles (slot -> Vehicle), pickup_points, pickup_types, pickup_active, ramps (Array of
## [foot: Vector3, top: Vector3]), bot_state (Dictionary).

const VIEW_RANGE := 110.0        # about 3500 world units: the machine gun's measured reach

## Skill levels. "normal" is calibrated against the original's level-1 opponent (games/twisted-metal/data/TUNING.md
## "Opponent AI"): it parks about 300 world units (9 m) from a target that sits still and keeps
## shooting, and does about 3.4 health per second to a stationary player, half of it machine-gun
## hits; against a moving player it does about 1 per second. It does not shove: the original's
## opponent never pushed into a parked player.
##   mg_duty: share of time the gun is held while aimed; cone: aim tolerance (rad);
##   special_every: seconds between missile/special shots; think: re-plan interval (s);
##   hold_dist: stop short of the target at this range (m)
const SKILL := {
	"easy":   {"mg_duty": 0.5, "cone": 0.2, "special_every": 2.6, "think": 0.7, "hold_dist": 10.0},
	"normal": {"mg_duty": 1.0,  "cone": 0.3, "special_every": 1.5, "think": 0.45, "hold_dist": 9.5},
	"hard":   {"mg_duty": 1.0,  "cone": 0.4, "special_every": 0.9, "think": 0.3, "hold_dist": 9.0},
}

static func skill_of(m: Node) -> Dictionary:
	var k := str(m.settings.get("difficulty", Game.args.get("difficulty", "normal"))) if "settings" in m else "normal"
	return SKILL.get(k, SKILL.normal)

static func _st(m: Node, v: Vehicle) -> Dictionary:
	return m.bot_state.get_or_add(v.pid, {"stuck": 0.0, "reverse": 0.0, "detour": 0.0, "detour_dir": 1.0,
		"think": 0.0, "goal": Vector3.ZERO, "goal_kind": "", "target": -1, "special": 0.0, "via": -1,
		"last_pos": Vector3.ZERO})

## Returns [buttons, steer, weapon_to_select (0 = keep)].
static func think(m: Node, v: Vehicle, dt: float) -> Array:
	if not v.alive:
		return [0, 0.0, 0]
	var st := _st(m, v)
	var sk := skill_of(m)
	st.think -= dt
	if st.think <= 0.0:
		st.think = float(sk.think) + randf() * 0.2
		_pick_goal(m, v, st)
	var pos := v.global_position
	var target: Vehicle = m.vehicles.get(st.target) if st.goal_kind == "enemy" else null
	if target != null and (not is_instance_valid(target) or not target.alive):
		target = null
		st.think = 0.0
	var goal: Vector3 = target.global_position if target != null else st.goal
	# route through a ramp when the goal is clearly higher than we are
	var aim := goal
	if goal.y > pos.y + 1.6 and not m.ramps.is_empty():
		var best_i := -1
		var best_d := 1e9
		for i in m.ramps.size():
			var foot: Vector3 = m.ramps[i][0]
			var d := Vector2(foot.x - pos.x, foot.z - pos.z).length() + Vector2(goal.x - foot.x, goal.z - foot.z).length()
			if d < best_d:
				best_d = d
				best_i = i
		if best_i >= 0:
			var r: Array = m.ramps[best_i]
			var foot2: Vector3 = r[0]
			var on_ramp_line: bool = Vector2(foot2.x - pos.x, foot2.z - pos.z).length() < 5.0 or st.via == best_i
			if on_ramp_line:
				st.via = best_i
				aim = r[1]
			else:
				aim = foot2
	else:
		st.via = -1
	var fwd := v.forward()
	var to := aim - pos
	to.y = 0.0
	var ang := fwd.signed_angle_to(to.normalized(), Vector3.UP) if to.length() > 0.1 else 0.0
	var steer := clampf(-ang * 2.0, -1.0, 1.0)   # positive angle = goal to the left
	var dist := to.length()
	var throttle := 1.0
	if target != null and dist < float(sk.hold_dist):
		# park at range and keep the nose on the target; creep only to turn toward it
		throttle = 0.4 if absf(ang) > 0.5 and dist > 5.0 else (-1.0 if v.spd > 300.0 else 0.0)
	if st.goal_kind == "pickup" and dist < 6.0:
		throttle = 0.7
	# obstacle feelers (ignore walkable slopes such as ramps)
	var spd := v.speed()
	var look := 5.0 + spd * 0.45
	var space := v.get_world_3d().direct_space_state
	var c_f := _clear(space, pos, fwd, look)
	# a drop-off ahead (roof edges) counts as a wall
	var edge := _drop_ahead(space, pos, fwd, minf(look, 3.0 + spd * 0.35))
	if edge >= 0.0:
		c_f = minf(c_f, edge)
	var c_l := _clear(space, pos, fwd.rotated(Vector3.UP, 0.6), look * 0.8)
	var c_r := _clear(space, pos, fwd.rotated(Vector3.UP, -0.6), look * 0.8)
	if c_f < look * 0.999:
		var away := 1.0 if c_l > c_r else -1.0          # +1 = turn left
		var urgency := 1.0 - c_f / look
		steer = clampf(steer * (1.0 - urgency) - away * (0.6 + urgency), -1.0, 1.0)
		if c_f < 3.0 and spd > 8.0:
			throttle = 0.0
	elif c_l < look * 0.5:
		steer = clampf(steer + 0.5, -1.0, 1.0)
	elif c_r < look * 0.5:
		steer = clampf(steer - 0.5, -1.0, 1.0)
	# stuck handling: back out, then detour to the clearer side for a moment
	var buttons := 0
	if st.reverse > 0.0:
		st.reverse -= dt
		throttle = -1.0
		steer = st.detour_dir          # reversing: steering right swings the nose left
		if st.reverse <= 0.0:
			st.detour = 1.2
	elif st.detour > 0.0:
		st.detour -= dt
		steer = -st.detour_dir         # forward: turn toward the clearer side
	else:
		var moved: float = pos.distance_to(st.last_pos)
		if spd < 1.5 and v.grounded and moved < 0.08:
			st.stuck += dt
		else:
			st.stuck = maxf(st.stuck - dt, 0.0)
		if st.stuck > 0.8:
			st.stuck = 0.0
			m.bot_stuck += 1
			st.reverse = 0.9
			st.detour_dir = 1.0 if c_l > c_r else -1.0
			st.detour_dir = -st.detour_dir if randf() < 0.2 else st.detour_dir
	st.last_pos = pos
	if throttle > 0.3:
		buttons |= Proto.B_ACCEL
	elif throttle < -0.3:
		buttons |= Proto.B_BRAKE
	var reset := v.global_position.y < -5.0
	if st.reverse > 0.0 and st.get("resets", 0.0) > 6.0:
		reset = true   # stuck for a long time (wedged): use the unstuck key
		st.resets = 0.0
	st.resets = maxf(st.get("resets", 0.0) + (dt if st.reverse > 0.0 else -dt * 0.2), 0.0)
	if reset:
		buttons = (buttons & ~Proto.B_RESET) | Proto.B_RESET
	# shooting
	var want_w := 0
	st.mg_t = fmod(float(st.get("mg_t", randf() * 2.0)) + dt, 2.0)
	if target != null and dist < VIEW_RANGE and absf(ang) < float(sk.cone) and _los(space, pos, target.global_position):
		if st.mg_t < 2.0 * float(sk.mg_duty):
			buttons |= Proto.B_FIRE_MG
		st.special -= dt
		if st.special <= 0.0:
			st.special = float(sk.special_every) * (0.7 + randf() * 0.6)
			for w in [Weapons.POWER, Weapons.HOMING, Weapons.SPECIAL, Weapons.FREEZE, Weapons.FIRE]:
				if v.ammo_count(w) > 0 and (w != Weapons.SPECIAL or v.profile.special_kind in ["bolt", "heavy", "salvo"] or dist < 12.0):
					want_w = w
					buttons |= Proto.B_SPECIAL
					break
		if target != null and dist > 25.0 and absf(ang) < 0.15 and v.turbo_fuel > 1.0 and v.grounded:
			buttons |= Proto.B_TURBO
	return [buttons, steer, want_w]

static func _clear(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector3, length: float) -> float:
	var from := pos + Vector3(0, 0.25, 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length, 1)
	var r := space.intersect_ray(q)
	if r.is_empty():
		return length
	if (r.normal as Vector3).y > 0.55:   # ramp or floor, drivable
		return length
	return from.distance_to(r.position)

## Distance to the first point ahead (sampled every 2 m) with no ground within 6 m below,
## or -1 when the ground continues.
static func _drop_ahead(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector3, length: float) -> float:
	var d := 2.0
	while d <= length:
		var p := pos + dir * d + Vector3(0, 1.5, 0)
		var q := PhysicsRayQueryParameters3D.create(p, p - Vector3(0, 7.5, 0), 1)
		if space.intersect_ray(q).is_empty():
			return maxf(d - 2.0, 0.5)
		d += 2.0
	return -1.0

static func _los(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a + Vector3(0, 0.5, 0), b + Vector3(0, 0.5, 0), 1)
	return space.intersect_ray(q).is_empty()

static func _pick_goal(m: Node, v: Vehicle, st: Dictionary) -> void:
	var pos := v.global_position
	var need_health := v.hp < 45.0
	var need_ammo: bool = v.ammo[Weapons.FIRE] + v.ammo[Weapons.HOMING] + v.ammo[Weapons.POWER] + v.ammo[Weapons.FREEZE] == 0
	var best_pk := -1
	var best_pd := 1e9
	for i in m.pickup_points.size():
		if not m.pickup_active[i]:
			continue
		var kind: String = m.pickup_types[i] if i < m.pickup_types.size() else Pickup.TYPES[i % Pickup.TYPES.size()]
		var useful := (need_health and kind == "health") or (need_ammo and kind != "health")
		if not useful:
			continue
		var d: float = pos.distance_to(m.pickup_points[i])
		if d < best_pd:
			best_pd = d
			best_pk = i
	var enemy: Vehicle = null
	var best_e := 1e9
	for o in m.vehicles.values():
		if o == v or not o.alive:
			continue
		var d2: float = o.global_position.distance_to(pos)
		if d2 < best_e:
			best_e = d2
			enemy = o
	if best_pk >= 0 and (need_health or best_pd < 40.0 or enemy == null or best_e > 35.0):
		st.goal_kind = "pickup"
		st.goal = m.pickup_points[best_pk]
		st.target = -1
	elif enemy != null:
		st.goal_kind = "enemy"
		st.target = enemy.pid
	else:
		st.goal_kind = "wander"
		st.target = -1
		if m.pickup_points.size() > 0 and (st.goal == Vector3.ZERO or pos.distance_to(st.goal) < 6.0):
			st.goal = m.pickup_points[randi() % m.pickup_points.size()]
