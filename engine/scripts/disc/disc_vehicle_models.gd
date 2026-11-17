class_name DiscVehicleModels
extends VehicleModelProvider
## Vehicle visuals from the player's own game data. The in-game models live inside the arena
## files by object id (models.dmd / CARS.DMD holds the same cars ~30x larger, for menus), so a
## vehicle is loaded from the first arena part (in manifest order, XARENA/part1 first) that
## contains its object id, with that part's textures, at the arena scale.
## Index = the manifest's select_order; get_disc_id() returns the manifest key (ICE, CAB, ...),
## which is also the tuning.json key. Object ids come from manifest vehicles.<ID>.object_id,
## else the table below (README "Vehicle object ids"; matches renders of each object).
## Only meshes with a non-zero bounding radius are drawn: each car also holds one or two
## zero-radius meshes far outside the body (cockpit/HUD-like parts).
##
## build_model() root (script disc_vehicle_visual.gd): MeshInstance3D "Body" plus, when the car
## has a body switch (slot 0, README "Switch nodes": intact / damaged / wrecked), "D0".."D2" with
## the hull of each state and its wheel frames (switches id + 2, merged per frame). Origin on the
## ground (lowest point of the default state), centred on x/z, front towards -Z. Meta:
## "collision_shape" (ConvexPolygonShape3D, same space), "disc_object_id", "size_m",
## "disc_source" (arena part it came from).

const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")
const DiscManifestScript := preload("res://scripts/disc/manifest.gd")
const DiscDmdScript := preload("res://scripts/disc/dmd.gd")
const DiscVramScript := preload("res://scripts/disc/vram.gd")
const DiscAtlasScript := preload("res://scripts/disc/atlas.gd")
const DiscMeshBuilderScript := preload("res://scripts/disc/mesh_builder.gd")
const DiscSettingsScript := preload("res://scripts/disc/disc_settings.gd")
const DiscVehicleVisualScript := preload("res://scripts/disc/disc_vehicle_visual.gd")

const OBJECT_IDS := {
	"ICE": 0x0A, "CAB": 0x14, "SEMI": 0x1E, "MONSTERT": 0x28, "COP": 0x32, "LAMBO": 0x3C,
	"HUMVEE": 0x46, "HARLEY": 0x50, "DUNEB": 0x5A, "LOWRIDER": 0x64, "VETTE": 0x6E, "MADMAX": 0x78,
}

static var _key := ""          # manifest checksum | scale the caches below belong to
static var _parts := {}        # arena part id -> {"objects": {id: DmdObject}, "atlas": DiscAtlas}
static var _built := {}        # object id -> [ArrayMesh, ConvexPolygonShape3D, size_m, part id, parts]
static var last_stats := {}

static func is_available() -> bool:
	var man = DiscManifestScript.load_manifest()
	return man != null and not man.arena_ids().is_empty() and not man.vehicle_names().is_empty()

func _names() -> PackedStringArray:
	var man = DiscManifestScript.load_manifest()
	return man.vehicle_names() if man != null else PackedStringArray()

func get_model_count() -> int:
	return _names().size()

func get_model_name(index: int) -> String:
	var n := _names()
	return n[posmod(index, n.size())].capitalize() if not n.is_empty() else "Vehicle"

func get_disc_id(index: int) -> String:
	var n := _names()
	return n[posmod(index, n.size())] if not n.is_empty() else ""

func object_id(index: int) -> int:
	var name := get_disc_id(index)
	var man = DiscManifestScript.load_manifest()
	if man != null:
		var e: Dictionary = man.data.get("vehicles", {}).get(name, {})
		if e.has("object_id"):
			return int(e.object_id)
	return int(OBJECT_IDS.get(name, 0))

func build_model(index: int, color: Color) -> Node3D:
	var root := build_model_by_object_id(object_id(index))
	root.set_meta("player_color", color)
	return root

static func _reset_if_stale(man) -> void:
	var key := "%s|%d" % [man.checksum, DiscSettingsScript.texture_upscale()]
	if key != _key:
		_parts.clear()
		_built.clear()
		_key = key

