extends Node
## Test tool (no window needed: runs in the Web export in headless Chrome): renders disc arenas
## from camera poses read in the emulator and posts the frames back to the local test server
## (cache/fidelity/visual/serve.py, loopback only). Started with the page argument
## ?job=<name>; the job JSON lists the arena, the game-data files to fetch and the shots.
## Nothing is saved in the build; game data comes from the player's own folder via the server.

const DiscArena := preload("res://scripts/disc/disc_arena_provider.gd")
const DiscCars := preload("res://scripts/disc/disc_vehicle_models.gd")
const DiscFilesS := preload("res://scripts/disc/disc_files.gd")
const DiscSettingsS := preload("res://scripts/disc/disc_settings.gd")
const DiscBuilder := preload("res://scripts/disc/mesh_builder.gd")
const Ps1 := preload("res://scripts/render/ps1_settings.gd")
const ChaseCam := preload("res://scripts/gameplay/chase_camera.gd")
const DiscFxS := preload("res://scripts/render/disc_fx.gd")

var _files := {}
var _http: HTTPRequest
var _vp: SubViewport
var _log := PackedStringArray()

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_run.call_deferred()

func _say(s: String) -> void:
	print("[fidelity] ", s)

var _origin := "http://127.0.0.1:8000"

func _fetch(url: String) -> PackedByteArray:
	var err := _http.request(_origin + url)
	if err != OK:
		return PackedByteArray()
	var r: Array = await _http.request_completed
	return r[3] if r[1] == 200 else PackedByteArray()

func _post(url: String, body: PackedByteArray) -> void:
	_http.request_raw(_origin + url, PackedStringArray(["Content-Type: application/octet-stream"]), HTTPClient.METHOD_POST, body)
	await _http.request_completed

