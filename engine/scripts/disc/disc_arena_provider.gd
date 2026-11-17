class_name DiscArenaProvider
extends ArenaProvider
## Arena from the player's own game data (manifest "arenas"), built at run time.
## arena_id is "<LEVEL>/<part>", e.g. "WH/part1"; empty = the first arena in the manifest.
##
## Node layout: root (meta spawn_points, pickup_points, disc_arena_id, disc_stats)
##   Level (Node3D, offset so the main floor is at y = 0 and the arena is centred on x/z)
##     Mesh (MeshInstance3D, objects 1 and 3 = level + Arena floor)
##     Body (StaticBody3D, layer 1) / Shape (ConcavePolygonShape3D of every non-sprite polygon)
##     Props (DiscProps: switch states, animations, destructible targets with their own bodies)
##   Sky (MeshInstance3D, object 2, when present: follows the camera, drawn behind everything)
## Meta on root: "props" (the DiscProps node), "pickup_gates" (per pickup: the target whose
## destruction reveals it, or -1).
## Built resources are cached per arena and upscale setting, so later matches are instant.

const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")
const DiscManifestScript := preload("res://scripts/disc/manifest.gd")
const DiscDmdScript := preload("res://scripts/disc/dmd.gd")
const DiscVramScript := preload("res://scripts/disc/vram.gd")
const DiscAtlasScript := preload("res://scripts/disc/atlas.gd")
const DiscMeshBuilderScript := preload("res://scripts/disc/mesh_builder.gd")
const DiscSpawnSamplerScript := preload("res://scripts/disc/spawn_sampler.gd")
const DiscSettingsScript := preload("res://scripts/disc/disc_settings.gd")
const SkyFollowScript := preload("res://scripts/disc/sky_follow.gd")
const DiscPropsScript := preload("res://scripts/disc/disc_props.gd")
const Ps1LookScript := preload("res://scripts/render/ps1_look.gd")
const DiscFxScript := preload("res://scripts/render/disc_fx.gd")

var arena_id := ""
var last_stats := {}
## Server: build the collision, spawns and pickups only (no textures or meshes).
var collision_only := false

const MAX_PICKUPS := 32   # the snapshot carries one bit per pickup
## Decoded pickup labels -> this game's pickup kinds. Rear missile, rear flame and oil are not
## implemented, so they stand in as the nearest kind; the unlabelled icons give a random
## weapon ("random", decided by the server when taken).
const PICKUP_KIND := {"fire": "fire", "homing": "homing", "freeze": "freeze", "power": "power",
	"rear": "fire", "rear_flame": "fire", "oil": "mine", "mine": "mine", "health": "health",
	"icon_disc": "random", "icon_ring": "random"}
## Pickup node tags in the level model (README "Pickups"): used for the pickups that sit inside
## the wreck states of destructible props.
const PICKUP_TAG_KIND := {0x191: "fire", 0x192: "freeze", 0x193: "homing", 0x194: "power", 0x195: "rear",
	0x19B: "rear_flame", 0x19D: "oil", 0x19A: "icon_disc", 0x19C: "icon_disc", 0x19E: "icon_disc", 0x1AE: "icon_disc"}
const GROUND_SIZE := 4000.0   # metres: flat ground and collision floor at DMD z = 0
const MIN_OPEN_PICKUPS := 6   # pickups available from the start (not inside a wreck), at least
const FILL_KINDS := ["health", "fire", "homing", "mine", "power", "freeze"]

static var _cache := {}   # "<manifest>|<arena>|x<scale>" -> Dictionary of built resources

func _init(id := "") -> void:
	arena_id = id

## True when the game data folder has a manifest with at least one arena.
static func is_available() -> bool:
	var man = DiscManifestScript.load_manifest()
	return man != null and not man.arena_ids().is_empty()

static func arena_ids() -> PackedStringArray:
	var man = DiscManifestScript.load_manifest()
	return man.arena_ids() if man != null else PackedStringArray()

static func clear_cache() -> void:
	_cache.clear()

func _resolved_id() -> String:
	if arena_id != "":
		return arena_id
	var ids := arena_ids()
	return ids[0] if not ids.is_empty() else ""

func get_arena_name() -> String:
	return _resolved_id().replace("/part", " ")

