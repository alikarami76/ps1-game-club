class_name DiscSkyFollow
extends MeshInstance3D
## Keeps the sky object where the game puts it: at the player's x/z (the chase camera's
## followed point when there is one, else the camera) and at the arena's game z = 0 height
## (ground_y, in the parent's space). Measured: placed-object record 1 = (player x, y, 0).

var ground_y := 0.0

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p: Vector3 = cam.global_position
	if "focus" in cam and cam.focus != null:
		p = cam.focus
	var parent := get_parent() as Node3D
	var y := ground_y if parent == null else (parent.global_transform * Vector3(0, ground_y, 0)).y
	global_position = Vector3(p.x, y, p.z)
