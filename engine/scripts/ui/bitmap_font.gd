extends RefCounted
## A bitmap font driven by the disc's font image and the glyph table read from the player's own
## executable (see games/twisted-metal/organize.py). Each glyph is (u, v, w, h, dy) in the font image; glyphs
## sit bottom-aligned on the line, moved down by dy. The glyph boxes include a one-pixel margin and
## the font's outline, so glyphs overlap by one pixel (advance = w - 1).
##
## The original draws the glyphs' white face in the text colour and keeps the dark outline, which
## a modulated draw reproduces (face 248 * colour, outline 8 * colour = near black).
##
## Characters missing from the table fall back to their other case, then to a few stand-ins.
## "menu": upper case = the large menu letters, lower case = small capitals; "big": upper case =
## tall headings, lower case = the menu's small capitals (so "Prepare" mixes sizes like the disc).

var name := ""
var texture: Texture2D
var glyphs := {}           # char -> [u, v, w, h, dy]
var line_h := 12           # height of a standard glyph box (the line's bottom = top + line_h)
var space := 13            # width of a space
var overlap := 1           # pixels each glyph overlaps the next
const FACE := 248.0 / 255.0

# measured from emulator frames of the original menus (see cache/fidelity/menus)
const METRICS := {"menu": [12, 13, 1], "big": [19, 12, 1], "digits": [14, 9, 1], "small": [9, 6, 0]}
const STAND_INS := {".": [":", ","], "&": ["+"], "/": ["-"], "#": ["-"], "+": ["-"], "%": ["-"], "\"": ["'"]}

var k := 1.0               # texture pixels per original pixel (UI upscaling)

## img: the font image as decoded from the disc. The glyphs are copied apart (2 transparent
## pixels between them) before upscaling, so the filter never mixes neighbouring glyphs; the
## table then points into that repacked, upscaled atlas.
func _init(font_name: String, img: Image, table: Dictionary, cache_key := "") -> void:
	name = font_name
	for kk in table:
		glyphs[str(kk)] = table[kk]
	_finish_table(font_name)
	texture = _repack(img, cache_key)

func _repack(img: Image, cache_key: String) -> Texture2D:
	var boxes := {}   # "u,v,w,h" -> new position
	var x := 2
	var y := 2
	var row_h := 0
	const W := 256
	for c in glyphs:
		var g: Array = glyphs[c]
		var key := "%d,%d,%d,%d" % [g[0], g[1], g[2], g[3]]
		if boxes.has(key):
			continue
		if x + int(g[2]) + 2 > W:
			x = 2
			y += row_h + 2
			row_h = 0
		boxes[key] = Vector2i(x, y)
		x += int(g[2]) + 2
		row_h = maxi(row_h, int(g[3]))
	var atlas := Image.create_empty(W, y + row_h + 2, false, Image.FORMAT_RGBA8)
	var src := img
	if src.get_format() != Image.FORMAT_RGBA8:
		src = img.duplicate()
		src.convert(Image.FORMAT_RGBA8)
	for key in boxes:
		var p := (key as String).split(",")
		atlas.blit_rect(src, Rect2i(int(p[0]), int(p[1]), int(p[2]), int(p[3])), boxes[key])
	for c in glyphs:
		var g: Array = glyphs[c]
		var pos: Vector2i = boxes["%d,%d,%d,%d" % [g[0], g[1], g[2], g[3]]]
		glyphs[c] = [pos.x, pos.y, g[2], g[3], g[4]]
	var up: Image = DiscUI.upscaled(cache_key, atlas) if cache_key != "" else atlas
	k = float(up.get_width()) / float(W)
	return ImageTexture.create_from_image(up)

func _finish_table(font_name: String) -> void:
	var m: Array = METRICS.get(font_name, [12, 8, 1])
	line_h = m[0]
	space = m[1]
	overlap = m[2]
	# '!' etc. live at the '\\' slot and friends in the disc's table (ASCII '0'-based, with the
	# symbols the game needs placed in the slots after 'Z')
	var remap := {"!": "\\", "(": "[", ")": "]", ",": "^", "'": "`"}
	for c in remap:
		if not glyphs.has(c) and glyphs.has(remap[c]):
			glyphs[c] = glyphs[remap[c]]
	if font_name == "big" and glyphs.has("="):
		glyphs["-"] = glyphs["="]
	if font_name == "menu":
		glyphs["-"] = [92, 42, 12, 6, -3]   # the dash in the font image has no table slot
	if not glyphs.has(".") and glyphs.has(";"):
		glyphs["."] = glyphs[";"]

func _glyph(c: String) -> Variant:
	if glyphs.has(c):
		return glyphs[c]
	var alt := c.to_upper() if c == c.to_lower() else c.to_lower()
	if glyphs.has(alt):
		return glyphs[alt]
	for s in STAND_INS.get(c, []):
		if glyphs.has(s):
			return glyphs[s]
	return null

func char_width(c: String) -> int:
	if c == " ":
		return space
	var g = _glyph(c)
	return int(g[2]) - overlap if g != null else space

func width(text: String) -> int:
	var w := 0
	for i in text.length():
		w += char_width(text[i])
	return w + overlap if text != "" else 0

## Draws text with its box's top-left at pos (pixel units of the 320x240 screen, scaled by s).
func draw(ci: CanvasItem, pos: Vector2, text: String, color: Color, s := 1.0) -> void:
	if texture == null:
		return
	var col := Color(minf(color.r / FACE, 1.0), minf(color.g / FACE, 1.0), minf(color.b / FACE, 1.0), color.a)
	var x := pos.x
	for i in text.length():
		var c := text[i]
		if c == " ":
			x += space * s
			continue
		var g = _glyph(c)
		if g == null:
			x += space * s
			continue
		var w := float(g[2])
		var h := float(g[3])
		var y := pos.y + (line_h - h + float(g[4])) * s
		ci.draw_texture_rect_region(texture, Rect2(x, y, w * s, h * s), Rect2(g[0] * k, g[1] * k, w * k, h * k), col)
		x += (w - overlap) * s

## Draws text centred on cx.
func draw_centered(ci: CanvasItem, cx: float, y: float, text: String, color: Color, s := 1.0) -> void:
	draw(ci, Vector2(roundf(cx - width(text) * s * 0.5), y), text, color, s)
