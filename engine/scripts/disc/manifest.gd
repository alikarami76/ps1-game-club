class_name DiscManifest
extends RefCounted
## manifest.json of the player's game data: lists every file by relative path.
## Arena ids are "<LEVEL>/<part>", e.g. "WH/part1".

const DiscFilesScript := preload("res://scripts/disc/disc_files.gd")

var data: Dictionary = {}
var checksum := ""   # sha1 of manifest.json, names the user:// cache folder

static var _cached: DiscManifest = null
static var _cached_base := ""

## Loads (and caches) the manifest; null when there is none.
static func load_manifest(force := false) -> DiscManifest:
	var base := DiscFilesScript.get_base_dir()
	if not force and _cached != null and _cached_base == base:
		return _cached
	var bytes := DiscFilesScript.read_bytes("manifest.json")
	if bytes.is_empty():
		return null
	var d = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		return null
	var m := DiscManifest.new()
	m.data = d
	m.checksum = DiscFilesScript.sha1_hex(bytes)
	_cached = m
	_cached_base = base
	return m

func arena_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var arenas: Dictionary = data.get("arenas", {})
	for level in arenas:
		for part in arenas[level]:
			out.append("%s/%s" % [level, part])
	return out

func _arena_entry(arena_id: String) -> Dictionary:
	var kv := arena_id.split("/")
	if kv.size() != 2:
		return {}
	return data.get("arenas", {}).get(kv[0], {}).get(kv[1], {})

func arena_model(arena_id: String) -> String:
	return str(_arena_entry(arena_id).get("model", ""))

func arena_textures(arena_id: String) -> String:
	return str(_arena_entry(arena_id).get("textures", ""))

func vehicle_model() -> String:
	return str(data.get("vehicle_models", {}).get("model", ""))

func vehicle_textures() -> String:
	return str(data.get("vehicle_models", {}).get("textures", ""))

## Vehicle names (manifest keys, also the tuning.json ids) in select order.
func vehicle_names() -> PackedStringArray:
	var v: Dictionary = data.get("vehicles", {})
	var keys := v.keys()
	keys.sort_custom(func(a, b): return int(v[a].get("select_order", 0)) < int(v[b].get("select_order", 0)))
	return PackedStringArray(keys)

## Checks one file against the manifest's sha1. True when it matches or no checksum is listed.
func verify(rel: String) -> bool:
	var want := str(data.get("checksums", {}).get(rel, ""))
	if want == "":
		return true
	var bytes := DiscFilesScript.read_bytes(rel)
	return not bytes.is_empty() and DiscFilesScript.sha1_hex(bytes) == want

## Checks every listed file. Returns {"ok": n, "bad": [...], "missing": [...]}.
func verify_all() -> Dictionary:
	var res := {"ok": 0, "bad": [], "missing": []}
	var sums: Dictionary = data.get("checksums", {})
	for rel in sums:
		var bytes := DiscFilesScript.read_bytes(rel)
		if bytes.is_empty():
			res.missing.append(rel)
		elif DiscFilesScript.sha1_hex(bytes) != str(sums[rel]):
			res.bad.append(rel)
		else:
			res.ok += 1
	return res
