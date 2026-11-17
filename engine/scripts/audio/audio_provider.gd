class_name AudioProvider
extends RefCounted
## Seam for sound. Game.audio_provider supplies streams; swap it to change where sound comes from.
## SFX names: "mg", "missile", "explosion", "pickup", "hit". Engine is a looping stream whose
## pitch the game scales with speed. Music is a list of tracks played in order during a match.

const SFX_NAMES := ["mg", "missile", "explosion", "pickup", "hit"]

func get_sfx(_name: String) -> AudioStream:
	return null

func get_engine() -> AudioStream:
	return null

func get_music_count() -> int:
	return 0

## Loaded on demand (a track can be 30 MB).
func get_music_track(_i: int) -> AudioStream:
	return null

func describe() -> String:
	return "none"