## Parses one arena part and builds an atlas of its vehicles. Returns the part entry.
static func _load_part(man, part: String) -> Dictionary:
	if _parts.has(part):
		return _parts[part]
	var t0 := Time.get_ticks_usec()
	var entry := {"objects": {}, "atlas": null}
	var dmd = DiscDmdScript.from_bytes(DiscFilesScript.read_bytes(man.arena_model(part)))
	if dmd != null:
		var drawn: Array = []
		for o in dmd.objects():
			if o.id in OBJECT_IDS.values() and not entry.objects.has(o.id) and not _body_meshes(o).is_empty():
				entry.objects[o.id] = o
				drawn.append_array(_all_meshes(o))   # every damage state and wheel frame
		var t1 := Time.get_ticks_usec()
		var vram = DiscVramScript.new()
		vram.load_tms(DiscFilesScript.read_bytes(man.arena_textures(part)))
		entry.atlas = DiscAtlasScript.build(drawn, vram, "vehicles_" + part.replace("/", "_"), DiscSettingsScript.texture_upscale(), man.checksum)
		last_stats[part] = {"parse_ms": (t1 - t0) / 1000.0, "atlas_ms": (Time.get_ticks_usec() - t1) / 1000.0,
			"atlas": entry.atlas.describe(), "upscale_ms": entry.atlas.stats.upscale_ms, "vehicles": entry.objects.size()}
	_parts[part] = entry
	return entry

static func _body_meshes(o) -> Array:
	return o.meshes.filter(func(m): return m.radius > 0 and not m.polygons.is_empty())

static func _drawn(m) -> bool:
	return m.radius > 0 and not m.polygons.is_empty()

## Default meshes plus those of every switch state (filtered like _body_meshes).
static func _all_meshes(o) -> Array:
	var seen := {}
	var out: Array = []
	for m in o.meshes:
		seen[m] = true
		if _drawn(m):
			out.append(m)
	for sw in o.switches:
		for st in sw.states:
			for m in st:
				if not seen.has(m):
					seen[m] = true
					if _drawn(m):
						out.append(m)
	return out

## Splits a vehicle into {"base": meshes outside the body switch, "body": per body state its own
## meshes, "wheels": per body state, per wheel frame, the meshes of its wheel switches}; empty
## when the car has no body switch (slot 0, no parent, 2+ states).
static func _damage_parts(o) -> Dictionary:
	var body_si := -1
	for si in o.switches.size():
		var sw = o.switches[si]
		if sw.parent.is_empty() and sw.slot == 0 and sw.count >= 2:
			body_si = si
			break
	if body_si < 0:
		return {}
	var depth := PackedInt32Array()
	for sw in o.switches:
		depth.append(0 if sw.parent.is_empty() else depth[sw.parent[0]] + 1)
	var cont := {}   # mesh -> [switch index, state, depth] of its innermost switch
	for si in o.switches.size():
		var sw = o.switches[si]
		for k in sw.states.size():
			for m in sw.states[k]:
				if not cont.has(m) or cont[m][2] < depth[si]:
					cont[m] = [si, k, depth[si]]
	var nb: int = o.switches[body_si].count
	var out := {"base": [], "body": [], "wheels": []}
	for k in nb:
		out.body.append([])
		out.wheels.append([])
	for m in _all_meshes(o):
		if not cont.has(m):
			out.base.append(m)
			continue
		var si2: int = cont[m][0]
		var k2: int = cont[m][1]
		if si2 == body_si:
			out.body[k2].append(m)
			continue
		var p: Array = o.switches[si2].parent
		if not p.is_empty() and p[0] == body_si:
			var frames: Array = out.wheels[p[1]]
			while frames.size() <= k2:
				frames.append([])
			frames[k2].append(m)
		elif p.is_empty() and k2 == o.switches[si2].default:
			out.base.append(m)
	return out

