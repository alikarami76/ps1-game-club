class_name GameData
extends RefCounted
## Where the player's own game data (organised from their disc) lives. Never packaged, never
## sent over the network. The setting is the folder that holds manifest.json; every file is
## found through the manifest (relative paths), never by guessing names.
##
## Desktop: a folder on disk (default ../gamedata beside game/), stored in user://settings.cfg.
## Web: the player picks their folder in the browser (WebDataImport); the listed files are
## copied into user://gamedata (IndexedDB) once, and read from there afterwards.
## read_bytes(rel_path) works the same on both.

const WEB_ROOT := "user://gamedata"

## Default: the "gamedata" folder next to the game/ project folder (works when running from the
## source tree). Exported builds have no such folder, so the player picks one.
static func default_root() -> String:
	if OS.has_feature("web"):
		return WEB_ROOT
	var proj := ProjectSettings.globalize_path("res://").simplify_path()
	return proj.path_join("../gamedata").simplify_path()
static var root_override := ""      # from --data=PATH
static var _manifest_cache := {}
static var _manifest_root := ""

static func _cfg() -> ConfigFile:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return c

static func expand(p: String) -> String:
	if p.begins_with("~"):
		return OS.get_environment("HOME") + p.substr(1)
	return p

## Folder holding manifest.json.
static func root() -> String:
	if root_override != "":
		return expand(root_override)
	if OS.has_feature("web"):
		return WEB_ROOT
	return expand(str(_cfg().get_value("game_data", "root", default_root())))

static func is_configured() -> bool:
	return root_override != "" or _cfg().has_section_key("game_data", "root")

static func set_root(path: String) -> void:
	var c := _cfg()
	c.set_value("game_data", "root", path)
	c.save("user://settings.cfg")
	_manifest_root = ""

static func reset_cache() -> void:
	_manifest_root = ""

static func use_disc_audio() -> bool:
	return bool(_cfg().get_value("game_data", "use_disc_audio", true))

static func set_use_disc_audio(on: bool) -> void:
	var c := _cfg()
	c.set_value("game_data", "use_disc_audio", on)
	c.save("user://settings.cfg")

static func manifest_path() -> String:
	return root().path_join("manifest.json")

static func manifest() -> Dictionary:
	var r := root()
	if _manifest_root == r:
		return _manifest_cache
	_manifest_root = r
	_manifest_cache = {}
	var mp := manifest_path()
	if FileAccess.file_exists(mp):
		var d = JSON.parse_string(FileAccess.get_file_as_string(mp))
		if typeof(d) == TYPE_DICTIONARY:
			_manifest_cache = d
	return _manifest_cache

static func has_data() -> bool:
	return not manifest().is_empty()

## True when rel is a plain relative path inside the data folder.
static func is_safe_rel(rel: String) -> bool:
	if rel == "" or rel.begins_with("/") or rel.begins_with("\\") or rel.contains(":"):
		return false
	for part in rel.replace("\\", "/").split("/"):
		if part == ".." or part == "":
			return false
	return true

## Bytes of one game-data file by manifest-relative path; empty when missing. Same on desktop
## and web (web reads the copy in user://gamedata).
static func read_bytes(rel: String) -> PackedByteArray:
	if not is_safe_rel(rel):
		return PackedByteArray()
	var p := root().path_join(rel)
	if not FileAccess.file_exists(p):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(p)

## Absolute path of a manifest-relative path.
static func path(rel: String) -> String:
	return root().path_join(rel)

## Every relative file path the manifest lists (checksums plus any path-like string value).
static func listed_files(m: Dictionary) -> PackedStringArray:
	var out := {}
	for k in m.get("checksums", {}):
		out[str(k)] = true
	_collect(m, out)
	var arr := PackedStringArray()
	for k in out:
		if is_safe_rel(k):
			arr.append(k)
	return arr

static func _collect(v, out: Dictionary) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) != "checksums" and str(k) != "source":
					_collect(v[k], out)
		TYPE_ARRAY:
			for e in v:
				_collect(e, out)
		TYPE_STRING:
			var s: String = v
			if s.contains("/") and s.get_extension() != "" and not s.contains(" "):
				out[s] = true

static func sfx_index_path() -> String:
	var rel: String = str(manifest().get("audio", {}).get("sfx_index", ""))
	return path(rel) if rel != "" else ""

static func music_paths() -> Array:
	var out: Array = []
	for rel in manifest().get("audio", {}).get("music", []):
		out.append(path(str(rel)))
	return out

## Measured tuning numbers: manifest "tuning" key if present, else tuning.json beside the manifest
## or in a sibling data/ folder.
static func tuning_path() -> String:
	var rel: String = str(manifest().get("tuning", ""))
	var cands: Array = []
	if rel != "":
		cands.append(path(rel))
	cands.append(root().path_join("tuning.json"))
	cands.append(root().path_join("../data/tuning.json"))
	for p in cands:
		if FileAccess.file_exists(p):
			return p
	return ""
