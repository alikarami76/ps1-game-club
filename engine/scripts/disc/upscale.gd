class_name DiscUpscale
extends RefCounted
## Pixel-art texture upscaling, run once per atlas and cached as PNG in user://.
## Scale2x (EPX / AdvMAME2x) is an edge-directed filter: it rounds diagonal staircases
## without blurring, and treats transparency as a colour so cut-out edges stay sharp.
## 4x = Scale2x applied twice (AdvMAME4x). Chosen over xBRZ because it is a few integer
## compares per pixel, fast enough for single-threaded GDScript on Web (no threads used).

## factor 1, 2 or 4. Returns a new RGBA8 image (or img itself for 1).
static func upscale(img: Image, factor: int) -> Image:
	var out := img
	var f := factor
	while f >= 2:
		out = scale2x(out)
		f /= 2
	return out

static func scale2x(img: Image) -> Image:
	if img.get_format() != Image.FORMAT_RGBA8:
		img = img.duplicate()
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var src := img.get_data().to_int32_array()
	var dst := PackedInt32Array()
	dst.resize(w * h * 4)
	var w2 := w * 2
	for y in h:
		var row := y * w
		var up := (y - 1 if y > 0 else 0) * w
		var dn := (y + 1 if y < h - 1 else y) * w
		var o0 := (y * 2) * w2
		var o1 := o0 + w2
		for x in w:
			var e := src[row + x]
			var b := src[up + x]
			var hh := src[dn + x]
			var d := src[row + (x - 1 if x > 0 else 0)]
			var f := src[row + (x + 1 if x < w - 1 else x)]
			var ox := x * 2
			if b != hh and d != f:
				dst[o0 + ox] = d if d == b else e
				dst[o0 + ox + 1] = f if b == f else e
				dst[o1 + ox] = d if d == hh else e
				dst[o1 + ox + 1] = f if hh == f else e
			else:
				dst[o0 + ox] = e
				dst[o0 + ox + 1] = e
				dst[o1 + ox] = e
				dst[o1 + ox + 1] = e
	return Image.create_from_data(w2, h * 2, false, Image.FORMAT_RGBA8, dst.to_byte_array())
