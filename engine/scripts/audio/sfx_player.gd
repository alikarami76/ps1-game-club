class_name SfxPlayer
extends Node
## Plays one-shot sounds at world positions (small player pool) and the match music.
## Silent in headless mode (no audio device); streams are still created so they can be tested.

const POOL := 12
const MUSIC_DB := -10.0

var enabled := DisplayServer.get_name() != "headless"
var pool: Array[AudioStreamPlayer3D] = []
var music: AudioStreamPlayer
var music_index := 0
var music_started := false

func _ready() -> void:
	if not enabled:
		return
	for i in POOL:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 12.0
		p.max_distance = 140.0
		add_child(p)
		pool.append(p)
	music = AudioStreamPlayer.new()
	music.volume_db = MUSIC_DB
	music.finished.connect(_next_track)
	add_child(music)

func play(sfx_name: String, pos: Vector3, vol_db := 0.0) -> void:
	if not enabled or not is_inside_tree() or Game.audio_provider == null:
		return
	var st := Game.audio_provider.get_sfx(sfx_name)
	if st == null:
		return
	for p in pool:
		if p.is_inside_tree() and not p.playing:
			p.stream = st
			p.global_position = pos
			p.volume_db = vol_db
			p.pitch_scale = randf_range(0.94, 1.06)
			p.play()
			return

func start_music() -> void:
	if not enabled or music_started or not is_inside_tree() or Game.audio_provider == null:
		return
	var n := Game.audio_provider.get_music_count()
	if n <= 0:
		return
	music_started = true
	music_index = randi() % n
	_play_track()

func _play_track() -> void:
	if not is_inside_tree() or music == null:
		return
	var st := Game.audio_provider.get_music_track(music_index)
	if st != null:
		music.stream = st
		music.play()

func _next_track() -> void:
	var n := Game.audio_provider.get_music_count()
	if n > 0:
		music_index = (music_index + 1) % n
		_play_track()
