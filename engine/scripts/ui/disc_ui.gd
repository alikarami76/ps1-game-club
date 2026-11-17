class_name DiscUI
extends RefCounted
## Front-end images, fonts and texts from the player's own game data, decoded at run time.
## Nothing here is packaged: every image comes from a TIM (or a TMS texture set) listed in
## manifest.json under "ui" (screens, bios, fonts, glyphs, strings) or "vehicles" (card,
## portrait). TIMs are decoded with DiscVram, the same video-memory emulation the arena loader
## uses. Without game data, available() is false and the menus keep their own design.

const VramS := preload("res://scripts/disc/vram.gd")
const FontS := preload("res://scripts/ui/bitmap_font.gd")

static var _tex := {}       # cache key -> ImageTexture
static var _fonts := {}
static var _strings := {}
static var _glyphs := {}
static var _root := ""      # game-data folder the caches belong to

static func _check_root() -> void:
	var r := GameData.root() + "|" + str(GameData.manifest().get("checksums", {}).size())
	if r != _root:
		_root = r
		_tex.clear()
		_fonts.clear()
		_strings.clear()
		_glyphs.clear()

static func ui() -> Dictionary:
	return GameData.manifest().get("ui", {})

## True when the game data has what the original-style menus need.
static func available() -> bool:
	var u := ui()
	return GameData.has_data() and u.has("glyphs") and u.has("screens") and u.get("fonts", {}).has("uafont1") \
		and u.get("screens", {}).has("scrnc")

## The menus' own setting: "original" (disc look, the default when available) or "modern".
static func classic_enabled() -> bool:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	return available() and str(c.get_value("video", "menus", "original")) == "original"

# ---------------- TIM decoding ----------------

## Decodes the TIM at byte offset off of data (loaded into vram first) to an RGBA image.
static func _decode_tim(vram, data: PackedByteArray, off: int) -> Image:
	var flags := data.decode_u32(off + 4)
	var mode := flags & 7
	var pos := off + 8
	var clut := 0
	if flags & 8:
		clut = (data.decode_u16(pos + 4) >> 4) | (data.decode_u16(pos + 6) << 6)
		pos += data.decode_u32(pos)
	var x := data.decode_u16(pos + 4)
	var y := data.decode_u16(pos + 6)
	var w16 := data.decode_u16(pos + 8)
	var h := data.decode_u16(pos + 10)
	if mode == 3:
		return null
	var per: int = [4, 2, 1][mode]
	var tpage := (x / 64) | ((y / 256) << 4) | (mode << 7)
	return vram.decode_rect(tpage, clut, (x % 64) * per, y % 256, w16 * per, h)

## A TIM file from the game data as an image (null when missing).
static func tim_image(rel: String) -> Image:
	var data := GameData.read_bytes(rel)
	if data.size() < 20 or data.decode_u32(0) != 0x10:
		return null
	var vram = VramS.new()
	vram.load_tim(data, 0)
	return _decode_tim(vram, data, 0)

## Image number index of a TMS texture set (null when missing).
static func tms_image(rel: String, index: int) -> Image:
	var data := GameData.read_bytes(rel)
	if data.size() < 16 or data.slice(0, 5).get_string_from_ascii() != "TXSPC":
		return null
	var count := data.decode_u32(12)
	var pos := 16
	for i in count:
		var size := data.decode_u32(pos)
		if i == index:
			var vram = VramS.new()
			vram.load_tim(data, pos + 4)
			return _decode_tim(vram, data, pos + 4)
		pos += 4 + size
	return null

## The image of a TMS texture set that the game places at video-memory position (x, y).
static func tms_image_at(rel: String, x: int, y: int) -> Image:
	var data := GameData.read_bytes(rel)
	if data.size() < 16 or data.slice(0, 5).get_string_from_ascii() != "TXSPC":
		return null
	var pos := 16
	for i in data.decode_u32(12):
		var size := data.decode_u32(pos)
		var o := pos + 4
		var q := o + 8
		if data.decode_u32(o + 4) & 8:
			q += data.decode_u32(q)
		if data.decode_u16(q + 4) == x and data.decode_u16(q + 6) == y:
			var vram = VramS.new()
			vram.load_tim(data, o)
			return _decode_tim(vram, data, o)
		pos += 4 + size
	return null

## The in-game HUD sheet of an arena ("Gun Tmp", "Turbo:", digits, weapon icons): the arena
## texture set's image at video memory (256, 384), as the game loads it.
static func hud_sheet(arena_id: String) -> Texture2D:
	var kv := arena_id.split("/")
	if kv.size() != 2:
		return null
	var rel := str(GameData.manifest().get("arenas", {}).get(kv[0], {}).get(kv[1], {}).get("textures", ""))
	if rel == "":
		return null
	return _texture("hud:" + rel, func(): return tms_image_at(rel, 256, 384))

# ---------------- UI upscaling ----------------
## [video] ui_upscale: 1 (original pixels), 2 or 4 (Scale2x once or twice, the same filter as the
## 3D textures). Every disc image the menus and HUD draw goes through it. Textures are drawn by
## their logical size (320x240 layout), so an upscaled texture is simply sharper on screen;
## source rectangles into an upscaled image are multiplied by scale() (see region()).
const UPSCALE_CHOICES := [1, 2, 4]
const CACHE_DIR := "user://ui_cache"
static var _factor := 0

static func scale() -> int:
	if _factor == 0:
		var c := ConfigFile.new()
		c.load("user://settings.cfg")
		var v := int(c.get_value("video", "ui_upscale", 4))
		_factor = v if v in UPSCALE_CHOICES else 4
	return _factor

