class_name Fx
extends RefCounted
## Short-lived visual effects. On disc arenas they use the original's own effect frames from
## the arena's texture file (scripts/render/disc_fx.gd: explosion, flash, smoke, sparks,
## fire), played at the game's 20 frames a second; elsewhere simple primitives.

const DiscFx := preload("res://scripts/render/disc_fx.gd")
const FRAME := 0.05   # the game animates at 20 frames a second

## Small burst of sparks where a machine-gun round hits (disc arenas).
static func hit_sparks(parent: Node, pos: Vector3) -> void:
	DiscFx.spawn(parent, "sparks", pos, 1.2, 5 * FRAME)

## Muzzle flash at the gun (disc arenas).
static func muzzle(parent: Node, pos: Vector3) -> void:
	DiscFx.spawn(parent, "glow", pos, 0.7, 3 * FRAME)

static func tracer(parent: Node, a: Vector3, b: Vector3) -> void:
	var len := a.distance_to(b)
	if len < 0.1:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.06, len)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.9, 0.4)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = (a + b) * 0.5
	mi.look_at(b, Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.RIGHT)
	parent.get_tree().create_timer(0.06).timeout.connect(mi.queue_free)
	if DiscFx.has_frames("sparks"):
		hit_sparks(parent, b)

static func explosion(parent: Node, pos: Vector3, radius: float) -> void:
	if DiscFx.has_frames("explosion"):
		# the original: a fireball (15 frames), a short blue-white flash, then smoke rising
		var size := clampf(radius * 1.4, 2.0, 9.0)
		DiscFx.spawn(parent, "explosion", pos + Vector3(0, size * 0.3, 0), size, 15 * FRAME, size * 0.2)
		DiscFx.spawn(parent, "flash", pos + Vector3(0, size * 0.3, 0), size * 0.8, 4 * FRAME)
		var tree := parent.get_tree()
		tree.create_timer(8 * FRAME).timeout.connect(func():
			if is_instance_valid(parent):
				DiscFx.spawn(parent, "smoke", pos + Vector3(0, size * 0.5, 0), size * 1.1, 20 * FRAME, size * 0.8))
		return
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 16
	sm.rings = 8
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.55, 0.15, 0.85)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * 0.3
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.2)
	light.light_energy = 4.0
	light.omni_range = radius * 2.5
	mi.add_child(light)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * radius * 1.6, 0.35)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.35)
	tw.tween_property(light, "light_energy", 0.0, 0.35)
	tw.chain().tween_callback(mi.queue_free)

## Flame special: a short burst of glowing puffs in front of the vehicle.
static func flame(parent: Node, v: Node3D) -> void:
	for i in 8:
		parent.get_tree().create_timer(i * 0.13).timeout.connect(func():
			if is_instance_valid(v) and is_instance_valid(parent):
				var xf: Transform3D = v.visual_xf
				var fwd := -xf.basis.z
				if DiscFx.has_frames("fire"):
					DiscFx.spawn(parent, "fire", xf.origin + fwd * (4.0 + randf() * 7.0) + Vector3(randf_range(-1, 1), 1.0, randf_range(-1, 1)), 2.4, 10 * FRAME, 0.8)
					return
				explosion(parent, xf.origin + fwd * (4.0 + randf() * 7.0) + Vector3(randf_range(-1, 1), 0.6, randf_range(-1, 1)), 1.2))

## Shockwave special: an expanding flat ring.
static func shockwave(parent: Node, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.8
	tm.outer_radius = 1.0
	mi.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.5, 0.85, 1.0, 0.8)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos + Vector3(0, 0.4, 0)
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(15, 1, 15), 0.4)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.4)
	tw.chain().tween_callback(mi.queue_free)
