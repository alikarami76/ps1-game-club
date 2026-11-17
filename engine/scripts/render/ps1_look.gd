extends Node
## Added to every disc arena (DiscArenaProvider): applies the PS1 look settings and sets the
## world's Environment so the game's display-space colours come out unchanged (no
## tonemapping). The match builds its Environment before the arena enters the tree.

const Ps1SettingsScript := preload("res://scripts/render/ps1_settings.gd")

func _ready() -> void:
	Ps1SettingsScript.apply()
	_fix_env.call_deferred()

var _t := 0.0

func _process(delta: float) -> void:
	_t += delta
	if _t < 1.0:
		return
	_t = 0.0
	if Ps1SettingsScript.poll_changes():
		var cam := get_viewport().get_camera_3d()
		if cam != null and cam.has_method("_layout_bars"):
			cam.call("_layout_bars")

func _fix_env() -> void:
	var w := get_viewport().find_world_3d() if get_viewport() else null
	if w != null:
		Ps1SettingsScript.setup_environment(w.environment)
