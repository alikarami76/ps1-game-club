class_name DiscAudio
extends AudioProvider
## Uses sounds and music from the player's own game data folder (read through manifest.json).
## SFX are picked by label from the sfx index when the label's confidence is at least MIN_CONF;
## anything without a confident label falls back to the procedural sound.

const MIN_CONF := 0.4
## game sound name -> start of the index label to look for
const LABELS := {
	"engine": "engine loop",
	"mg": "gun/cannon shot",
	"missile": "rocket/missile",
	"explosion": "explosion",
	"pickup": "swell or power-up",
	"hit": "short impact",
}

var fallback := ProceduralAudio.new()
var _by_name := {}      # game sound name -> Array[AudioStream]
var _music: Array = []  # file paths
var used := {}          # game sound name -> Array of file names (what was picked, for logging)
var from_fallback: PackedStringArray = []

func _init() -> void:
	var idx_path := GameData.sfx_index_path()
	if idx_path != "" and FileAccess.file_exists(idx_path):
		var idx = JSON.parse_string(FileAccess.get_file_as_string(idx_path))
		if typeof(idx) == TYPE_DICTIONARY:
			_load_sfx(idx, idx_path.get_base_dir())
	_music = GameData.music_paths().filter(func(p): return FileAccess.file_exists(p))

func _load_sfx(idx: Dictionary, dir: String) -> void:
	var samples: Dictionary = idx.get("samples", {})
	var keys := samples.keys()
	keys.sort_custom(func(a, b): return int(a) < int(b))
	for gname in LABELS:
		var list: Array = []
		for k in keys:
			var s: Dictionary = samples[k]
			if float(s.get("confidence", 0.0)) < MIN_CONF:
				continue
			if not str(s.get("label", "")).begins_with(LABELS[gname]):
				continue
			var lo := Vector2i(-1, -1)
			if s.get("loop_start") != null and s.get("loop_end") != null:
				lo = Vector2i(int(s.loop_start), int(s.loop_end))
			var st := WavLoader.load_file(dir.path_join(str(s.get("file", ""))), lo)
			if st != null:
				list.append(st)
				used.get_or_add(gname, []).append(str(s.file))
		if not list.is_empty():
			_by_name[gname] = list
		else:
			from_fallback.append(gname)

func is_usable() -> bool:
	return not _by_name.is_empty() or not _music.is_empty()

func get_sfx(sfx_name: String) -> AudioStream:
	if _by_name.has(sfx_name):
		var l: Array = _by_name[sfx_name]
		return l[randi() % l.size()]
	return fallback.get_sfx(sfx_name)

func get_engine() -> AudioStream:
	if _by_name.has("engine"):
		return _by_name["engine"][0]
	return fallback.get_engine()

func get_music_count() -> int:
	return _music.size()

func get_music_track(i: int) -> AudioStream:
	if i < 0 or i >= _music.size():
		return null
	return WavLoader.load_file(_music[i])

func describe() -> String:
	return "game data (%s); from game data: %s; procedural fallback: %s; music tracks: %d" % [GameData.root(), str(used), ", ".join(from_fallback), _music.size()]
