class_name DiscFiles
extends RefCounted
## The one place the disc loader reads the player's game data. Every read goes through
## read_bytes(rel_path) with a manifest-relative path, never an absolute disk path, so the
## same code works on desktop and in a Web export (where the player's picked folder is copied
## into user:// first).
##
## Swap points, in order of priority:
##  - DiscFiles.reader: a Callable(rel_path: String) -> PackedByteArray. Set it to the
##    project-wide game-data reader once that exists (e.g. GameData.read_bytes).
##  - DiscFiles.base_dir: the folder holding manifest.json (res://, user:// or an OS path).
##  - otherwise GameData.root() (the existing setting, default ../gamedata beside game/).
##
## Named DiscFiles because the project already has a GameData class (scripts/autoload/game_data.gd).

static var reader := Callable()
static var base_dir := ""

static func get_base_dir() -> String:
	if base_dir != "":
		return base_dir
	return GameData.root()

## True when rel is a plain relative path inside the data folder.
static func is_safe_rel(rel: String) -> bool:
	if rel == "" or rel.begins_with("/") or rel.begins_with("\\") or rel.contains(":"):
		return false
	for part in rel.replace("\\", "/").split("/"):
		if part == "..":
			return false
	return true

## Bytes of one game-data file, by manifest-relative path. Empty on any failure.
static func read_bytes(rel: String) -> PackedByteArray:
	if not is_safe_rel(rel):
		push_warning("[disc] refusing path outside the data folder: %s" % rel)
		return PackedByteArray()
	if reader.is_valid():
		return reader.call(rel)
	var p := get_base_dir().path_join(rel)
	if not FileAccess.file_exists(p):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(p)

static func exists(rel: String) -> bool:
	return not read_bytes(rel).is_empty() if reader.is_valid() else (is_safe_rel(rel) and FileAccess.file_exists(get_base_dir().path_join(rel)))

static func sha1_hex(bytes: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA1)
	h.update(bytes)
	return h.finish().hex_encode()

## Decoded side data that is not in manifest.json yet (e.g. "arenas/WH.json" with start
## positions and pickups). Looks, in order, for: manifest "data_files" mapping, rel inside the
## data folder, "data/" + rel inside it, then (desktop only, source tree) the repo's data/
## folder beside the data folder. Empty when not found.
static func read_side_data(rel: String, manifest: Dictionary = {}) -> PackedByteArray:
	var mapped := str(manifest.get("data_files", {}).get(rel, ""))
	for cand in [mapped, rel, "data/" + rel]:
		if cand != "":
			var b := read_bytes(cand)
			if not b.is_empty():
				return b
	if not reader.is_valid() and not OS.has_feature("web") and is_safe_rel(rel):
		var p := get_base_dir().path_join("../data").path_join(rel).simplify_path()
		if FileAccess.file_exists(p):
			return FileAccess.get_file_as_bytes(p)
	return PackedByteArray()
