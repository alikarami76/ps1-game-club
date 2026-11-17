class_name DiscVram
extends RefCounted
## PS1 video memory: 1024x512 16-bit words (an RG8 image, so uploads are native blits).
## Mirrors tools/vram.py: load TMS/TIM, decode a (tpage, clut) texture page region to RGBA.
## Colour 0x0000 is transparent; everything else is opaque (bit 15 is ignored, as in tim.py).

const W := 1024
const H := 512

var image: Image = Image.create_empty(W, H, false, Image.FORMAT_RG8)
var _mem := PackedByteArray()   # snapshot of image data, refreshed after uploads
var _dirty := true

func upload(x: int, y: int, w: int, h: int, data: PackedByteArray, off: int) -> void:
	if w <= 0 or h <= 0 or off + w * h * 2 > data.size():
		return
	var src := Image.create_from_data(w, h, false, Image.FORMAT_RG8, data.slice(off, off + w * h * 2))
	image.blit_rect(src, Rect2i(0, 0, w, h), Vector2i(x, y))
	_dirty = true

func load_tim(data: PackedByteArray, off := 0) -> void:
	var flags := data.decode_u32(off + 4)
	var pos := off + 8
	for _i in (2 if flags & 8 else 1):
		var blen := data.decode_u32(pos)
		upload(data.decode_u16(pos + 4), data.decode_u16(pos + 6), data.decode_u16(pos + 8), data.decode_u16(pos + 10), data, pos + 12)
		pos += blen

## Loads every TIM in a TMS texture set. Returns false when the bytes are not a TMS file.
func load_tms(data: PackedByteArray) -> bool:
	if data.size() < 16 or data.slice(0, 5).get_string_from_ascii() != "TXSPC":
		return false
	var count := data.decode_u32(12)
	var pos := 16
	for _i in count:
		var size := data.decode_u32(pos)
		load_tim(data, pos + 4)
		pos += 4 + size
	return true

func mem() -> PackedByteArray:
	if _dirty:
		_mem = image.get_data()
		_dirty = false
	return _mem

## Alpha given to texels whose semi-transparency bit (bit 15) is set, when decode_rect is
## asked to mark them. The PS1 blends only those texels of a semi-transparent polygon.
const STP_ALPHA := 200

## PS1 15-bit colour to a little-endian RGBA8 int (r | g<<8 | b<<16 | a<<24), as tim.py's
## rgb555_to_rgba: 0x0000 is transparent, all else opaque (or STP_ALPHA when mark_stp).
static func rgba(px: int, mark_stp := false) -> int:
	if px == 0:
		return 0
	var a := STP_ALPHA if mark_stp and px & 0x8000 else 255
	return ((px & 31) << 3) | (((px >> 5) & 31) << 11) | (((px >> 10) & 31) << 19) | (a << 24)

## Decodes the region (rx, ry, rw, rh) of a 256x256 texture page with its palette, as RGBA8.
func decode_rect(tpage: int, clut: int, rx: int, ry: int, rw: int, rh: int, mark_stp := false) -> Image:
	var m := mem()
	var bx := (tpage & 15) * 64
	var by := ((tpage >> 4) & 1) * 256
	var mode := (tpage >> 7) & 3
	var cx := (clut & 63) * 16
	var cy := (clut >> 6) & 511
	var out := PackedInt32Array()
	out.resize(rw * rh)
	var pal := PackedInt32Array()
	if mode == 0 or mode == 1:
		var n := 16 if mode == 0 else 256
		pal.resize(n)
		for i in n:
			var col := (cx + i) % W if mode == 1 else cx + i
			pal[i] = rgba(m.decode_u16((cy * W + col) * 2), mark_stp)
	var k := 0
	for v in rh:
		var row := ((by + ry + v) % H) * W
		for u in rw:
			var uu := rx + u
			if mode == 0:
				var word := m.decode_u16((row + (bx + (uu >> 2)) % W) * 2)
				out[k] = pal[(word >> ((uu & 3) * 4)) & 15]
			elif mode == 1:
				var word := m.decode_u16((row + (bx + (uu >> 1)) % W) * 2)
				out[k] = pal[(word >> ((uu & 1) * 8)) & 255]
			else:
				out[k] = rgba(m.decode_u16((row + (bx + uu) % W) * 2), mark_stp)
			k += 1
	return Image.create_from_data(rw, rh, false, Image.FORMAT_RGBA8, out.to_byte_array())

## Whole 256x256 page, as vram.py's page().
func page(tpage: int, clut: int) -> Image:
	return decode_rect(tpage, clut, 0, 0, 256, 256)