func build_arena() -> Node3D:
	var id := _resolved_id()
	var res := _get_resources(id)
	var root := Node3D.new()
	root.name = "DiscArena"
	root.set_meta("disc_arena_id", id)
	root.set_meta("disc_stats", res.get("stats", {}))
	last_stats = res.get("stats", {})
	if res.is_empty() or not res.has("shape"):
		push_warning("[disc] arena %s could not be loaded" % id)
		root.set_meta("spawn_points", [])
		root.set_meta("pickup_points", [])
		root.set_meta("pickup_gates", [])
		return root
	var level := Node3D.new()
	level.name = "Level"
	level.position = res.offset
	root.set_meta("game_offset", res.offset)   # game position * WORLD_UNIT_M (Godot axes) + this = arena space
	root.add_child(level)
	var level_name: String = id.split("/")[0]
	var bg: Color = DiscDmdScript.BACKGROUND.get(level_name, Color(0.2, 0.2, 0.2))
	root.set_meta("background", bg)
	if not collision_only:
		var man_fx = DiscManifestScript.load_manifest()
		if man_fx != null:
			# effect frames (explosions, smoke, sparks) from this arena's own texture file
			DiscFxScript.load_from_tms(DiscFilesScript.read_bytes(man_fx.arena_textures(id)), man_fx.checksum + "|" + id)
	var look := Node.new()
	look.name = "Ps1Look"
	look.set_script(Ps1LookScript)
	root.add_child(look)
	if res.mesh != null:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = res.mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		level.add_child(mi)
		# The game clears the screen to a per-arena colour that shows wherever no polygon
		# is drawn (the centres of SUBURB and XFWY): a flat plane in that colour at z = 0.
		var ground := MeshInstance3D.new()
		ground.name = "Ground"
		ground.mesh = DiscMeshBuilderScript.flat_quad(GROUND_SIZE, bg)
		ground.position.y = -0.03
		# Hidden: the camera's clear colour (match.gd sets it from meta "background") already
		# fills every pixel no polygon covers, exactly like the PS1; a drawn plane fought the
		# floor for depth once vertices are snapped. Kept for code that looks it up by name.
		ground.visible = false
		ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		level.add_child(ground)
		if not res.split_meshes.is_empty():
			var sw := SplitSwitch.new()
			sw.name = "Splits"
			level.add_child(sw)
			for e in res.split_meshes:
				var pair := []
				for side in 2:
					var smi := MeshInstance3D.new()
					smi.mesh = e[1 + side]
					smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					smi.visible = side == 0
					sw.add_child(smi)
					pair.append(smi)
				sw.entries.append([e[0], pair[0], pair[1]])
	if res.sky_mesh != null:
		var sky := MeshInstance3D.new()
		sky.name = "Sky"
		sky.mesh = res.sky_mesh
		sky.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sky.extra_cull_margin = 16384.0
		sky.set_script(SkyFollowScript)
		sky.set("ground_y", res.offset.y)
		root.add_child(sky)
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = res.shape
	body.add_child(cs)
	# Cars drive on z = 0 where the model has no polygon (SUBURB's centre lot): a flat floor.
	var fcs := CollisionShape3D.new()
	fcs.name = "Floor"
	var fb := BoxShape3D.new()
	fb.size = Vector3(GROUND_SIZE, 2.0, GROUND_SIZE)
	fcs.shape = fb
	fcs.position.y = -1.0
	body.add_child(fcs)
	level.add_child(body)
	var props := DiscPropsScript.new()
	props.name = "Props"
	level.add_child(props)
	props.setup(res.props, res.mesh != null)
	root.set_meta("props", props)
	root.set_meta("spawn_points", res.spawns.duplicate())
	root.set_meta("pickup_points", res.pickups.duplicate())
	root.set_meta("pickup_types", res.pickup_types.duplicate())
	root.set_meta("pickup_gates", res.pickup_gates.duplicate())
	return root

