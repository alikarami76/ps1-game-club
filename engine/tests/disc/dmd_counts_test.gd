extends SceneTree
## Prints per-object counts for every DMD in the manifest, in the same format as
## tests/disc/dmd_counts_ref.py (which runs games/twisted-metal/dmd.py), so the two can be diffed:
##   python3 -I engine/tests/disc/dmd_counts_ref.py > /tmp/ref.txt
##   Godot --headless --path engine --script res://tests/disc/dmd_counts_test.gd 2>/dev/null | grep " obj " > /tmp/gd.txt
##   diff /tmp/ref.txt /tmp/gd.txt    (no output = the port matches)
## Options after --: --data=DIR (folder holding manifest.json).

const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")
const DiscManifestScript := preload("res://scripts/disc/manifest.gd")
const DiscDmdScript := preload("res://scripts/disc/dmd.gd")

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--data="):
			DiscFilesScript.base_dir = a.substr(7)
	var man = DiscManifestScript.load_manifest()
	if man == null:
		printerr("no manifest.json under ", DiscFilesScript.get_base_dir())
		quit(1)
		return
	var files: Array = []
	for id in man.arena_ids():
		files.append([id, man.arena_model(id)])
	files.append(["vehicles", man.vehicle_model()])
	for f in files:
		var t0 := Time.get_ticks_usec()
		var dmd = DiscDmdScript.from_bytes(DiscFilesScript.read_bytes(f[1]))
		var objs: Array = dmd.objects()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		for i in objs.size():
			var o = objs[i]
			var polys := 0
			var verts := 0
			var spr := 0
			var tex := 0
			var nrm := 0
			var tw := 0
			var cs := 0
			for m in o.meshes:
				nrm += m.normal_count()
				for sp in m.sprites:
					for c in DiscDmdScript.vertex_colors(m, sp[1]):
						cs += (c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)
				polys += m.polygons.size()
				verts += m.vertex_count
				spr += m.sprites.size()
				for p in m.polygons:
					if p.is_textured():
						tex += 1
					if not p.texwin.is_empty():
						tw += 1
					for c in DiscDmdScript.vertex_colors(m, p):
						cs += (c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)
			print("%s obj %d id 0x%x meshes %d polys %d verts %d sprites %d textured %d normals %d texwin %d colsum %d" % [f[0], i, o.id, o.meshes.size(), polys, verts, spr, tex, nrm, tw, cs])
		printerr("# %s parse %.0f ms" % [f[0], ms])
	quit(0)