static func set_scale(v: int) -> void:
	var c := ConfigFile.new()
	c.load("user://settings.cfg")
	c.set_value("video", "ui_upscale", v if v in UPSCALE_CHOICES else 4)
	c.save("user://settings.cfg")
	_factor = 0
	_tex.clear()
	_fonts.clear()

## A source rectangle in original pixels -> the same rectangle in the (upscaled) texture.
static func region(r: Rect2) -> Rect2:
	var k := float(scale())
	return Rect2(r.position * k, r.size * k)

## Upscaled copy of img, cached in memory and as PNG in user://ui_cache (so only the very first
## visit of a screen pays for the filter; ~0.1-0.5 s for a 320x240 screen at 4x).
static func upscaled(key: String, img: Image) -> Image:
	var f := scale()
	if img == null or f <= 1:
		return img
	var name := "%s_%dx.png" % [key.sha1_text().left(16), f]
	var path := CACHE_DIR.path_join(name)
	if FileAccess.file_exists(path):
		var cached := Image.load_from_file(path)
		if cached != null and cached.get_width() == img.get_width() * f and cached.get_height() == img.get_height() * f:
			return cached
	var t0 := Time.get_ticks_msec()
	var out := DiscUpscale.upscale(img, f)
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	out.save_png(path)
	print("[ui] upscaled %s %dx%d x%d in %d ms" % [key, img.get_width(), img.get_height(), f, Time.get_ticks_msec() - t0])
	return out

static func _texture(key: String, make: Callable) -> Texture2D:
	_check_root()
	if _tex.has(key):
		return _tex[key]
	var img: Image = make.call()
	img = upscaled(_root + key, img)
	var t: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	_tex[key] = t
	return t

static func tim_texture(rel: String) -> Texture2D:
	if rel == "":
		return null
	return _texture("tim:" + rel, func(): return tim_image(rel))

## A full-screen image by its disc name, e.g. "scrnc" (UASCREEN) or "scndb01" (UABIOS).
static func screen(name: String) -> Texture2D:
	var u := ui()
	var rel := str(u.get("screens", {}).get(name, u.get("bios", {}).get(name, u.get("menus", {}).get(name, ""))))
	return tim_texture(rel)

static func _vehicle(vid: String) -> Dictionary:
	return GameData.manifest().get("vehicles", {}).get(vid, {})

## The vehicle's select-screen card (128x64).
static func card(vid: String) -> Texture2D:
	return tim_texture(str(_vehicle(vid).get("card", "")))

## The driver's portrait (64x90) from the menu car textures.
static func portrait(vid: String) -> Texture2D:
	var p = _vehicle(vid).get("portrait", {})
	if typeof(p) != TYPE_DICTIONARY or not p.has("textures"):
		return null
	var rel := str(p.textures)
	var idx := int(p.get("image", 0))
	return _texture("tms:%s:%d" % [rel, idx], func(): return tms_image(rel, idx))

## The car's biography pages (UABIOS SCNDBnn and SCNDBnnB), in select order.
static func bio_pages(vid: String) -> Array:
	var e := _vehicle(vid)
	if e.is_empty():
		return []
	var n := int(e.get("select_order", 0)) + 1
	var out: Array = []
	for nm in ["scndb%02d" % n, "scndb%02db" % n]:
		var t := screen(nm)
		if t != null:
			out.append(t)
	return out

# ---------------- fonts and texts ----------------

## "menu" (menu entries), "big" (headings), "digits" (thin numbers), "small" (HUD and notes).
static func font(name: String):
	_check_root()
	if _fonts.has(name):
		return _fonts[name]
	if _glyphs.is_empty():
		var rel := str(ui().get("glyphs", ""))
		var d = JSON.parse_string(GameData.read_bytes(rel).get_string_from_utf8()) if rel != "" else null
		_glyphs = d if typeof(d) == TYPE_DICTIONARY else {}
	var spec: Dictionary = _glyphs.get(name, {})
	var f = null
	if not spec.is_empty():
		var frel := str(ui().get("fonts", {}).get(str(spec.get("image", "")), ""))
		var img := tim_image(frel) if frel != "" else null
		if img != null:
			f = FontS.new(name, img, spec.get("glyphs", {}), _root + "font:" + name)
	_fonts[name] = f
	return f

static func strings() -> Dictionary:
	_check_root()
	if _strings.is_empty():
		var rel := str(ui().get("strings", ""))
		var d = JSON.parse_string(GameData.read_bytes(rel).get_string_from_utf8()) if rel != "" else null
		_strings = d if typeof(d) == TYPE_DICTIONARY else {"_": true}
	return _strings

static func text(key: String, fallback: String) -> String:
	return str(strings().get(key, fallback))

## The vehicle's name as the disc's select screen spells it (e.g. the car's call sign).
static func vehicle_name(vid: String) -> String:
	var n := str(strings().get("vehicle_names", {}).get(vid, ""))
	return n if n != "" else Game.vehicle_name(vid).to_upper()

## The stage title lines for an arena id like "WH/part1", e.g. ["'WAREHOUSE DISTRICT", "WARFARE'"].
static func stage_lines(arena_id: String) -> Array:
	var lv := arena_id.split("/")[0]
	var st = strings().get("stages", {}).get(lv, [])
	if typeof(st) == TYPE_ARRAY and not st.is_empty():
		return [st[0]] if lv == "ROOF" else st
	return ["'%s'" % Game.arena_label(arena_id).to_upper()]

## Arena preview screens from the two-player "choose battleground" set, by level.
const ARENA_PREVIEW := {"XARENA": "scrne31", "WH": "scrne32", "XFWY": "scrne33", "PARK": "scrne34", "SUBURB": "scrne35", "ROOF": "scrne36"}