func _get_resources(id: String) -> Dictionary:
	var man = DiscManifestScript.load_manifest()
	if man == null or id == "":
		return {}
	var scale := DiscSettingsScript.texture_upscale()
	var ck := "%s|%s|%s" % [man.checksum, id, "collision" if collision_only else "x%d" % scale]
	if _cache.has(ck):
		return _cache[ck]
	var st := {}
	var t0 := Time.get_ticks_usec()
	var dmd = DiscDmdScript.from_bytes(DiscFilesScript.read_bytes(man.arena_model(id)))
	if dmd == null:
		return {}
	var objs: Array = dmd.objects()
	var level: Array = DiscDmdScript.meshes_of(objs, DiscDmdScript.LEVEL_IDS)
	var pd: Dictionary = DiscPropsScript.analyse(objs, PICKUP_TAG_KIND)
	var hidden_pickups: Array = pd.hidden_pickups
	var sky: Array = DiscDmdScript.meshes_of(objs, [DiscDmdScript.SKY_ID])
	var t1 := Time.get_ticks_usec()
	var atlas = null
	if not collision_only:
		var vram = DiscVramScript.new()
		vram.load_tms(DiscFilesScript.read_bytes(man.arena_textures(id)))
		atlas = DiscAtlasScript.build(pd.all + sky, vram, "arena_" + id.replace("/", "_"), scale, man.checksum)
	var t2 := Time.get_ticks_usec()
	var unit := DiscMeshBuilderScript.WORLD_UNIT_M
	var scale_xf := Transform3D(Basis.from_scale(Vector3.ONE * unit), Vector3.ZERO)
	# every default polygon (spawn sampling, as before); the arena body leaves out destructible
	# targets, which get their own bodies (DiscProps)
	var faces: PackedVector3Array = DiscMeshBuilderScript.collision_faces(level, scale_xf)
	var base_faces: PackedVector3Array = DiscMeshBuilderScript.collision_faces(pd.base_collision, scale_xf)
	var t3 := Time.get_ticks_usec()
	var side_bytes := DiscFilesScript.read_side_data("arenas/%s.json" % id.split("/")[0], man.data)
	var side = JSON.parse_string(side_bytes.get_string_from_utf8()) if not side_bytes.is_empty() else null
	var placed: Dictionary = _place(faces, side if typeof(side) == TYPE_DICTIONARY else {}, unit, hidden_pickups)
	var t4 := Time.get_ticks_usec()
	var box: AABB = DiscMeshBuilderScript.bounds(level)
	var c := box.get_center() * unit
	var offset := Vector3(-c.x, -float(placed.floor_y), -c.z)
	var res := {}
	res.offset = offset
	res.mesh = null
	res.split_meshes = []
	if atlas != null:
		# Spatial splits (ROOF): meshes under a split are drawn per side, switched by camera.
		var base: Array = []
		var groups := {}   # split offset -> [DmdSplit, outside meshes, inside meshes]
		var split_of := {}
		for o in objs:
			if o.id in DiscDmdScript.LEVEL_IDS:
				for sp in o.splits:
					split_of[sp.offset] = sp
		for m in pd.base_visual:
			if m.split_node >= 0 and split_of.has(m.split_node):
				var g: Array = groups.get_or_add(m.split_node, [split_of[m.split_node], [], []])
				g[1 + clampi(m.split_side, 0, 1)].append(m)
			else:
				base.append(m)
		res.mesh = DiscMeshBuilderScript.build_mesh(base, atlas, scale_xf)
		for k in groups:
			var g2: Array = groups[k]
			res.split_meshes.append([g2[0], DiscMeshBuilderScript.build_mesh(g2[1], atlas, scale_xf), DiscMeshBuilderScript.build_mesh(g2[2], atlas, scale_xf)])
		st.splits = groups.size()
	res.sky_mesh = null
	if not sky.is_empty() and atlas != null:
		# In game units around its own origin: the game places the sky object at the player's
		# x, y with z = 0 every frame (placed-object record 1); DiscSkyFollow does the same.
		var sky_xf := Transform3D(Basis.from_scale(Vector3.ONE * unit), Vector3.ZERO)
		res.sky_mesh = DiscMeshBuilderScript.build_mesh(sky, atlas, sky_xf, true)
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(base_faces)
	res.shape = shape
	DiscPropsScript.build_resources(pd, atlas, scale_xf)
	res.props = pd
	var t5 := Time.get_ticks_usec()
	var spawns: Array = []
	for xf in placed.spawns:
		spawns.append(Transform3D(xf.basis, xf.origin + offset))
	var pickups: Array = []
	var pickup_types: Array = []
	var pickup_gates: Array = []
	for i in mini(placed.pickups.size(), MAX_PICKUPS):
		pickups.append(placed.pickups[i] + offset)
		var kind := str(placed.pickup_types[i]) if i < placed.pickup_types.size() else ""
		pickup_types.append(PICKUP_KIND.get(kind, FILL_KINDS[i % FILL_KINDS.size()]))
		pickup_gates.append(placed.pickup_gates[i])
	if spawns.size() < 8:
		push_warning("[disc] %s: only %d spawn points found, adding a ring" % [id, spawns.size()])
		for k in range(spawns.size(), 8):
			var a := TAU * k / 8.0
			var pos := Vector3(cos(a), 0, sin(a)) * minf(box.size.x, box.size.z) * unit * 0.3 + Vector3(0, 1.0, 0)
			spawns.append(Transform3D(Basis.looking_at(-pos * Vector3(1, 0, 1), Vector3.UP), pos))
	if pickups.is_empty():
		for xf in spawns:
			pickups.append(xf.origin * 0.5)
			pickup_types.append(FILL_KINDS[pickup_types.size() % FILL_KINDS.size()])
			pickup_gates.append(-1)
	res.spawns = spawns
	res.pickups = pickups
	res.pickup_types = pickup_types
	res.pickup_gates = pickup_gates
	st.spawn_source = placed.source
	st.hidden_pickups = hidden_pickups.size()
	st.targets = pd.targets.size()
	st.switches = pd.switches.size()
	st.animations = pd.anims.size()
	st.pickups_from_data = placed.data_pickups
	var polys := 0
	for m in level:
		polys += m.polygons.size()
	st.polygons = polys
	st.triangles = faces.size() / 3
	st.size_m = box.size * unit
	st.parse_ms = (t1 - t0) / 1000.0
	st.atlas_ms = (t2 - t1) / 1000.0
	if atlas != null:
		st.atlas = atlas.describe()
		st.atlas_decode_ms = atlas.stats.decode_ms
		st.upscale_ms = atlas.stats.upscale_ms
		st.atlas_cached = atlas.stats.cached > 0 and atlas.stats.built == 0
	st.spawn_ms = (t4 - t3) / 1000.0
	st.spawn_samples = placed.samples
	st.mesh_ms = (t5 - t4 + t3 - t2) / 1000.0
	st.total_ms = (Time.get_ticks_usec() - t0) / 1000.0
	res.stats = st
	_cache[ck] = res
	return res

