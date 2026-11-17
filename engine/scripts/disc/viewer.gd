extends Node3D
## Disc content viewer: loads one arena by id with a free-fly camera and the 12 vehicles
## lined up at the spawn points.
## Run: Godot --path game res://scenes/disc/viewer.tscn -- --arena=WH/part1
## Options: --data=DIR, --upscale=1|2|4, --no-vehicles, --shot=user://shot.png (save one frame
## and quit), --cam=x,y,z and --look=x,y,z (camera position / target in metres), --lineup
## (vehicles in a row along x at the origin, fronts to -Z, instead of at the spawn points).
## Keys: right mouse = look, WASD = move, Q/E = down/up, Shift = fast, N/P = next/previous arena, V = toggle vehicles.

const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")
const DiscSettingsScript := preload("res://scripts/disc/disc_settings.gd")
const ArenaScript := preload("res://scripts/disc/disc_arena_provider.gd")
const VehiclesScript := preload("res://scripts/disc/disc_vehicle_models.gd")

@export var arena_id := ""

var args := {}
var cam: Camera3D
var arena: Node3D
var vehicles_node: Node3D
var yaw := 0.0
var pitch := -0.5
var ids := PackedStringArray()
var frames := 0
var label: Label

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("data"):
		DiscFilesScript.base_dir = args.data
	if args.has("upscale"):
		DiscSettingsScript.upscale_override = int(args.upscale)
	if args.has("arena"):
		arena_id = args.arena
	ids = ArenaScript.arena_ids()
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.32, 0.4, 0.5)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	cam = Camera3D.new()
	cam.far = 2000.0
	cam.fov = 70.0
	add_child(cam)
	cam.make_current()
	label = Label.new()
	label.position = Vector2(8, 8)
	var layer := CanvasLayer.new()
	layer.add_child(label)
	add_child(layer)
	if ids.is_empty():
		label.text = "No game data found under %s" % DiscFilesScript.get_base_dir()
		return
	if arena_id == "" or not arena_id in ids:
		arena_id = ids[0]
	_load_arena(arena_id)

func _load_arena(id: String) -> void:
	if arena:
		arena.queue_free()
	if vehicles_node:
		vehicles_node.queue_free()
		vehicles_node = null
	arena_id = id
	var prov = ArenaScript.new(id)
	arena = prov.build_arena()
	add_child(arena)
	var st: Dictionary = prov.last_stats
	var sz: Vector3 = st.get("size_m", Vector3(60, 10, 60))
	cam.position = Vector3(0, maxf(sz.x, sz.z) * 0.45, maxf(sz.x, sz.z) * 0.55)
	if args.has("cam"):
		cam.position = _vec(args.cam)
	cam.look_at(_vec(args.look) if args.has("look") else Vector3.ZERO)
	yaw = cam.rotation.y
	pitch = cam.rotation.x
	if not args.has("no-vehicles"):
		_spawn_vehicles()
	label.text = "%s  %d polys  %.0f ms  atlas %s\nN/P arena, RMB look, WASD/QE move, Shift fast, V vehicles" % [id, st.get("polygons", 0), st.get("total_ms", 0), st.get("atlas", "")]

func _spawn_vehicles() -> void:
	vehicles_node = Node3D.new()
	vehicles_node.name = "Vehicles"
	add_child(vehicles_node)
	var sp: Array = [] if args.has("lineup") else arena.get_meta("spawn_points", [])
	var vp = VehiclesScript.new()
	for i in vp.get_model_count():
		var m: Node3D = vp.build_model(i, Color.WHITE)
		if i < sp.size():
			m.transform = sp[i]
			m.position.y -= 1.0
		else:
			m.position = Vector3((i - sp.size()) * 4.0 - 22.0, 0.0, 0.0)  # row along x, fronts to -Z
		vehicles_node.add_child(m)

func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2])) if p.size() == 3 else Vector3.ZERO

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw -= ev.relative.x * 0.004
		pitch = clampf(pitch - ev.relative.y * 0.004, -1.55, 1.55)
		cam.rotation = Vector3(pitch, yaw, 0)
	elif ev is InputEventKey and ev.pressed and not ev.echo and not ids.is_empty():
		var i := ids.find(arena_id)
		match ev.physical_keycode:
			KEY_N: _load_arena(ids[(i + 1) % ids.size()])
			KEY_P: _load_arena(ids[(i - 1 + ids.size()) % ids.size()])
			KEY_V:
				if vehicles_node:
					vehicles_node.visible = not vehicles_node.visible

func _process(delta: float) -> void:
	var d := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): d.z -= 1
	if Input.is_physical_key_pressed(KEY_S): d.z += 1
	if Input.is_physical_key_pressed(KEY_A): d.x -= 1
	if Input.is_physical_key_pressed(KEY_D): d.x += 1
	if Input.is_physical_key_pressed(KEY_Q): d.y -= 1
	if Input.is_physical_key_pressed(KEY_E): d.y += 1
	var speed := 60.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 15.0
	cam.position += cam.global_transform.basis * d * speed * delta
	frames += 1
	if args.has("shot") and frames == 20:
		var img := get_viewport().get_texture().get_image()
		var path: String = args.shot
		img.save_png(path)
		print("[viewer] saved ", ProjectSettings.globalize_path(path))
		get_tree().quit()