## A vehicle model by its object id (0x0A ... 0x78), from the first arena part holding it.
static func build_model_by_object_id(obj_id: int) -> Node3D:
	var root := Node3D.new()
	root.name = "DiscVehicle"
	var man = DiscManifestScript.load_manifest()
	if man == null:
		return root
	_reset_if_stale(man)
	if not _built.has(obj_id):
		var ids := man.arena_ids()
		var found := ""
		for part in ids:
			if _load_part(man, part).objects.has(obj_id):
				found = part
				break
		if found == "":
			push_warning("[disc] vehicle object 0x%x is in no arena part" % obj_id)
			return root
		var entry: Dictionary = _parts[found]
		var meshes := _body_meshes(entry.objects[obj_id])
		var unit := DiscMeshBuilderScript.WORLD_UNIT_M
		var box: AABB = DiscMeshBuilderScript.bounds(meshes)
		var c := box.get_center()
		var origin := Vector3(-c.x, -box.position.y, -c.z) * unit
		var xf := Transform3D(Basis.from_scale(Vector3.ONE * unit), origin)
		var parts := _damage_parts(entry.objects[obj_id])
		var mesh: ArrayMesh = DiscMeshBuilderScript.build_mesh(parts.base if not parts.is_empty() else meshes, entry.atlas, xf, false, true, true)
		var hull := ConvexPolygonShape3D.new()
		hull.points = _hull_points(DiscMeshBuilderScript.collision_faces(meshes, xf))
		var built_parts := {}
		if not parts.is_empty():
			built_parts.body = []
			built_parts.wheels = []
			for k in parts.body.size():
				built_parts.body.append(DiscMeshBuilderScript.build_mesh(parts.body[k], entry.atlas, xf, false, true, true))
				var wf: Array = []
				for fr in parts.wheels[k]:
					wf.append(DiscMeshBuilderScript.build_mesh(fr, entry.atlas, xf, false, true, true))
				built_parts.wheels.append(wf)
		_built[obj_id] = [mesh, hull, box.size * unit, found, built_parts, origin]
	var b: Array = _built[obj_id]
	root.set_script(DiscVehicleVisualScript)
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = b[0]
	root.add_child(mi)
	var bp: Dictionary = b[4]
	if not bp.is_empty():
		var states: Array = []
		var wheels: Array = []
		for k in bp.body.size():
			var st := Node3D.new()
			st.name = "D%d" % k
			var hm := MeshInstance3D.new()
			hm.name = "Hull"
			hm.mesh = bp.body[k]
			st.add_child(hm)
			var wf2: Array = []
			for f in bp.wheels[k].size():
				var wm := MeshInstance3D.new()
				wm.name = "W%d" % f
				wm.mesh = bp.wheels[k][f]
				st.add_child(wm)
				wf2.append(wm)
			root.add_child(st)
			states.append(st)
			wheels.append(wf2)
		root.call("setup_parts", states, wheels)
	root.set_meta("collision_shape", b[1])
	root.set_meta("disc_object_id", obj_id)
	root.set_meta("size_m", b[2])
	root.set_meta("disc_source", b[3])
	# where the game's vehicle origin (its world position in RAM) sits in this model's space
	root.set_meta("game_origin", b[5])
	return root

static var _col_parts := {}    # arena part id -> {object id: DmdObject} (collision only, no atlas)
static var _col_built := {}    # object id -> [ConvexPolygonShape3D, size_m]
static var _col_key := ""

## Collision of a vehicle without building its mesh or textures (the dedicated server uses
## this): [ConvexPolygonShape3D, size_m] in model space (origin on the ground, centred on x/z,
## front towards -Z), the same as build_model's meta. Empty when the vehicle is not found.
static func collision_by_object_id(obj_id: int) -> Array:
	var man = DiscManifestScript.load_manifest()
	if man == null:
		return []
	if _built.has(obj_id) and _key.begins_with(man.checksum + "|"):
		return [_built[obj_id][1], _built[obj_id][2]]
	if _col_key != man.checksum:
		_col_parts.clear()
		_col_built.clear()
		_col_key = man.checksum
	if _col_built.has(obj_id):
		return _col_built[obj_id]
	for part in man.arena_ids():
		if not _col_parts.has(part):
			var objs := {}
			if _parts.has(part):
				objs = _parts[part].objects
			else:
				var dmd = DiscDmdScript.from_bytes(DiscFilesScript.read_bytes(man.arena_model(part)))
				if dmd != null:
					for o in dmd.objects():
						if o.id in OBJECT_IDS.values() and not objs.has(o.id) and not _body_meshes(o).is_empty():
							objs[o.id] = o
			_col_parts[part] = objs
		if _col_parts[part].has(obj_id):
			var meshes := _body_meshes(_col_parts[part][obj_id])
			var unit := DiscMeshBuilderScript.WORLD_UNIT_M
			var box: AABB = DiscMeshBuilderScript.bounds(meshes)
			var c := box.get_center()
			var xf := Transform3D(Basis.from_scale(Vector3.ONE * unit), Vector3(-c.x, -box.position.y, -c.z) * unit)
			var hull := ConvexPolygonShape3D.new()
			hull.points = _hull_points(DiscMeshBuilderScript.collision_faces(meshes, xf))
			_col_built[obj_id] = [hull, box.size * unit]
			return _col_built[obj_id]
	return []

## Convex hull points of a triangle soup (Mesh.create_convex_shape with simplification).
static func _hull_points(faces: PackedVector3Array) -> PackedVector3Array:
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = faces
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var shape := mesh.create_convex_shape(true, true)
	return shape.points if shape else faces
