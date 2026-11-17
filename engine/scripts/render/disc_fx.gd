extends RefCounted
## Effect sprites from the player's own arena texture file (TMS): the game keeps its effect
## frames as a block of small TIM images at the end of each arena's TMS (missile glow, hit
## sparks, explosion, flash, fire, debris, a second explosion, smoke). The block is found by
## its layout (the sizes of the images, 86 in a row; checked in XARENA, WH, XFWY, PARK and
## SUBURB, both parts), never by pixel content, and decoded here at run time. Nothing is
## shipped. ROOF arranges its effects differently: there has_frames() is false and fx.gd
## falls back to its simple effects.
##
## Drawing: camera-facing quads with the shader below (display-space colours like the disc
## materials, nearest sampling, the PS1 x-stretch); additive for light (glow, sparks, fire,
## explosions; most of their palette entries have the semi-transparency bit set) and half
## blending for smoke.

const Ps1SettingsScript := preload("res://scripts/render/ps1_settings.gd")

## Run-length layout of the block: [[width in 16-bit units, height, TIM mode], count].
const LAYOUT := [[[4, 16, 0], 8], [[8, 32, 0], 38], [[4, 16, 0], 1], [[8, 32, 0], 16], [[4, 16, 0], 3], [[16, 64, 0], 20]]
## Groups: name -> [first image in the block, frame count, additive?]
const GROUPS := {
	"glow": [0, 8, true],
	"sparks": [8, 5, true],
	"explosion": [13, 15, true],
	"flash": [28, 4, true],
	"fire": [32, 10, true],
	"debris": [42, 4, false],
	"blast": [47, 16, true],
	"smoke": [66, 20, false],
}

static var _key := ""
static var _strips := {}     # group -> [ImageTexture strip, frame count, additive]
static var _shaders := {}

static func has_frames(group: String) -> bool:
	return _strips.has(group)

static func clear() -> void:
	_strips.clear()
	_key = ""

## Finds and decodes the effect block in a TMS file (bytes). Cheap; call per arena.
static func load_from_tms(bytes: PackedByteArray, key: String) -> void:
	if key == _key and not _strips.is_empty():
		return
	clear()
	_key = key
	if bytes.size() < 16:
		return
	var tims := _list_tims(bytes)
	var pat: Array = []
	for run in LAYOUT:
		for i in int(run[1]):
			pat.append(run[0])
	var start := -1
	for i in tims.size() - pat.size() + 1:
		var ok := true
		for k in pat.size():
			var t: Dictionary = tims[i + k]
			if t.w != pat[k][0] or t.h != pat[k][1] or t.mode != pat[k][2]:
				ok = false
				break
		if ok:
			start = i
			break
	if start < 0:
		return
	for g in GROUPS:
		var spec: Array = GROUPS[g]
		var frames: Array = []
		for k in int(spec[1]):
			var img := _decode(bytes, tims[start + int(spec[0]) + k])
			if img == null:
				break
			frames.append(img)
		if frames.size() != int(spec[1]):
			continue
		var fw: int = frames[0].get_width()
		var fh: int = frames[0].get_height()
		var strip := Image.create(fw * frames.size(), fh, false, Image.FORMAT_RGBA8)
		for k in frames.size():
			strip.blit_rect(frames[k], Rect2i(0, 0, fw, fh), Vector2i(fw * k, 0))
		_strips[g] = [ImageTexture.create_from_image(strip), frames.size(), bool(spec[2])]

static func _list_tims(b: PackedByteArray) -> Array:
	var out: Array = []
	var n := b.decode_u32(12)
	var pos := 16
	for i in n:
		if pos + 8 > b.size():
			break
		var size := b.decode_u32(pos)
		var p := pos + 4
		var flags := b.decode_u32(p + 4)
		var q := p + 8
		var clut := -1
		if flags & 8:
			clut = q
			q += b.decode_u32(q)
		out.append({"w": b.decode_u16(q + 8), "h": b.decode_u16(q + 10), "mode": flags & 7, "clut": clut, "pix": q})
		pos += 4 + size
	return out

## 4- and 8-bit TIMs with a palette; colour 0 is transparent.
static func _decode(b: PackedByteArray, t: Dictionary) -> Image:
	if t.clut < 0 or t.mode > 1:
		return null
	var q: int = t.pix
	var w16: int = t.w
	var h: int = t.h
	var c: int = t.clut
	var bpp4: bool = t.mode == 0
	var w := w16 * (4 if bpp4 else 2)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var idx: int
			if bpp4:
				var byte := b[q + 12 + y * w16 * 2 + (x >> 1)]
				idx = (byte >> 4) if (x & 1) else (byte & 15)
			else:
				idx = b[q + 12 + y * w16 * 2 + x]
			var col := b.decode_u16(c + 12 + idx * 2)
			if col == 0:
				continue
			img.set_pixel(x, y, Color8((col & 31) << 3, ((col >> 5) & 31) << 3, ((col >> 10) & 31) << 3, 255))
	return img

## A camera-facing quad playing a group's frames over `time` seconds; size in metres.
## Returns null when the group is not available.
static func spawn(parent: Node, group: String, pos: Vector3, size: float, time: float, rise := 0.0) -> Node3D:
	if not _strips.has(group) or parent == null or not parent.is_inside_tree():
		return null
	var s: Array = _strips[group]
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2.ONE
	mi.mesh = qm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = size
	var m := ShaderMaterial.new()
	m.shader = _shader(bool(s[2]))
	m.set_shader_parameter("tex", s[0])
	m.set_shader_parameter("frames", float(s[1]))
	m.set_shader_parameter("frame", 0.0)
	m.render_priority = 2
	mi.material_override = m
	parent.add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * size
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(m, "shader_parameter/frame", float(s[1]) - 0.01, time)
	if rise != 0.0:
		tw.tween_property(mi, "global_position", pos + Vector3(0, rise, 0), time)
	tw.chain().tween_callback(mi.queue_free)
	return mi

static func _shader(additive: bool) -> Shader:
	if _shaders.has(additive):
		return _shaders[additive]
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, %s;
global uniform float ps1_xstretch;
global uniform float ps1_linearize;
uniform sampler2D tex : filter_nearest, repeat_disable;
uniform float frames = 1.0;
uniform float frame = 0.0;
void vertex() {
	vec4 c = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	float s = length(MODEL_MATRIX[0].xyz);
	c.xy += VERTEX.xy * s;
	vec4 p = PROJECTION_MATRIX * c;
	p.x *= ps1_xstretch;
	POSITION = p;
}
void fragment() {
	vec2 uv = vec2((floor(frame) + UV.x) / frames, UV.y);
	vec4 t = texture(tex, uv);
	if (t.a < 0.5) { discard; }
	vec3 col = t.rgb;
	if (ps1_linearize > 0.5) {
		col = mix(col / 12.92, pow((col + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), col));
	}
	ALBEDO = col;
	ALPHA = %s;
}
""" % ["blend_add" if additive else "blend_mix", "1.0" if additive else "0.5"]
	_shaders[additive] = sh
	return sh
