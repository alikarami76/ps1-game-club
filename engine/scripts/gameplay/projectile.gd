class_name Projectile
extends Node3D
## Missiles and mines. Logic runs on the server only. On clients a projectile is either a
## snapshot proxy (interpolated like vehicles) or a locally predicted missile the shooter sees
## the moment they fire, until the server's copy takes over.


var id := 0
var type := Weapons.P_FIRE
var damage := 7.0
var owner_id := 0
var sim := false
var velocity := Vector3.ZERO
var life := 6.0
var age := 0.0
var target: Vehicle = null
var turn := 0.0                 # homing turn rate, rad/s (0 = flies straight)
var game: Node
# client
var predicted := false          # local prediction, not yet confirmed by the server
var own := false                # fired by the local player (drawn ahead, not in the past)
var _buf: Array = []            # [tick, pos, yaw, pitch]
var _blend := 0.0               # seconds left blending from the predicted position

func setup(kind: int, simulate: bool, g: Node) -> void:
	type = kind
	sim = simulate
	game = g
	life = 45.0 if kind == Weapons.P_MINE else 6.0
	if Game.is_server:
		return
	var col := Weapons.proj_color(kind)
	var mi := MeshInstance3D.new()
	var m := StandardMaterial3D.new()
	m.emission_enabled = true
	m.emission = col
	if kind == Weapons.P_MINE:
		var c2 := CylinderMesh.new()
		c2.top_radius = 0.55
		c2.bottom_radius = 0.6
		c2.height = 0.2
		mi.mesh = c2
		m.albedo_color = Color(0.2, 0.2, 0.22)
		m.emission_energy_multiplier = 0.6
	elif kind == Weapons.P_BOLT or kind == Weapons.P_HEAVY:
		var sp := SphereMesh.new()
		sp.radius = 0.22 if kind == Weapons.P_BOLT else 0.4
		sp.height = sp.radius * 2.0
		mi.mesh = sp
		m.albedo_color = col
		m.emission_energy_multiplier = 2.0
	else:
		var c := CylinderMesh.new()
		c.top_radius = 0.14
		c.bottom_radius = 0.14
		c.height = 1.3 if kind != Weapons.P_POWER else 1.7
		mi.mesh = c
		mi.rotation_degrees = Vector3(90, 0, 0)
		m.albedo_color = Color(0.85, 0.85, 0.8)
		m.emission_energy_multiplier = 0.8
		var nose := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.16
		s.height = 0.32
		nose.mesh = s
		nose.position = Vector3(0, 0, -0.7)
		var nm := StandardMaterial3D.new()
		nm.albedo_color = col
		nm.emission_enabled = true
		nm.emission = col
		nm.emission_energy_multiplier = 1.5
		nose.material_override = nm
		add_child(nose)
	mi.material_override = m
	add_child(mi)

# ---------------- client ----------------
func push_sample(tick: float, pos: Vector3, y: float, pitch: float) -> void:
	if not _buf.is_empty() and tick <= _buf[-1][0]:
		return
	if predicted:
		predicted = false
		_blend = 0.15
	_buf.append([tick, pos, y, pitch])
	if _buf.size() == 1 and _blend <= 0.0:
		global_transform = Transform3D(Basis.from_euler(Vector3(pitch, y, 0)), pos)
	while _buf.size() > 30:
		_buf.pop_front()

## rt: render tick for remote objects; now_tick: estimated current server tick (own missiles
## are drawn there, extrapolated, so they leave the shooter's muzzle without delay).
func render(rt: float, now_tick: float, delta: float) -> void:
	if predicted:
		age += delta
		global_position += velocity * delta
		if age > 1.0:
			queue_free()
		return
	if _buf.is_empty():
		return
	var t := now_tick if own else rt
	while _buf.size() >= 3 and _buf[1][0] <= t:
		_buf.pop_front()
	var a: Array = _buf[0]
	var pos: Vector3 = a[1]
	var y: float = a[2]
	var pitch: float = a[3]
	if _buf.size() >= 2:
		var c: Array = _buf[-1] if own else _buf[1]
		var b0: Array = _buf[-2] if own else a
		var span: float = maxf(c[0] - b0[0], 0.001)
		var k: float = clampf((t - b0[0]) / span, 0.0, 1.0 + 9.0 / span)
		pos = (b0[1] as Vector3).lerp(c[1], k)
		y = lerp_angle(b0[2], c[2], minf(k, 1.0))
		pitch = lerpf(b0[3], c[3], minf(k, 1.0))
	var xf := Transform3D(Basis.from_euler(Vector3(pitch, y, 0)), pos)
	if _blend > 0.0:
		_blend -= delta
		var w := clampf(1.0 - _blend / 0.15, 0.0, 1.0)
		global_transform = global_transform.interpolate_with(xf, w)
	else:
		global_transform = xf

# ---------------- server ----------------
func _physics_process(dt: float) -> void:
	if not sim:
		return
	age += dt
	life -= dt
	if type == Weapons.P_MINE:
		_mine()
	else:
		_missile(dt)

func _missile(dt: float) -> void:
	if life <= 0.0:
		_explode(global_position)
		return
	var cur := velocity.normalized()
	if target != null and is_instance_valid(target) and target.alive:
		var desired := (target.global_position + Vector3(0, 0.3, 0) - global_position).normalized()
		var ang := cur.angle_to(desired)
		var axis := cur.cross(desired)
		if axis.length() > 0.001 and ang > 0.0001:
			cur = cur.rotated(axis.normalized(), minf(ang, turn * dt))
	velocity = cur * velocity.length()
	var from := global_position
	var to := from + velocity * dt
	var q := PhysicsRayQueryParameters3D.create(from, to, 3)
	var ov = game.vehicles.get(owner_id)
	if ov != null and age < 0.5:
		q.exclude = [ov.get_rid()]
	var r := get_world_3d().direct_space_state.intersect_ray(q)
	if not r.is_empty():
		_explode(r.position)
		return
	for v in game.vehicles.values():
		if v.alive and v.pid != owner_id and v.global_position.distance_to(to) < 2.0:
			_explode(to)
			return
	global_position = to
	global_transform.basis = Basis.looking_at(cur, Vector3.UP if absf(cur.y) < 0.99 else Vector3.RIGHT)

func _mine() -> void:
	if life <= 0.0:
		_destroy()
		return
	if age < 1.0:
		return
	for v in game.vehicles.values():
		if v.alive and v.pid != owner_id and v.global_position.distance_to(global_position) < 3.4:
			_explode(global_position)
			return

func _weapon_id() -> int:
	match type:
		Weapons.P_FIRE: return Weapons.FIRE
		Weapons.P_HOMING: return Weapons.HOMING
		Weapons.P_POWER: return Weapons.POWER
		Weapons.P_FREEZE: return Weapons.FREEZE
		Weapons.P_MINE: return Weapons.MINE
	return Weapons.SPECIAL

func _explode(pos: Vector3) -> void:
	if type == Weapons.P_FREEZE:
		game.freeze(pos, owner_id)
	else:
		game.explode(pos, 5.0 if type == Weapons.P_HEAVY or type == Weapons.P_POWER else 3.5, damage, owner_id, _weapon_id())
	_destroy()

func _destroy() -> void:
	game.projectiles.erase(id)
	queue_free()
