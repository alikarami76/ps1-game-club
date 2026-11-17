class_name MenuSounds
extends Node
## Menu move / select / back sounds and the menu music, from the player's own game data.
## The sounds were picked by matching the emulator's audio when the cursor moves and when an
## entry is chosen on the original's main menu against the disc's 25 samples (cross-correlation
## at several pitches; best: sample 10 played an octave up for a move, sample 20 an octave
## down for a choice). Low confidence: confirm by ear. Nothing plays without game data or when
## disc audio is turned off. Volumes follow the audio settings ([audio] music / effects, 0-14),
## like the original's 14-step bars.

const MOVE := ["vag_10.wav", 2.0]
const SELECT := ["vag_20.wav", 0.5]
const STEPS := 14

var _players: Array = []
var _streams := {}
var music: AudioStreamPlayer

static func level(key: String) -> int:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return clampi(int(c.get_value("audio", key, 10)), 0, STEPS)

static func set_level(key: String, v: int) -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value("audio", key, clampi(v, 0, STEPS))
	c.save("user://settings.cfg")
	apply_volumes()

static func db(key: String) -> float:
	var l := level(key)
	return -80.0 if l == 0 else linear_to_db(float(l) / STEPS)

## Two buses on top of Master, created here: "Effects" (menu and game sounds; the HUD routes the
## match's players to it) and "Music".
static func bus(name: String) -> int:
	var i := AudioServer.get_bus_index(name)
	if i < 0:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, name)
		AudioServer.set_bus_send(i, "Master")
	return i

static func apply_volumes() -> void:
	AudioServer.set_bus_volume_db(bus("Effects"), db("effects"))
	AudioServer.set_bus_volume_db(bus("Music"), db("music"))

func _ready() -> void:
	apply_volumes()
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = "Effects"
		add_child(p)
		_players.append(p)
	music = AudioStreamPlayer.new()
	music.bus = "Music"
	add_child(music)

func _stream(file: String) -> AudioStream:
	if _streams.has(file):
		return _streams[file]
	var s: AudioStream = null
	if GameData.has_data() and GameData.use_disc_audio():
		var idx := GameData.sfx_index_path()
		if idx != "":
			s = WavLoader.load_file(idx.get_base_dir().path_join(file))
			if s is AudioStreamWAV:
				(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_DISABLED
	_streams[file] = s
	return s

func _play(spec: Array, i: int) -> void:
	var s := _stream(spec[0])
	if s == null:
		return
	var p: AudioStreamPlayer = _players[i]
	p.stream = s
	p.pitch_scale = spec[1]
	p.play()

func move() -> void:
	_play(MOVE, 0)

func select() -> void:
	_play(SELECT, 1)

## Plays disc music track n (0 = the first CD audio track) on loop; -1 stops.
func play_track(n: int) -> void:
	if n < 0 or not (GameData.has_data() and GameData.use_disc_audio()):
		music.stop()
		return
	var paths := GameData.music_paths()
	if paths.is_empty():
		return
	var p: String = paths[posmod(n, paths.size())]
	if music.has_meta("path") and str(music.get_meta("path")) == p and music.playing:
		return
	var st = WavLoader.load_file(p)
	if st == null:
		return
	music.set_meta("path", p)
	music.stream = st
	if not music.finished.is_connected(music.play):
		music.finished.connect(music.play)
	music.play()
