extends Node
## Global settings, content providers and command line options.
##
## Roles (command line, after `--`):
##   --server [--port=8910] [--http-port=8080] [--web-root=PATH] [--transport=enet] [--data=PATH]
##       dedicated headless server, no local player (see scripts/server/game_server.gd). With
##       --data the folder must hold manifest.json (disc arenas need it for collision).
##   --connect=HOST:PORT [--name=X] [--lobby=NAME] [--autostart=N] [--bots=N] [--autodrive]
##       client that joins (or creates) a lobby automatically (used by tests/net/*.sh)
##   --host [--solo] [--arena=ID] [--bots=N]
##       start a local headless server and join it; --solo starts a match with bots at once
##   --netstats  --overlay  --net-latency=MS --net-jitter=MS --net-loss=PCT [--net-loss-mode=hol|drop]
##   --no-predict  --verbose  --score-limit=N  --time-limit=SECONDS  --exit-after=SECONDS  --data=PATH
##   --vehicle=ID (vehicle id, e.g. builtin_3 or a game-data id)  --no-disc-models
##   --vehicle-collision=hull|box|capsule (disc vehicles; default hull)

const SERVER_SCENE := "res://scenes/server.tscn"
const DiscArena := preload("res://scripts/disc/disc_arena_provider.gd")
const DiscCars := preload("res://scripts/disc/disc_vehicle_models.gd")
const DiscFilesS := preload("res://scripts/disc/disc_files.gd")
const DiscManifestS := preload("res://scripts/disc/manifest.gd")
const DiscSettingsS := preload("res://scripts/disc/disc_settings.gd")
## Measured numbers only (no disc content); shipped with the game so the server and every
## client run exactly the same vehicle profiles.
const TUNING_RES := "res://data/tuning.json"
const TEST_YARD := "test_yard"
const BODY_RADIUS := 0.6        # body origin height above the ground (Vehicle.RADIUS)

var player_name := "Driver"
var player_color := Color(0.85, 0.22, 0.17)
var player_vid := ""            # preferred vehicle id ("" = let the lobby pick)
var server_addr := "127.0.0.1:8910"
var last_message := ""
var last_results: Dictionary = {}   # the last match's final scores, for the results page
var is_server := false

# Swap these to feed in other arenas or vehicle visuals.
var arena_provider: ArenaProvider = ProceduralArena.new()
var vehicle_provider: VehicleModelProvider = ProceduralVehicleModels.new()
var builtin_models := ProceduralVehicleModels.new()
var disc_models = null          # DiscVehicleModels when the game data has vehicles

var profiles := VehicleProfiles.new()
var audio_provider: AudioProvider
var sfx: SfxPlayer        # set by the running match

var args := {}   # parsed from `-- --key=value --flag`
var _collision_cache := {}

const ACTION_KEYS := {
	"accelerate": KEY_W, "brake": KEY_S, "steer_left": KEY_A, "steer_right": KEY_D,
	"fire_mg": KEY_SPACE, "fire_special": KEY_SHIFT, "weapon_next": KEY_E, "weapon_prev": KEY_Q,
	"reset_vehicle": KEY_R, "handbrake": KEY_CTRL, "scoreboard": KEY_TAB, "pause_menu": KEY_ESCAPE,
	"turbo": KEY_ALT,
}

func _ready() -> void:
	_ensure_actions()
	for a in OS.get_cmdline_user_args():
		var s := a.trim_prefix("--")
		var kv := s.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if OS.has_feature("web"):
		_web_args()
	if args.has("join") and not args.has("connect"):   # old flag
		args["connect"] = "%s:%s" % [args["join"], args.get("port", "8910")]
	is_server = args.has("server")
	if args.has("data"):
		GameData.root_override = args["data"]
	if args.has("upscale"):
		DiscSettingsS.upscale_override = int(args["upscale"])
	_load_profile()
	if args.has("name"):
		player_name = args["name"]
	if args.has("vehicle"):
		player_vid = str(args["vehicle"])
	var n := profiles.load_disc_tuning(TUNING_RES)
	if n == 0:
		n = profiles.load_disc_tuning(GameData.tuning_path())
	if n > 0:
		print("[game] loaded %d measured vehicle profiles" % n)
	if is_server and args.has("data") and not GameData.has_data():
		printerr("[server] ERROR: --data=%s has no manifest.json. Point --data at the game-data folder made from your own disc (the one holding manifest.json), or leave --data out to host the built-in arena only." % args["data"])
		get_tree().quit(2)
		return
	select_providers()
	if not is_server:
		audio_provider = _make_audio()
		apply_display_settings()
	if args.has("exit-after"):
		get_tree().create_timer(float(args["exit-after"])).timeout.connect(func():
			print("[game] exit-after reached, quitting")
			get_tree().quit())
	if is_server:
		Engine.max_fps = 120
		get_tree().change_scene_to_file.call_deferred(SERVER_SCENE)
	elif args.has("connect"):
		Net.auto_start.call_deferred()
	elif args.has("host"):
		Net.auto_host.call_deferred()

