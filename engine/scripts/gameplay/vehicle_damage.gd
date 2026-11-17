extends RefCounted
## Client-side vehicle damage visuals from the replicated health (no extra network data).
##   level 0 intact, 1 damaged (health <= 50%), 2 wrecked (dead, until respawn)
## Disc models (scripts/disc/disc_vehicle_visual.gd) switch their body state (switch tag
## vehicle id + 1) and cycle the wheel frames (id + 2) with the speed the model moves at.
## Every model also gets smoke (grey when damaged, thick and dark when wrecked); models without
## damage states (the built-in procedural ones) darken their materials instead. A dead vehicle
## stays visible as a wreck where it died.

const DAMAGED_AT := 0.5

static func level_of(v: Vehicle) -> int:
	if not v.alive:
		return 2
	return 1 if v.hp <= v.max_hp * DAMAGED_AT else 0

## Called by the match every frame after Vehicle.update_visual().
static func update(v: Vehicle, delta: float) -> void:
	var model: Node3D = v.model
	if model == null:
		return
	var lvl := level_of(v)
	var st: Dictionary = model.get_meta("dmg_state", {})
	if st.is_empty():
		st = {"level": 0, "pos": v.visual_xf.origin, "smoke": null, "mats": null}
		model.set_meta("dmg_state", st)
	if not v.alive:
		model.visible = true   # the wreck stays until the respawn (Vehicle hides the model)
	var disc: bool = model.has_method("has_damage_states") and model.call("has_damage_states")
	if lvl != st.level:
		st.level = lvl
		if disc:
			model.call("set_damage_level", lvl)
		else:
			_darken(model, st, lvl)
		_smoke(model, st, lvl)
	if model.has_method("set_wheel_speed") and delta > 0.0:
		var p: Vector3 = v.visual_xf.origin
		var last: Vector3 = st.pos
		st.pos = p
		var sp := Vector2(p.x - last.x, p.z - last.z).length() / delta
		if sp < 80.0 and v.alive:
			model.call("set_wheel_speed", sp, delta)

## Built-in models: multiply every material's albedo (originals kept in the state).
static func _darken(model: Node3D, st: Dictionary, lvl: int) -> void:
	if st.mats == null:
		var mats: Array = []
		var seen := {}
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			var mat = (mi as MeshInstance3D).material_override
			if mat is StandardMaterial3D and not seen.has(mat):
				seen[mat] = true
				mats.append([mat, (mat as StandardMaterial3D).albedo_color])
		st.mats = mats
	var k: float = [1.0, 0.6, 0.22][lvl]
	for e in st.mats:
		var c: Color = e[1]
		(e[0] as StandardMaterial3D).albedo_color = Color(c.r * k, c.g * k, c.b * k, c.a)

static func _smoke(model: Node3D, st: Dictionary, lvl: int) -> void:
	var p: CPUParticles3D = st.smoke
	if lvl == 0:
		if p != null:
			p.emitting = false
		return
	if p == null:
		p = CPUParticles3D.new()
		p.name = "DamageSmoke"
		var sz: Vector3 = model.get_meta("size_m", Vector3(2, 1.6, 4))
		p.position = Vector3(0, sz.y * 0.8, -sz.z * 0.2)
		p.local_coords = false
		p.lifetime = 1.4
		p.direction = Vector3.UP
		p.spread = 18.0
		p.gravity = Vector3(0, 1.2, 0)
		p.initial_velocity_min = 0.8
		p.initial_velocity_max = 1.8
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.2
		var curve := Curve.new()
		curve.add_point(Vector2(0, 0.4))
		curve.add_point(Vector2(1, 1.6))
		p.scale_amount_curve = curve
		var q := QuadMesh.new()
		q.size = Vector2(0.8, 0.8)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.vertex_color_use_as_albedo = true
		q.material = mat
		p.mesh = q
		var g := Gradient.new()
		g.set_color(0, Color(0.35, 0.35, 0.35, 0.55))
		g.set_color(1, Color(0.2, 0.2, 0.2, 0.0))
		p.color_ramp = g
		model.add_child(p)
		st.smoke = p
	p.amount = 10 if lvl == 1 else 26
	p.color = Color(0.75, 0.75, 0.75) if lvl == 1 else Color(0.25, 0.22, 0.2)
	p.emitting = true
