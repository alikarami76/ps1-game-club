class_name DiscSettings
extends RefCounted
## Settings for disc content, stored in user://settings.cfg section [disc] (next to GameData's
## [game_data] keys; each writer reloads the file first, so they do not overwrite each other).
##  texture_upscale: 1 (original resolution, like the PS1), 2 or 4 (Scale2x, sampled
##  nearest-neighbour). Default 4 on desktop (the menus' UI UPSCALING default) and 2 on Web:
##  measured in headless Chrome on XARENA, 4x took the arena build from 0.5 s to 2.0 s and
##  video memory from 78 to 209 MB; 2x costs 0.95 s and 129 MB.

const PATH := "user://settings.cfg"
const UPSCALE_CHOICES := [1, 2, 4]
const UPSCALE_LABELS := ["Original", "2x", "4x"]

static var upscale_override := 0   # from --upscale=N for tests; 0 = use the setting

static func default_upscale() -> int:
	return 2 if OS.has_feature("web") else 4   # Scale2x; "Original" (1) stays a choice

static func texture_upscale() -> int:
	if upscale_override in UPSCALE_CHOICES:
		return upscale_override
	var c := ConfigFile.new()
	c.load(PATH)
	var v := int(c.get_value("disc", "texture_upscale", default_upscale()))
	return v if v in UPSCALE_CHOICES else default_upscale()

static func set_texture_upscale(v: int) -> void:
	var c := ConfigFile.new()
	c.load(PATH)
	c.set_value("disc", "texture_upscale", v if v in UPSCALE_CHOICES else default_upscale())
	c.save(PATH)