## Web test automation: page URL query keys become args, e.g.
## https://host:8443/?name=W1&lobby=T&autostart=1&arena=test_yard&time-limit=20&autodrive
## (the page connects, joins or creates lobby T, readies, and the host starts once autostart
## players are in). Only these keys; they affect this browser's own client only.
const WEB_ARG_KEYS := ["name", "lobby", "autostart", "bots", "arena", "time-limit", "score-limit", "autodrive", "netstats", "vehicle"]

func _web_args() -> void:
	var q := str(JavaScriptBridge.eval("location.search", true)).trim_prefix("?")
	for part in q.split("&", false):
		var kv := part.split("=", true, 1)
		var k := kv[0].uri_decode()
		if k in WEB_ARG_KEYS:
			args[k] = kv[1].uri_decode().left(64) if kv.size() > 1 else "1"

## Picks the arena and vehicle providers for the current game-data folder. Call again after
## the folder changes.
func select_providers() -> void:
	DiscFilesS.reader = GameData.read_bytes
	DiscManifestS.load_manifest(true)
	DiscArena.clear_cache()
	_collision_cache.clear()
	disc_models = null
	if has_disc_data():
		arena_provider = DiscArena.new(str(args.get("arena", "")))   # e.g. "WH/part1"
		if DiscCars.is_available():
			disc_models = DiscCars.new()
			vehicle_provider = disc_models
		else:
			vehicle_provider = builtin_models
	else:
		arena_provider = ProceduralArena.new()
		vehicle_provider = builtin_models
	if is_server:
		print("[game] game data: %s" % (("%s (%d arenas, %d vehicles)" % [GameData.root(), disc_arena_ids().size(), disc_vehicle_ids().size()]) if has_disc_data() else "none (built-in arena only)"))

func has_disc_data() -> bool:
	return GameData.has_data() and DiscArena.is_available() and not args.has("no-disc-models")

func disc_arena_ids() -> PackedStringArray:
	return DiscArena.arena_ids() if has_disc_data() else PackedStringArray()

## Arena ids this machine can build: every arena in the game data first, then the built-in
## test yard (last, so lists and defaults lead with the disc's own arenas).
func local_arena_ids() -> Array:
	var out: Array = Array(disc_arena_ids())
	out.append(TEST_YARD)
	return out

## Vehicle ids from the game data (manifest keys, in select order) that also have measured
## numbers in the shipped tuning, so the server and every client simulate them the same way.
func disc_vehicle_ids() -> PackedStringArray:
	var out := PackedStringArray()
	if disc_models == null:
		return out
	var man = DiscManifestS.load_manifest()
	if man == null:
		return out
	for id in man.vehicle_names():
		if profiles.disc.has(id):
			out.append(id)
	return out

func builtin_vehicle_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for p in profiles.builtin:
		out.append(p.id)
	return out

func is_builtin_vid(vid: String) -> bool:
	return vid.begins_with("builtin_")

## Vehicles this machine can show and simulate: the game-data ones when present, else the
## eight built-in stand-ins.
func local_vehicle_ids() -> PackedStringArray:
	var d := disc_vehicle_ids()
	return d if not d.is_empty() else builtin_vehicle_ids()

func profile_for(vid: String) -> VehicleProfile:
	if profiles.disc.has(vid):
		return profiles.disc[vid]
	return profiles.builtin[_builtin_index(vid)]

