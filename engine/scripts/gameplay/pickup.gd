class_name Pickup
extends Node3D
## Floating, spinning pickup. Type is derived from its index so no sync is needed.

const TYPES := ["fire", "health", "homing", "mine", "power", "freeze"]
const COLORS := {
	"fire": Color(1.0, 0.5, 0.1), "health": Color(0.2, 0.9, 0.3), "mine": Color(0.9, 0.15, 0.15),
	"homing": Color(1.0, 0.85, 0.2), "power": Color(1.0, 0.25, 0.2), "freeze": Color(0.4, 0.8, 1.0),
	"random": Color(0.85, 0.85, 0.95),
}

var type := "missile"
var base_y := 0.0
var _t := randf() * TAU

func setup(kind: String) -> void:
	type = kind
	var mi := MeshInstance3D.new()
	match kind:
		"fire", "homing", "power":
			var c := CylinderMesh.new()
			c.top_radius = 0.18
			c.bottom_radius = 0.18
			c.height = 1.0
			mi.mesh = c
			mi.rotation_degrees = Vector3(90, 0, 0)
		"health":
			var b := BoxMesh.new()
			b.size = Vector3(0.8, 0.8, 0.8)
			mi.mesh = b
		"mine":
			var c2 := CylinderMesh.new()
			c2.top_radius = 0.5
			c2.bottom_radius = 0.5
			c2.height = 0.25
			mi.mesh = c2
		"random":
			var pr := PrismMesh.new()
			pr.size = Vector3(0.8, 0.8, 0.8)
			mi.mesh = pr
		"freeze":
			var s := SphereMesh.new()
			s.radius = 0.45
			s.height = 0.9
			mi.mesh = s
	var m := StandardMaterial3D.new()
	var col: Color = COLORS.get(kind, Color.WHITE)
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.2
	mi.material_override = m
	var holder := Node3D.new()
	holder.name = "Holder"
	add_child(holder)
	holder.add_child(mi)

func _process(delta: float) -> void:
	_t += delta
	var h := get_node("Holder") as Node3D
	h.rotation.y += delta * 2.0
	h.position.y = sin(_t * 2.0) * 0.15
