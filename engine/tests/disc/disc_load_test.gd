extends SceneTree
## Loads every arena and the 12 vehicles from the game data folder and prints counts,
## timings and atlas sizes. Headless:
##   Godot --headless --path game --script res://tests/disc/disc_load_test.gd -- [options]
## Options: --data=DIR (folder with manifest.json), --upscale=1|2|4, --fresh (delete the
## user:// atlas cache first, to time decoding + upscaling), --only=WH/part1, --verify
## (check every file's sha1 against the manifest).

const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")
const DiscManifestScript := preload("res://scripts/disc/manifest.gd")
const DiscAtlasScript := preload("res://scripts/disc/atlas.gd")
const DiscSettingsScript := preload("res://scripts/disc/disc_settings.gd")
const ArenaScript := preload("res://scripts/disc/disc_arena_provider.gd")
const VehiclesScript := preload("res://scripts/disc/disc_vehicle_models.gd")

func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("data"):
		DiscFilesScript.base_dir = args.data
	if args.has("upscale"):
		DiscSettingsScript.upscale_override = int(args.upscale)
	var man = DiscManifestScript.load_manifest()
	if man == null:
		printerr("FAIL no manifest.json under ", DiscFilesScript.get_base_dir())
		quit(1)
		return
	var scale := DiscSettingsScript.texture_upscale()
	print("manifest %s, upscale x%d, cache %s" % [man.checksum.substr(0, 12), scale, ProjectSettings.globalize_path(DiscAtlasScript.cache_dir(man.checksum))])
	if args.has("fresh"):
		_remove_dir(DiscAtlasScript.cache_dir(man.checksum))
	if args.has("verify"):
		var t := Time.get_ticks_usec()
		var v: Dictionary = man.verify_all()
		print("verify: %d ok, %d bad, %d missing (%.0f ms)" % [v.ok, v.bad.size(), v.missing.size(), (Time.get_ticks_usec() - t) / 1000.0])
	var fails := 0
	for id in man.arena_ids():
		if args.has("only") and id != args.only:
			continue
		var prov = ArenaScript.new(id)
		var t0 := Time.get_ticks_usec()
		var root: Node3D = prov.build_arena()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var st: Dictionary = prov.last_stats
		var sp: Array = root.get_meta("spawn_points")
		var pk: Array = root.get_meta("pickup_points")
		if sp.size() < 8:
			fails += 1
		var sz: Vector3 = st.get("size_m", Vector3.ZERO)
		print("arena %-13s %6d polys %6d tris  size %.0fx%.0fx%.0f m  total %5.0f ms (parse %4.0f, atlas %5.0f [decode %4.0f, upscale %5.0f%s], mesh %4.0f, spawns %4.0f)  spawns %d (%s) pickups %d (%d decoded) samples %d  atlas: %s" % [
			id, st.get("polygons", 0), st.get("triangles", 0), sz.x, sz.y, sz.z, ms, st.get("parse_ms", 0), st.get("atlas_ms", 0),
			st.get("atlas_decode_ms", 0), st.get("upscale_ms", 0), ", cached" if st.get("atlas_cached", false) else "",
			st.get("mesh_ms", 0), st.get("spawn_ms", 0), sp.size(), st.get("spawn_source", ""), pk.size(), st.get("pickups_from_data", 0), st.get("spawn_samples", 0), st.get("atlas", "")])
		root.free()
	var vp = VehiclesScript.new()
	var t1 := Time.get_ticks_usec()
	for i in vp.get_model_count():
		var t2 := Time.get_ticks_usec()
		var m: Node3D = vp.build_model(i, Color.WHITE)
		var s: Vector3 = m.get_meta("size_m", Vector3.ZERO)
		var hull = m.get_meta("collision_shape", null)
		if hull == null:
			fails += 1
		print("vehicle %2d %-9s obj 0x%02x from %-13s %.2f x %.2f x %.2f m (w x h x l)  hull %d pts  %.0f ms" % [i, vp.get_disc_id(i), m.get_meta("disc_object_id", 0), m.get_meta("disc_source", "-"), s.x, s.y, s.z, hull.points.size() if hull else 0, (Time.get_ticks_usec() - t2) / 1000.0])
		m.free()
	print("vehicles total %.0f ms" % ((Time.get_ticks_usec() - t1) / 1000.0))
	for part in VehiclesScript.last_stats:
		print("  vehicle atlas from %s: %s" % [part, VehiclesScript.last_stats[part]])
	print("RESULT %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)

func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