func _run() -> void:
	var job_name := "job"
	if OS.has_feature("web"):
		_origin = str(JavaScriptBridge.eval("location.origin", true))
		var q := str(JavaScriptBridge.eval("location.search", true)).trim_prefix("?")
		for part in q.split("&", false):
			var kv := part.split("=", true, 1)
			if kv[0] == "job" and kv.size() > 1:
				job_name = kv[1]
	var job = JSON.parse_string((await _fetch("/job/%s.json" % job_name)).get_string_from_utf8())
	if typeof(job) != TYPE_DICTIONARY:
		_say("no job")
		await _post("/done", "no job".to_utf8_buffer())
		return
	for f in job.files:
		_files[f] = await _fetch("/gd/" + f)
	DiscFilesS.reader = func(rel: String) -> PackedByteArray: return _files.get(rel, PackedByteArray())
	DiscSettingsS.upscale_override = int(job.get("upscale", 1))
	var legacy := bool(job.get("legacy", false))
	if legacy:   # the look before this work
		for k in ["ps1_accurate", "color_15bit", "depth_cue", "nearest"]:
			Ps1.set_override(k, false)
	for k in job.get("settings", {}):
		Ps1.set_override(k, job.settings[k])
	var size := Vector2i(int(job.get("w", 320)), int(job.get("h", 240)))
	_vp = SubViewport.new()
	_vp.size = size
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.8)
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC   # what match.gd sets up
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	DiscBuilder.sky_priority = int(job.get("sky_priority", 0))
	DiscArena.clear_cache()
	var arena: Node3D = DiscArena.new(str(job.arena)).build_arena()
	_vp.add_child(arena)
	env.background_color = arena.get_meta("background", Color(0.2, 0.2, 0.2))
	await get_tree().process_frame
	await get_tree().process_frame
	if legacy:
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		RenderingServer.global_shader_parameter_set("ps1_xstretch", 1.0)
	_off = arena.get_meta("game_offset", Vector3.ZERO)
	if job.get("no_sky", false):
		var snode := arena.find_child("Sky", true, false)
		if snode:
			snode.visible = false
	if job.get("no_ground", false):
		var gnode := arena.find_child("Ground", true, false)
		if gnode:
			gnode.visible = false
	for gk in job.get("globals", {}):
		var gv = job.globals[gk]
		RenderingServer.global_shader_parameter_set(gk, Vector2(gv[0], gv[1]) if typeof(gv) == TYPE_ARRAY else float(gv))
	if job.has("linearize"):
		RenderingServer.global_shader_parameter_set("ps1_linearize", float(job.linearize))
	var cars := Node3D.new()
	_vp.add_child(cars)
	for shot in job.shots:
		for c in cars.get_children():
			c.queue_free()
		var player_xf := Transform3D()
		var player_up := 0.0
		var player_go := Vector3.ZERO
		for v in shot.vehicles:
			var m: Node3D = DiscCars.build_model_by_object_id(int(v.oid))
			m.set("_menu_done", not shot.get("menu_light", false))   # in-game lighting unless asked
			cars.add_child(m)
			var go: Vector3 = m.get_meta("game_origin", Vector3.ZERO)
			var b := Basis(Vector3.UP, -float(v.head) * TAU / 4096.0)
			var p := _g(v.pos)
			m.global_transform = Transform3D(b, p - b * go)
			if v.get("player", false):
				player_xf = Transform3D(b, p - b * go + b * Vector3(0, ChaseCam.BODY_RADIUS, 0))
				player_up = go.y - ChaseCam.BODY_RADIUS
				player_go = go
		var mode := str(shot.get("camera", "emu"))
		var cam: Camera3D = ChaseCam.new() if mode in ["chase", "track"] else Camera3D.new()
		_vp.add_child(cam)
		cam.current = true
		cam.far = 1500.0
		if mode == "emu":
			cam.keep_aspect = Camera3D.KEEP_HEIGHT
			cam.fov = Ps1.VFOV
			var r: Array = shot.R
			var x := _dir(r[0]); var y := -_dir(r[1]); var z := -_dir(r[2])
			cam.global_transform = Transform3D(Basis(x, y, z).orthonormalized(), _g(shot.cam_pos))
		elif mode == "look":
			cam.fov = float(shot.get("fov", 60.0))
			cam.global_position = _g(shot.eye)
			cam.look_at(_g(shot.at), Vector3.UP if absf(_g(shot.eye).x - _g(shot.at).x) + absf(_g(shot.eye).z - _g(shot.at).z) > 0.01 else Vector3.FORWARD)
		elif mode == "track":
			cam.set("origin_up", player_up)
			cam.set("collide", false)
			var tr: Array = shot.track
			for i in tr.size():
				for sub in 3:
					var f := (sub + 1) / 3.0
					var a: Array = tr[maxi(i - 1, 0)]
					var b2: Array = tr[i]
					var hd := lerp_angle(float(a[3]) * TAU / 4096.0, float(b2[3]) * TAU / 4096.0, f)
					var gp := _g([lerpf(a[0], b2[0], f), lerpf(a[1], b2[1], f), lerpf(a[2], b2[2], f)])
					var bb := Basis(Vector3.UP, -hd)
					cam.call("follow", Transform3D(bb, gp - bb * player_go + bb * Vector3(0, ChaseCam.BODY_RADIUS, 0)), 1.0 / 60.0)
		elif mode == "chase":
			cam.set("origin_up", player_up)
			cam.set("collide", false)
			for i in 40:
				cam.call("follow", player_xf, 1.0 / 60.0)
		else:   # the camera before this work: fov 72, 8 m back, 3.6 m up
			cam.fov = 72.0
			var fwd := -player_xf.basis.z
			cam.global_position = player_xf.origin - fwd * 8.0 + Vector3(0, 3.6, 0)
			cam.look_at(player_xf.origin + Vector3(0, 1.2, 0) + fwd * 4.0, Vector3.UP)
		await _post("/log", ("fx frames: explosion %s smoke %s sparks %s; method %s" % [DiscFxS.has_frames("explosion"), DiscFxS.has_frames("smoke"), DiscFxS.has_frames("sparks"), RenderingServer.get_current_rendering_method()]).to_utf8_buffer())
		if shot.has("tint"):
			var tc: Array = shot.tint
			for c2 in cars.get_children():
				c2.call("_set_tint", c2, Color(tc[0], tc[1], tc[2], tc[3]))
		if shot.has("explode"):
			Fx.explosion(_vp, _g(shot.explode), float(shot.get("radius", 4.0)))
			await get_tree().create_timer(float(shot.get("wait", 0.3))).timeout
		for i in 4:
			await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		await _post("/save/%s.png" % str(shot.name), img.save_png_to_buffer())
		_say("saved " + str(shot.name))
		cam.queue_free()
	await _post("/done", "ok".to_utf8_buffer())

var _off := Vector3.ZERO

func _g(v) -> Vector3:
	return DiscBuilder.to_godot(Vector3(float(v[0]), float(v[1]), float(v[2]))) * DiscBuilder.WORLD_UNIT_M + _off

func _dir(v) -> Vector3:
	return DiscBuilder.to_godot(Vector3(float(v[0]), float(v[1]), float(v[2]))).normalized()
