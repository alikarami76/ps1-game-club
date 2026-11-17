extends Node
## Headless check that both audio providers produce loadable streams. Nothing is played.
## Run: Godot --headless --path game res://scenes/tests/audio_test.tscn [-- --data=PATH]

var fails := 0

func _check(label: String, st: AudioStream, min_len := 0.01) -> void:
	var ok := st != null and st.get_length() >= min_len
	if not ok:
		fails += 1
	print("  %-22s %s  %s" % [label, "ok  " if ok else "FAIL", "-" if st == null else "%.2fs %s" % [st.get_length(), _info(st)]])

func _info(st: AudioStream) -> String:
	if st is AudioStreamWAV:
		var w := st as AudioStreamWAV
		return "%d Hz %s loop=%s" % [w.mix_rate, "stereo" if w.stereo else "mono", "yes" if w.loop_mode != AudioStreamWAV.LOOP_DISABLED else "no"]
	return ""

func _ready() -> void:
	print("[audio] game data root: %s (manifest %s)" % [GameData.root(), "found" if GameData.has_data() else "missing"])
	var providers: Array = [ProceduralAudio.new()]
	var d := DiscAudio.new()
	print("[audio] disc provider usable: %s" % d.is_usable())
	if d.is_usable():
		providers.append(d)
	for p in providers:
		print("[audio] provider: %s" % p.describe())
		for n in AudioProvider.SFX_NAMES:
			_check("sfx " + n, p.get_sfx(n))
		_check("engine", p.get_engine(), 0.1)
		print("  music tracks: %d" % p.get_music_count())
		for i in p.get_music_count():
			_check("music %d" % i, p.get_music_track(i), 5.0)
	print("[audio] %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	get_tree().quit(1 if fails > 0 else 0)
