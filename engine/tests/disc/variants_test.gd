extends SceneTree
# Variant cross-check (switches, animations, splits) against tests/disc/variants_ref.py:
#   Godot --headless --path engine --script res://tests/disc/variants_test.gd > gd.txt
#   python3 -I engine/tests/disc/variants_ref.py [gamedata_dir] > py.txt && diff gd.txt py.txt
const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")
const DiscManifestScript := preload("res://scripts/disc/manifest.gd")
const DiscDmdScript := preload("res://scripts/disc/dmd.gd")

func cnt(ms: Array) -> String:
	var polys := 0
	var spr := 0
	var cs := 0
	var v := 0
	for m in ms:
		polys += m.polygons.size()
		spr += m.sprites.size()
		for p in m.polygons:
			for c in DiscDmdScript.vertex_colors(m, p):
				cs += (c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)
		for sp in m.sprites:
			for c in DiscDmdScript.vertex_colors(m, sp[1]):
				cs += (c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)
		for p in m.polygons:
			for k in p.indices:
				var q: Vector3 = m.vertices[k]
				for c in 3:
					v += absi(floori(q[c] + 0.5))
		for sp in m.sprites:
			var ce: Vector3 = sp[0]
			for c in 3:
				v += absi(floori(ce[c] + 0.5))
	return "%d/%d/%d/%d/%d" % [ms.size(), polys, spr, cs, v]

func par(p: Array) -> String:
	return "None" if p.is_empty() else "(%d, %d)" % [p[0], p[1]]

func _init() -> void:
	var man = DiscManifestScript.load_manifest()
	var files: Array = []
	for id in man.arena_ids():
		files.append([id, man.arena_model(id)])
	files.append(["vehicles", man.vehicle_model()])
	for f in files:
		var dmd = DiscDmdScript.from_bytes(DiscFilesScript.read_bytes(f[1]))
		var objs: Array = dmd.objects()
		for i in objs.size():
			var o = objs[i]
			var ctx := 0
			for x in o.meshes:
				ctx += x.switch_node + x.state * 7 + x.anim_node * 3 + x.frame + x.tag * 5 + x.tag_node + x.split_node + x.split_side * 11
			print("%s obj %d ctx %d" % [f[0], i, ctx])
			for s in o.switches:
				var st := PackedStringArray()
				for z in s.states:
					st.append(cnt(z))
				print("%s obj %d sw 0x%x id 0x%x slot %d count %d def %d parent %s states %s" % [f[0], i, s.offset, s.id, s.slot, s.count, s.default, par(s.parent), " ".join(st)])
			for a in o.animations:
				var fr := PackedStringArray()
				for z in a.frames:
					fr.append(cnt(z))
				print("%s obj %d anim 0x%x id 0x%x delay %d %d-%d mode %d def %d parent %s frames %s" % [f[0], i, a.offset, a.id, a.delay, a.first, a.last, a.mode, a.default, par(a.parent), " ".join(fr)])
			splits_of(f[0], i, o)
	quit(0)

func splits_of(name: String, i: int, o) -> void:
	var pts := [Vector3(16800, 4300, 150), Vector3(10800, 5200, 7700), Vector3(4600, 1800, 7900), Vector3(10800, 6200, 8500), Vector3(0, 0, 0)]
	for sp in o.splits:
		var org := "%d,%d,%d" % [sp.origin[0], sp.origin[1], sp.origin[2]]
		var regs := PackedStringArray()
		for r in sp.regions:
			var parts := PackedStringArray()
			for arr in r:
				var vs := PackedStringArray()
				for v in arr:
					vs.append(str(v))
				parts.append(",".join(vs))
			regs.append("|".join(parts))
		var con := ""
		for q in pts:
			con += "1" if sp.contains(q) else "0"
		print("%s obj %d split 0x%x origin %s parent %s regions %s out %s in %s contains %s" % [name, i, sp.offset, org, par(sp.parent), ";".join(regs), cnt(sp.outside), cnt(sp.inside), con])