## Spawn and pickup points in metres (before the arena offset), plus the floor height to put
## at y = 0. With decoded data (data/arenas/<LEVEL>.json): the player and enemy starts with
## their headings, 6 more spawns spread around and between them on the same floor, and the
## decoded pickups (topped up to 8 with floor points). Without it: points spread over the
## largest open floor patch.
func _place(faces: PackedVector3Array, side: Dictionary, unit: float, hidden: Array = []) -> Dictionary:
	var fs = DiscSpawnSamplerScript.new(faces)
	var out := {"spawns": [], "pickups": [], "pickup_types": [], "pickup_gates": [], "floor_y": fs.main_floor_y, "samples": 0, "source": "sampled", "data_pickups": 0}
	var starts: Array = []   # [position on the ground, forward]
	var sp: Dictionary = side.get("spawns", {})
	for who in ["player", "enemy"]:
		if not sp.has(who):
			continue
		var e: Dictionary = sp[who]
		var x := float(e.get("x", 0)) * unit
		var z := -float(e.get("y", 0)) * unit
		var g: float = fs.ground_at(x, z)
		if is_nan(g):
			g = fs.main_floor_y
		var h := float(e.get("heading", 0)) / 4096.0 * TAU
		starts.append([Vector3(x, g, z), Vector3(sin(h), 0, -cos(h))])   # game forward (sin h, cos h)
	var pts: Array
	if starts.size() == 2:
		out.source = "decoded starts + generated"
		out.floor_y = starts[0][0].y
		var a: Vector3 = starts[0][0]
		var b: Vector3 = starts[1][0]
		var r := maxf(a.distance_to(b) * 0.6, 20.0)
		var area := Rect2(Vector2(minf(a.x, b.x), minf(a.z, b.z)) - Vector2(r, r), Vector2(absf(a.x - b.x), absf(a.z - b.z)) + Vector2(r, r) * 2)
		pts = fs.floor_points([a.y, b.y], area)
		pts = pts.filter(func(p): return _dist_to_segment(p, a, b) < r and p.distance_to(a) > 6.0 and p.distance_to(b) > 6.0)
		var mid := (a + b) * 0.5
		for s in starts:
			out.spawns.append(Transform3D(Basis.looking_at(s[1], Vector3.UP), s[0] + Vector3(0, 1.0, 0)))
		for p in DiscSpawnSamplerScript.farthest_points(pts, [a, b], 6):
			var d: Vector3 = (mid - p) * Vector3(1, 0, 1)
			if d.length() < 0.01:
				d = Vector3.FORWARD
			out.spawns.append(Transform3D(Basis.looking_at(d.normalized(), Vector3.UP), p + Vector3(0, 1.0, 0)))
	else:
		pts = DiscSpawnSamplerScript.largest_patch(fs.floor_points([fs.main_floor_y]))
		var centre := Vector3.ZERO
		for p in pts:
			centre += p
		if not pts.is_empty():
			centre /= pts.size()
		for p in DiscSpawnSamplerScript.farthest_points(pts, [], 8):
			var d: Vector3 = (centre - p) * Vector3(1, 0, 1)
			if d.length() < 0.01:
				d = Vector3.FORWARD
			out.spawns.append(Transform3D(Basis.looking_at(d.normalized(), Vector3.UP), p + Vector3(0, 1.0, 0)))
	out.samples = pts.size()
	for e in side.get("pickups", []):
		out.pickups.append(Vector3(float(e.get("x", 0)), float(e.get("z", 0)), -float(e.get("y", 0))) * unit + Vector3(0, 0.5, 0))
		out.pickup_types.append(str(e.get("type", "")))
		out.pickup_gates.append(-1)
	var open: int = out.pickups.size()
	var n_data: int = open
	# pickups inside the wreck states of destructible props: they appear when the prop is
	# destroyed (gate = target index in DiscProps)
	for h in hidden:
		out.pickups.append(DiscMeshBuilderScript.to_godot(h[0]) * unit + Vector3(0, 0.3, 0))
		out.pickup_types.append(h[1])
		out.pickup_gates.append(h[2])
		if h[2] < 0:
			open += 1
	# the snapshot carries MAX_PICKUPS bits: drop open pickups from the end of the decoded list
	# rather than the ones inside props (SUBURB has 29 + 5)
	var k := n_data - 1
	while out.pickups.size() > MAX_PICKUPS and k >= 0:
		if out.pickup_gates[k] < 0:
			out.pickups.remove_at(k)
			out.pickup_types.remove_at(k)
			out.pickup_gates.remove_at(k)
			open -= 1
		k -= 1
	out.data_pickups = out.pickups.size()
	# top up with floor points: at least 8 in all and MIN_OPEN_PICKUPS available from the start
	# (ROOF has one open pickup; its other 17 are inside props)
	var need: int = maxi(8 - out.pickups.size(), MIN_OPEN_PICKUPS - open)
	if need > 0:
		var seeds: Array = out.pickups.duplicate()
		for xf in out.spawns:
			seeds.append(xf.origin - Vector3(0, 1.0, 0))
		for p in DiscSpawnSamplerScript.farthest_points(pts, seeds, need):
			out.pickups.append(p + Vector3(0, 1.0, 0))
			out.pickup_gates.append(-1)
	return out

static func _dist_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Shows the inside or outside version of each spatial split, as the game does, from the
## camera position (converted back to disc world units).
class SplitSwitch extends Node3D:
	var entries: Array = []   # [DmdSplit, outside MeshInstance3D, inside MeshInstance3D]
	func _process(_d: float) -> void:
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return
		var p: Vector3 = (get_parent() as Node3D).global_transform.affine_inverse() * cam.global_position
		var u: float = 1.0 / DiscMeshBuilderScript.WORLD_UNIT_M
		var w := Vector3(p.x, -p.z, p.y) * u
		for e in entries:
			var inside: bool = e[0].contains(w)
			e[1].visible = not inside
			e[2].visible = inside
