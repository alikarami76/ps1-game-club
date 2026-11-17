extends RefCounted
## Destructible arena props, server-authoritative (README DESTRUCTIBLE; arena side in
## scripts/disc/disc_props.gd, found through the arena's "props" meta; arenas without it have
## no targets and every call here is a no-op).
##
## Server: keeps hit points per target; explosions (missiles, specials), machine-gun rays and
## rams damage the targets. At 0 hit points the target is destroyed: the server swaps its
## collision, sends an explosion and an EV_PROP event (reliable), and pickups gated on it become
## available. Clients apply EV_PROP as it arrives and the destroyed bitset that every full
## snapshot carries (late joiners, lost state). Props do not come back within a match.

const RAM_MIN_SPEED := 6.0      # m/s closing speed before a prop takes ram damage
const RAM_DAMAGE_PER_MS := 0.6  # damage per m/s above RAM_MIN_SPEED (not measured)
const RAM_COOLDOWN := 0.5

var m: Node                    # the match
var props: Node = null         # DiscProps or null
var hp := PackedFloat32Array()
var _ram_cd := {}              # "pid:target" -> seconds left
var _last_vel := {}            # pid -> velocity before this tick's move
var stats := {"destroyed": 0, "explosion": 0, "mg": 0, "ram": 0, "test": 0}
## Test mode (environment TM_PROPS_TEST=<seconds>, read by the server): every that many seconds
## one random intact target is destroyed through the normal path, so every target, its
## pickups and the replication get exercised in bot matches.
var _test_every := 0.0
var _test_timer := 0.0

func _init(match_node: Node, arena: Node) -> void:
	m = match_node
	if arena != null and arena.has_meta("props"):
		props = arena.get_meta("props")
	for i in count():
		hp.append(float(props.target_hp(i)))
	_test_every = float(OS.get_environment("TM_PROPS_TEST")) if OS.has_environment("TM_PROPS_TEST") else 0.0

func count() -> int:
	return props.target_count() if props != null else 0

func is_destroyed(i: int) -> bool:
	return props != null and i >= 0 and i < count() and props.is_destroyed(i)

func destroyed_count() -> int:
	var n := 0
	for i in count():
		if props.is_destroyed(i):
			n += 1
	return n

# ---------------- server ----------------
## Explosion at pos (world): damage falls off like Match.explode, by distance to the hit box.
func on_explosion(pos: Vector3, radius: float, dmg: float, attacker: int) -> void:
	if dmg <= 0.0:
		return
	for i in count():
		if not props.is_active(i):
			continue
		var box: AABB = props.target_box(i)
		var d := pos.distance_to(_closest(box, pos))
		if d < radius:
			_damage(i, dmg * (1.0 - 0.5 * (d / radius)), attacker, "explosion")

## A hitscan ray that stopped on collider (machine gun).
func on_ray_hit(collider: Object, dmg: float, attacker: int) -> void:
	if collider == null or not collider.has_meta("prop_index") or props == null:
		return
	var i: int = collider.get_meta("prop_index")
	if props.is_active(i):
		_damage(i, dmg, attacker, "mg")

## After a vehicle's sim step: rams into target bodies.
func after_drive(v: Vehicle) -> void:
	if props == null:
		return
	var before: Vector3 = _last_vel.get(v.pid, v.velocity)
	_last_vel[v.pid] = v.velocity
	if not v.alive:
		return
	for k in v.get_slide_collision_count():
		var c := v.get_slide_collision(k)
		var o = c.get_collider()
		if o == null or not o.has_meta("prop_index"):
			continue
		var i: int = o.get_meta("prop_index")
		var key := "%d:%d" % [v.pid, i]
		if _ram_cd.has(key) or not props.is_active(i):
			continue
		var closing := maxf(before.dot(-c.get_normal()), 0.0)
		if closing < RAM_MIN_SPEED:
			continue
		_ram_cd[key] = RAM_COOLDOWN
		_damage(i, (closing - RAM_MIN_SPEED) * RAM_DAMAGE_PER_MS * clampf(v.veh_mass, 0.5, 3.0) + 1.0, v.pid, "ram")

func server_tick(dt: float) -> void:
	for k in _ram_cd.keys():
		_ram_cd[k] -= dt
		if _ram_cd[k] <= 0.0:
			_ram_cd.erase(k)
	if _test_every > 0.0 and m.started and not m.over and count() > 0:
		_test_timer += dt
		if _test_timer >= _test_every:
			_test_timer = 0.0
			var act: Array = []
			for i in count():
				if props.is_active(i):
					act.append(i)
			if not act.is_empty():
				var t: int = act[randi() % act.size()]
				_damage(t, hp[t] + 1.0, 255, "test")

func _damage(i: int, amount: float, attacker: int, source: String) -> void:
	if not m.started or m.over:
		return
	hp[i] -= amount
	if hp[i] > 0.0:
		return
	stats.destroyed += 1
	stats[source] += 1
	props.set_destroyed(i, true)
	var box: AABB = props.target_box(i)
	m._ev_explosion(box.get_center(), clampf(box.size.length() * 0.35, 2.0, 8.0))
	var w := Proto.writer()
	w.put_u8(Proto.EV_PROP)
	w.put_u8(i)
	w.put_u8(1)
	m.events.append(w.data_array)
	var gated := 0
	for g in m.pickup_gates:
		if g == i:
			gated += 1
	print("[match] lobby %s: prop %d (tag 0x%x) destroyed by %s (%s)%s" % [m.lobby.name if m.lobby else "?", i, props.target_tag(i),
		m._name_of(attacker), source, ", reveals %d pickup(s)" % gated if gated else ""])

## Destroyed flags for the full snapshot (empty when the arena has no targets).
func bitset() -> PackedByteArray:
	return props.bitset() if props != null else PackedByteArray()

static func _closest(box: AABB, p: Vector3) -> Vector3:
	return p.clamp(box.position, box.end)

# ---------------- client ----------------
func on_event(i: int, state: int) -> void:
	if props != null and i < count():
		props.set_destroyed(i, state != 0)

func apply_bitset(bits: PackedByteArray) -> void:
	if props != null:
		props.apply_bitset(bits)

## Per frame: tells the props where the vehicles are (foot soldiers react to them).
func client_process(vehicles: Dictionary) -> void:
	if props == null:
		return
	var pts: Array = []
	for v in vehicles.values():
		if v.alive:
			pts.append(v.visual_xf.origin)
	props.vehicle_points = pts
