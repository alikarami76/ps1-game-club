class_name ProceduralVehicleModels
extends VehicleModelProvider
## Eight original box-and-cylinder vehicles. Index picks the shape, colour is the body colour.

func get_model_count() -> int:
	return 8

func get_model_name(index: int) -> String:
	return "Vehicle %d" % (index + 1)

func _mat(c: Color, rough := 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

func _cyl(parent: Node3D, r: float, h: float, pos: Vector3, mat: Material, rot_deg: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = 16
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

func build_model(index: int, color: Color) -> Node3D:
	var root := Node3D.new()
	var body := _mat(color)
	var trim := _mat(color.darkened(0.45))
	var dark := _mat(Color(0.08, 0.08, 0.09), 0.9)
	var glass := _mat(Color(0.15, 0.2, 0.28), 0.2)
	var metal := _mat(Color(0.6, 0.62, 0.66), 0.35)
	var i := index % 8
	var width := 1.8
	var length := 3.6
	var wheel_r := 0.4
	match i:
		1: width = 2.0; length = 3.9; wheel_r = 0.48
		3: width = 1.9; length = 3.8
		4: width = 2.0; length = 3.8; wheel_r = 0.5
		5: width = 2.0; length = 3.4; wheel_r = 0.36
		7: width = 1.8; length = 3.8
	var wy := wheel_r
	var by := wheel_r + 0.2
	_box(root, Vector3(width, 0.5, length), Vector3(0, by + 0.05, 0), body)
	# wheels
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_cyl(root, wheel_r, 0.32, Vector3(sx * (width * 0.5 + 0.02), wy, sz * length * 0.32), dark, Vector3(0, 0, 90))
	# cabin and extras differ by style
	match i:
		0:
			_box(root, Vector3(width * 0.85, 0.5, 1.5), Vector3(0, by + 0.5, 0.3), trim)
			_box(root, Vector3(width * 0.8, 0.3, 0.05), Vector3(0, by + 0.55, -0.46), glass)
		1:
			_box(root, Vector3(width * 0.8, 0.55, 1.2), Vector3(0, by + 0.55, 0.6), trim)
			_box(root, Vector3(width * 1.05, 0.7, 0.35), Vector3(0, by - 0.05, -length * 0.5 - 0.1), metal, Vector3(-20, 0, 0))
		2:
			_box(root, Vector3(width * 0.75, 0.4, 1.3), Vector3(0, by + 0.45, 0.2), trim)
			_box(root, Vector3(width * 0.95, 0.08, 0.5), Vector3(0, by + 0.85, length * 0.5 - 0.15), trim)
			_box(root, Vector3(0.1, 0.4, 0.1), Vector3(-0.6, by + 0.6, length * 0.5 - 0.15), dark)
			_box(root, Vector3(0.1, 0.4, 0.1), Vector3(0.6, by + 0.6, length * 0.5 - 0.15), dark)
		3:
			_box(root, Vector3(width * 0.8, 0.45, 1.3), Vector3(0, by + 0.5, 0.7), trim)
			_cyl(root, 0.38, 0.3, Vector3(0, by + 0.9, -0.4), metal, Vector3.ZERO)
			_cyl(root, 0.07, 1.5, Vector3(0, by + 0.95, -1.2), dark, Vector3(90, 0, 0))
		4:
			_box(root, Vector3(width * 0.95, 1.1, 1.3), Vector3(0, by + 0.8, -0.9), trim)
			_box(root, Vector3(width * 0.95, 0.9, 1.9), Vector3(0, by + 0.7, 0.9), body.duplicate())
		5:
			_box(root, Vector3(width * 0.6, 0.35, 1.2), Vector3(0, by + 0.4, 0.3), trim)
			_box(root, Vector3(0.08, 0.7, 0.9), Vector3(0, by + 0.65, length * 0.5 - 0.5), trim)
		6:
			_box(root, Vector3(width * 0.8, 0.5, 1.5), Vector3(0, by + 0.5, 0.3), trim)
			for sx2 in [-1.0, 1.0]:
				_cyl(root, 0.1, 2.0, Vector3(sx2 * (width * 0.5 + 0.12), by - 0.1, 0.2), metal, Vector3(90, 0, 0))
		7:
			_box(root, Vector3(width * 0.8, 0.45, 1.4), Vector3(0, by + 0.5, 0.4), trim)
			_box(root, Vector3(1.2, 0.12, 0.2), Vector3(0, by + 0.8, 0.4), _mat(Color(1.0, 0.75, 0.1), 0.3))
			_box(root, Vector3(0.5, 0.15, 0.9), Vector3(0, by + 0.35, -1.0), trim)
	return root