func _builtin_index(vid: String) -> int:
	if is_builtin_vid(vid):
		return clampi(int(vid.trim_prefix("builtin_")) - 1, 0, profiles.builtin.size() - 1)
	return posmod(hash(vid), profiles.builtin.size())

func vehicle_name(vid: String) -> String:
	if is_builtin_vid(vid):
		return profile_for(vid).display_name
	return vid.capitalize()

## True when the model of this vehicle comes from the player's own game data.
func has_disc_model(vid: String) -> bool:
	return disc_models != null and not is_builtin_vid(vid) and vid in disc_vehicle_ids()

func build_vehicle_model(vid: String, color: Color) -> Node3D:
	if has_disc_model(vid):
		var root: Node3D = DiscCars.build_model_by_object_id(_disc_object_id(vid))
		root.set_meta("player_color", color)
		return root
	return builtin_models.build_model(_builtin_index(vid), color)

func _disc_object_id(vid: String) -> int:
	var man = DiscManifestS.load_manifest()
	if man != null:
		var e: Dictionary = man.data.get("vehicles", {}).get(vid, {})
		if e.has("object_id"):
			return int(e.object_id)
	return int(DiscCars.OBJECT_IDS.get(vid, 0))

## Collision of a vehicle body: {"shapes": [[Shape3D, Transform3D in body space], ...],
## "half_extents": Vector3 (hitscan box), "kind"}. Built-in vehicles keep the capsule.
## Game-data vehicles (default "hull"): a capsule sized to the car carries it on the ground,
## and the car's convex hull, cut off 0.5 m above the ground, gives the body its real shape
## against walls and other cars. A flat-bottomed hull or box touching the floor catches on the
## seams between floor triangles differently on the server and in client prediction (which
## restarts from millimetre-rounded states): measured 0.08 m (hull) and 0.47 m (box) average
## prediction error against 0.04 m for the capsule. --vehicle-collision=box|flat|capsule
## selects the alternatives (box = box fitted to the hull's bounds on the same capsule; flat =
## the whole hull with a chamfered underside). The server and every client build the same
## shapes from their own game data, so prediction matches.
func vehicle_collision(vid: String) -> Dictionary:
	var mode := str(args.get("vehicle-collision", "hull"))
	var key := "%s|%s" % [vid, mode]
	if _collision_cache.has(key):
		return _collision_cache[key]
	var out := {}
	var col: Array = []
	if mode != "capsule" and has_disc_model(vid):
		col = DiscCars.collision_by_object_id(_disc_object_id(vid))
	var cap_xf := Transform3D(Basis.from_euler(Vector3(PI / 2, 0, 0)), Vector3.ZERO)
	if col.is_empty():
		var cap := CapsuleShape3D.new()
		cap.radius = BODY_RADIUS
		cap.height = 3.8
		out = {"shapes": [[cap, cap_xf]], "half_extents": Vector3(0.95, 0.55, 1.9), "kind": "capsule"}
	else:
		var hull: ConvexPolygonShape3D = col[0]
		var size: Vector3 = col[1]
		var shapes: Array = []
		var body_xf := Transform3D(Basis.IDENTITY, Vector3(0, -BODY_RADIUS, 0))
		if mode == "flat":
			var flat := ConvexPolygonShape3D.new()
			flat.points = _chamfer(hull.points, size)
			shapes.append([flat, body_xf])
		else:
			var cap2 := CapsuleShape3D.new()
			cap2.radius = BODY_RADIUS
			cap2.height = clampf(size.z - 0.3, 2.4, 4.2)
			shapes.append([cap2, cap_xf])
			var upper := ConvexPolygonShape3D.new()
			upper.points = _raise(hull.points if mode == "hull" else _box_points(size), UPPER_CLEAR)
			shapes.append([upper, body_xf])
		out = {"shapes": shapes, "half_extents": Vector3(size.x * 0.5, maxf(size.y * 0.5, 0.55), size.z * 0.5), "kind": mode}
	_collision_cache[key] = out
	return out

const UPPER_CLEAR := 0.5   # the hull part starts this far above the ground

