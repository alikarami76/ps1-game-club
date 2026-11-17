class_name ProceduralArena
extends ArenaProvider
## Original test arena: flat floor, perimeter walls, central platform with four ramps,
## two jump ramps, crates and pillars.

const HALF := 70.0

var _grid_shader: Shader

func get_arena_name() -> String:
	return "Test Yard"

func _grid_mat(base: Color) -> ShaderMaterial:
	if _grid_shader == null:
		_grid_shader = Shader.new()
		_grid_shader.code = """
shader_type spatial;
uniform vec3 base_color : source_color = vec3(0.25, 0.27, 0.3);
uniform vec3 line_color : source_color = vec3(0.45, 0.47, 0.5);
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wpos.xz / 4.0;
	vec2 g = abs(fract(p - 0.5) - 0.5) / max(fwidth(p), vec2(0.0001));
	float m = 1.0 - min(min(g.x, g.y), 1.0);
	ALBEDO = mix(base_color, line_color, m);
	ROUGHNESS = 0.9;
}
"""
	var m := ShaderMaterial.new()
	m.shader = _grid_shader
	m.set_shader_parameter("base_color", Vector3(base.r, base.g, base.b))
	m.set_shader_parameter("line_color", Vector3(base.r, base.g, base.b) * 1.6)
	return m

func _std(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m

func _static_box(parent: Node3D, size: Vector3, xf: Transform3D, mat: Material) -> StaticBody3D:
	var sb := StaticBody3D.new()
	sb.transform = xf
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	sb.add_child(mi)
	parent.add_child(sb)
	return sb

func _pillar(parent: Node3D, pos: Vector3, r: float, h: float, mat: Material) -> void:
	var sb := StaticBody3D.new()
	sb.position = pos + Vector3(0, h * 0.5, 0)
	sb.collision_layer = 1
	sb.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = r
	shape.height = h
	cs.shape = shape
	sb.add_child(cs)
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	mi.mesh = cm
	mi.material_override = mat
	sb.add_child(mi)
	parent.add_child(sb)

# Ramp rising toward local -Z. low end sits on the ground; centre xz is given.
func _ramp(parent: Node3D, center_xz: Vector2, yaw_deg: float, length: float, width: float, angle_deg: float, mat: Material) -> void:
	var a := deg_to_rad(angle_deg)
	var t := 0.6
	var cy := (length * 0.5) * sin(a) - (t * 0.5) * cos(a)
	var basis := Basis(Vector3.UP, deg_to_rad(yaw_deg)) * Basis(Vector3.RIGHT, a)
	_static_box(parent, Vector3(width, t, length), Transform3D(basis, Vector3(center_xz.x, cy, center_xz.y)), mat)

func build_arena() -> Node3D:
	var root := Node3D.new()
	root.name = "TestYard"
	var floor_mat := _grid_mat(Color(0.2, 0.22, 0.25))
	var ramp_mat := _grid_mat(Color(0.33, 0.27, 0.15))
	var wall_mat := _std(Color(0.45, 0.2, 0.18))
	var crate_mat := _std(Color(0.5, 0.4, 0.22))
	var pillar_mat := _std(Color(0.3, 0.35, 0.5))

	_static_box(root, Vector3(HALF * 2, 2, HALF * 2), Transform3D(Basis.IDENTITY, Vector3(0, -1, 0)), floor_mat)
	var wh := 16.0
	_static_box(root, Vector3(HALF * 2 + 4, wh, 2), Transform3D(Basis.IDENTITY, Vector3(0, wh * 0.5, -HALF - 1)), wall_mat)
	_static_box(root, Vector3(HALF * 2 + 4, wh, 2), Transform3D(Basis.IDENTITY, Vector3(0, wh * 0.5, HALF + 1)), wall_mat)
	_static_box(root, Vector3(2, wh, HALF * 2), Transform3D(Basis.IDENTITY, Vector3(-HALF - 1, wh * 0.5, 0)), wall_mat)
	_static_box(root, Vector3(2, wh, HALF * 2), Transform3D(Basis.IDENTITY, Vector3(HALF + 1, wh * 0.5, 0)), wall_mat)

	# central platform (top at y=3) with four ramps
	_static_box(root, Vector3(24, 3, 24), Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), ramp_mat)
	var L := 14.0
	var ang := rad_to_deg(asin(3.0 / L))
	var off := 12.0 + (L * 0.5) * cos(deg_to_rad(ang))
	_ramp(root, Vector2(0, off), 0, L, 10, ang, ramp_mat)
	_ramp(root, Vector2(0, -off), 180, L, 10, ang, ramp_mat)
	_ramp(root, Vector2(off, 0), 90, L, 10, ang, ramp_mat)
	_ramp(root, Vector2(-off, 0), -90, L, 10, ang, ramp_mat)

	# ramp feet and tops for bot navigation (outside foot -> onto the platform)
	var nav: Array = []
	for d in [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0)]:
		nav.append([d * (off + L * 0.5 + 4.0) + Vector3(0, 0.6, 0), d * 6.0 + Vector3(0, 3.6, 0)])
	root.set_meta("ramps", nav)

	# jump ramps (face the middle, launch off the high edge)
	_ramp(root, Vector2(-42, 28), 90, 16, 8, 18, ramp_mat)
	_ramp(root, Vector2(42, -28), -90, 16, 8, 18, ramp_mat)

	# crates and pillars
	var crates := [Vector3(28, 0, 8), Vector3(-30, 0, -10), Vector3(14, 0, -34), Vector3(-16, 0, 36), Vector3(36, 0, 36), Vector3(-38, 0, -38)]
	for c in crates:
		_static_box(root, Vector3(4, 3, 4), Transform3D(Basis(Vector3.UP, deg_to_rad(c.x * 3.0)), c + Vector3(0, 1.5, 0)), crate_mat)
	for p in [Vector3(20, 0, 20), Vector3(-20, 0, 20), Vector3(20, 0, -20), Vector3(-20, 0, -20)]:
		_pillar(root, p, 1.5, 8.0, pillar_mat)

	# spawn points on a ring, facing the centre
	var spawns: Array = []
	for k in 8:
		var a2 := TAU * float(k) / 8.0 + 0.2
		var pos := Vector3(cos(a2) * 55.0, 0.9, sin(a2) * 55.0)
		spawns.append(Transform3D(Basis.looking_at(-pos.normalized() * Vector3(1, 0, 1), Vector3.UP), pos))
	root.set_meta("spawn_points", spawns)

	# pickup points
	var pk: Array = []
	for k in 8:
		var a3 := TAU * float(k) / 8.0 + 0.6
		pk.append(Vector3(cos(a3) * 32.0, 1.0, sin(a3) * 32.0))
	pk.append(Vector3(0, 4.0, 0))
	pk.append(Vector3(52, 1.0, 0))
	pk.append(Vector3(-52, 1.0, 0))
	pk.append(Vector3(0, 1.0, 52))
	pk.append(Vector3(0, 1.0, -52))
	root.set_meta("pickup_points", pk)
	return root
