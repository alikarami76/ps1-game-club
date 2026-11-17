extends RefCounted
## PS1 look settings (user://settings.cfg, section [render]) and the global shader values the
## disc materials read (declared in project.godot [shader_globals]). Measured in the emulator
## (cache/fidelity/visual, not shipped):
##  - projection: GTE H = 228 on a 320x240 frame, and the game's camera matrix scales the view
##    y and z rows by 0.9, so the picture is 228/0.9 = 253 px per unit wide and 228 tall:
##    vertical FOV 55.5 degrees, and everything is drawn 1/0.9 = 1.111 times wider than tall.
##  - depth cue: DQA = -4194, DQB = 1.25 (x 2^24), far colour black: a polygon's colour is
##    scaled by 1 - clamp(1.25 - 3735 / SZ), SZ = 0.9 x depth in game units. Fog starts at
##    104 m and is total at 519 m.
##  - colour: 15-bit frame buffer with the GPU's 4x4 dither on shaded polygons.
## Use: const Ps1Settings := preload("res://scripts/render/ps1_settings.gd"); Ps1Settings.apply()

const PATH := "user://settings.cfg"
const SECTION := "render"
const VFOV := 55.53            # 2 * atan(120 / 228)
const X_STRETCH := 1.0 / 0.9   # the game's view matrix squeezes y and z by 0.9
const INTERNAL_RES := Vector2(320.0, 240.0)
const FOG_DQA := -3735.3       # DQA * H / 4096 * 16 (game units)
const FOG_DQB := 1.25
const FOG_SZ_PER_M := 32.0 * 0.9

## Defaults: everything "like the original".
const DEFAULTS := {
	"ps1_accurate": true,      # affine texture mapping + vertex snapping to 320x240
	"color_15bit": true,       # 15-bit colour with the PS1 dither pattern
	"depth_cue": true,         # the original's distance darkening
	"nearest": true,           # nearest-neighbour texture sampling
	"widescreen": false,       # false: 4:3 picture with side bars, like the original
}

static var _overrides := {}

## The front end's VIDEO options (scripts/ui/classic_front.gd) store two of these:
## [video] ps1_rendering (true = PS1 ACCURATE) and [video] screen ("stretch" = widescreen).
## They win over this file's own [render] keys when present.
static func get_value(key: String) -> bool:
	if _overrides.has(key):
		return bool(_overrides[key])
	var c := ConfigFile.new()
	c.load(PATH)
	if key == "ps1_accurate" and c.has_section_key("video", "ps1_rendering"):
		return bool(c.get_value("video", "ps1_rendering"))
	if key == "widescreen" and c.has_section_key("video", "screen"):
		return str(c.get_value("video", "screen")) == "stretch"
	return bool(c.get_value(SECTION, key, DEFAULTS.get(key, false)))

static var _mtime := -1

## True (and re-applies) when settings.cfg changed since the last call: lets running scenes
## pick up the menu's choices live.
static func poll_changes() -> bool:
	var t := FileAccess.get_modified_time(PATH) if FileAccess.file_exists(PATH) else 0
	if t == _mtime:
		return false
	_mtime = t
	apply()
	return true

static func set_value(key: String, on: bool) -> void:
	var c := ConfigFile.new()
	c.load(PATH)
	c.set_value(SECTION, key, on)
	c.save(PATH)
	apply()

## Command-line / test overrides (not saved), e.g. {"ps1_accurate": false}.
static func set_override(key: String, on) -> void:
	if on == null:
		_overrides.erase(key)
	else:
		_overrides[key] = on
	apply()

## Pushes the settings into the global shader values. Safe to call often.
static func apply() -> void:
	var acc := get_value("ps1_accurate")
	RenderingServer.global_shader_parameter_set("ps1_xstretch", X_STRETCH)
	RenderingServer.global_shader_parameter_set("ps1_snap", INTERNAL_RES if acc else Vector2.ZERO)
	RenderingServer.global_shader_parameter_set("ps1_affine", 1.0 if acc else 0.0)
	RenderingServer.global_shader_parameter_set("ps1_color15", 1.0 if get_value("color_15bit") else 0.0)
	# The Compatibility renderer (Web) writes shader colours to the screen as they are (and
	# blends them in display space, like the PS1); Mobile/Forward+ expect linear colour.
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	RenderingServer.global_shader_parameter_set("ps1_linearize", 0.0 if compat else 1.0)
	# The sky's depth band just in front of the far plane. Both renderers use reverse-z: the
	# far plane is clip z / w = 0 on Mobile/Forward+ and -1 on Compatibility (measured with
	# the fidelity capture). With the near plane at 0.05 m every level polygon up to 1500 m
	# stays in front of the band.
	RenderingServer.global_shader_parameter_set("ps1_far", -0.9999998 if compat else 0.0000001)
	RenderingServer.global_shader_parameter_set("ps1_far_band", -0.99999 if compat else 0.00001)
	RenderingServer.global_shader_parameter_set("ps1_fog", Vector3(FOG_DQB, FOG_DQA / FOG_SZ_PER_M, 1.0 if get_value("depth_cue") else 0.0))

## Environment values for disc arenas: no tonemapping, so the game's display-space colours
## come out unchanged.
static func setup_environment(env: Environment) -> void:
	if env == null:
		return
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	env.glow_enabled = false
	env.fog_enabled = false
	env.ssao_enabled = false
	env.adjustment_enabled = false