static func _raise(pts: PackedVector3Array, y0: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p in pts:
		out.append(Vector3(p.x, maxf(p.y, y0), p.z))
	return out

static func _box_points(size: Vector3) -> PackedVector3Array:
	var h := Vector3(size.x * 0.5, 0, size.z * 0.5)
	var out := PackedVector3Array()
	for x in [-h.x, h.x]:
		for y in [0.0, size.y]:
			for z in [-h.z, h.z]:
				out.append(Vector3(x, y, z))
	return out

## Lifts every point below CLEAR to CLEAR, then adds a smaller flat underside, so the front and
## back slope up from the ground (about 30 degrees) like a sled and the body slides up small
## steps and seams instead of catching on them.
static func _chamfer(pts: PackedVector3Array, size: Vector3) -> PackedVector3Array:
	const CLEAR := 0.3
	const RAMP := 0.55
	var out := PackedVector3Array()
	for p in pts:
		out.append(Vector3(p.x, maxf(p.y, CLEAR), p.z))
	var hx := maxf(size.x * 0.5 - 0.15, 0.3)
	var hz := maxf(size.z * 0.5 - RAMP, 0.4)
	for x in [-hx, hx]:
		for z in [-hz, hz]:
			out.append(Vector3(x, 0.0, z))
	return out

## Arena provider for a match: the built-in yard, or an arena from this machine's own game
## data. Null when the arena is not available here. The server builds collision only.
func make_arena_provider(arena_id: String) -> ArenaProvider:
	if arena_id == "" or arena_id == TEST_YARD:
		return ProceduralArena.new()
	if not (arena_id in disc_arena_ids()):
		return null
	var p = DiscArena.new(arena_id)
	p.collision_only = is_server
	return p

func arena_label(arena_id: String) -> String:
	if arena_id == TEST_YARD or arena_id == "":
		return "Test Yard (built-in, for testing)"
	var kv := arena_id.split("/")
	if kv.size() == 2:
		return "%s  %s" % [kv[0].capitalize(), kv[1].replace("part", "part ")]
	return arena_id

func _make_audio() -> AudioProvider:
	if GameData.has_data() and GameData.use_disc_audio() and not args.has("no-disc-audio"):
		var d := DiscAudio.new()
		if d.is_usable():
			return d
	return ProceduralAudio.new()

func reload_audio() -> void:
	audio_provider = _make_audio()

func _load_profile() -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	player_name = str(c.get_value("player", "name", player_name))
	player_color = c.get_value("player", "color", player_color)
	player_vid = str(c.get_value("player", "vehicle", player_vid))
	server_addr = str(c.get_value("player", "server", server_addr))

func has_saved_name() -> bool:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return c.has_section_key("player", "name")

func save_profile() -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value("player", "name", player_name)
	c.set_value("player", "color", player_color)
	c.set_value("player", "vehicle", player_vid)
	c.set_value("player", "server", server_addr)
	c.save("user://settings.cfg")

# ---------------- display settings ----------------
const RESOLUTIONS := [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)]
const RENDER_SCALES := [0.5, 0.67, 0.75, 0.85, 1.0]

func display_setting(key: String, default):
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return c.get_value("display", key, default)

func set_display_setting(key: String, value) -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value("display", key, value)
	c.save("user://settings.cfg")

## Window size, fullscreen and 3D render scale from user://settings.cfg [display].
func apply_display_settings() -> void:
	var scale := float(display_setting("render_scale", 1.0))
	get_tree().root.scaling_3d_scale = clampf(scale, 0.25, 2.0)
	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		return
	var fs := bool(display_setting("fullscreen", false))
	var res: Vector2i = display_setting("resolution", Vector2i(1280, 720))
	if fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var screen := DisplayServer.screen_get_usable_rect()
		var sz := Vector2i(mini(res.x, screen.size.x), mini(res.y, screen.size.y))
		DisplayServer.window_set_size(sz)
		DisplayServer.window_set_position(screen.position + (screen.size - sz) / 2)

# Fallback so the game works even if project.godot lacks an action.
func _ensure_actions() -> void:
	for action in ACTION_KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = ACTION_KEYS[action]
			InputMap.action_add_event(action, ev)

func play_sfx(sfx_name: String, pos: Vector3, vol_db := 0.0) -> void:
	if sfx != null and is_instance_valid(sfx):
		sfx.play(sfx_name, pos, vol_db)
