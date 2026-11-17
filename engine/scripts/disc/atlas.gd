class_name DiscAtlas
extends RefCounted
## Packs the texture-page regions a set of meshes uses into one or a few atlas textures.
##
## Each entry is one rectangle of one (tpage, clut) page:
##  - plain polygons: the bounding box of their UVs, edge-padded by PAD texels;
##  - texture-window polygons (GPU 0xE2, u' = (u & ~mask) | (offset & mask)): the window tile,
##    padded with wrapped copies of itself so the tile can repeat seamlessly.
## The shader samples atlas pixel  A + mod(uv, W)  where uv is the polygon's raw texel UV and
## (A, W) come from entry_param(): W = 256 for plain entries (mod is a no-op), the tile size
## for windowed ones. Atlases are upscaled once (DiscUpscale) and cached as PNG in
## user://disc_cache/<manifest sha1>/<name>_v<VERSION>_x<scale>_<n>.png.
## Bump VERSION whenever decoding, packing or upscaling changes, so old caches are ignored.

const DiscUpscaleScript := preload("res://scripts/disc/upscale.gd")

const VERSION := 3   # 3: alternate switch states and animation frames are packed too
const MAX_SIZE := 1024   # base atlas size limit; 4x upscaled = 4096
const PAD := 4
const CACHE_ROOT := "user://disc_cache"

## key -> [atlas index, x, y, u0, v0, w, h, windowed]: page texel (u0, v0) sits at base-atlas
## pixel (x, y); the rectangle is w x h texels (without padding).
var entries := {}
var base_sizes: Array = []     # Vector2i per atlas, before upscaling
var final_sizes: Array = []    # Vector2i per atlas after upscaling (images are not kept)
var textures: Array = []       # ImageTexture per atlas (with mipmaps)
var scale := 1
var stats := {"decode_ms": 0.0, "upscale_ms": 0.0, "cached": 0, "built": 0, "texels": 0, "windows": 0}

## Size of a texture-window tile along one axis, and its origin; [256, 0] when the mask does
## not form a power-of-two tile (treated as no window).
static func window_axis(mask: int, offset: int) -> Array:
	var free := ~mask & 255
	if free & (free + 1) != 0:
		return [256, 0]
	return [free + 1, offset & mask]

## Atlas key of a polygon: tpage << 16 | clut, plus the window in bits 32+ when it has one.
static func key_of(poly) -> int:
	var k: int = (poly.tpage << 16) | poly.clut
	var tw: PackedInt32Array = poly.texwin
	if tw.is_empty():
		return k
	var wu := window_axis(tw[0], tw[2])
	var wv := window_axis(tw[1], tw[3])
	if wu[0] == 256 and wv[0] == 256:
		return k
	return k | (((wu[0] >> 3) & 63) << 32) | (((wv[0] >> 3) & 63) << 38) | ((wu[1] >> 3) << 44) | ((wv[1] >> 3) << 50) | (1 << 56)

static func cache_dir(manifest_checksum: String) -> String:
	return CACHE_ROOT.path_join(manifest_checksum if manifest_checksum != "" else "nomanifest")

## meshes: DiscDmd meshes (polygons and sprites). vram: a loaded DiscVram.
## name: cache file stem (e.g. "arena_WH_part1").
static func build(meshes: Array, vram, name: String, upscale: int, manifest_checksum: String) -> DiscAtlas:
	var at := DiscAtlas.new()
	at.scale = upscale
	# 1. rectangle per key: UV bounding box, or the window tile
	var rects := {}   # key -> [u0, v0, w, h, windowed]
	for m in meshes:
		var polys: Array = m.polygons.duplicate()
		for s in m.sprites:
			polys.append(s[1])
		for p in polys:
			if not p.is_textured():
				continue
			var k := key_of(p)
			if k >> 56:
				if not rects.has(k):
					var wu := (k >> 32) & 63
					var wv := (k >> 38) & 63
					rects[k] = [((k >> 44) & 31) << 3, ((k >> 50) & 31) << 3, (wu if wu else 32) << 3, (wv if wv else 32) << 3, true]
				continue
			var b: Array = rects.get(k, [255, 255, 0, 0, false])
			for uv in p.uvs:
				var u: int = uv & 0xFF
				var v: int = (uv >> 8) & 0xFF
				b[0] = mini(b[0], u); b[1] = mini(b[1], v)
				b[2] = maxi(b[2], u); b[3] = maxi(b[3], v)
			rects[k] = b
	for k in rects:
		var r: Array = rects[k]
		if not r[4]:
			rects[k] = [r[0], r[1], r[2] - r[0] + 1, r[3] - r[1] + 1, false]
		else:
			at.stats.windows += 1
	# 2. shelf packing, tallest first (deterministic order so caches stay valid)
	var keys := rects.keys()
	keys.sort_custom(func(a, b):
		if rects[a][3] != rects[b][3]:
			return rects[a][3] > rects[b][3]
		return a < b)
	var idx := 0
	var x := 0
	var y := 0
	var shelf_h := 0
	var used := Vector2i.ZERO
	for k in keys:
		var r: Array = rects[k]
		var rw: int = r[2] + PAD * 2
		var rh: int = r[3] + PAD * 2
		if x + rw > MAX_SIZE:
			x = 0
			y += shelf_h
			shelf_h = 0
		if y + rh > MAX_SIZE:
			at.base_sizes.append(used)
			idx += 1
			x = 0
			y = 0
			shelf_h = 0
			used = Vector2i.ZERO
		at.entries[k] = [idx, x + PAD, y + PAD, r[0], r[1], r[2], r[3], r[4]]
		x += rw
		shelf_h = maxi(shelf_h, rh)
		used = Vector2i(maxi(used.x, x), maxi(used.y, y + rh))
		at.stats.texels += r[2] * r[3]
	if not keys.is_empty():
		at.base_sizes.append(used)
	for i in at.base_sizes.size():
		var s: Vector2i = at.base_sizes[i]
		at.base_sizes[i] = Vector2i((s.x + 3) & ~3, (s.y + 3) & ~3)
	# 3. images: from cache, or decoded + upscaled + saved
	var dir := cache_dir(manifest_checksum)
	DirAccess.make_dir_recursive_absolute(dir)
	for i in at.base_sizes.size():
		var want: Vector2i = at.base_sizes[i] * upscale
		var path := dir.path_join("%s_v%d_x%d_%d.png" % [name, VERSION, upscale, i])
		var img: Image = null
		if FileAccess.file_exists(path):
			img = Image.load_from_file(path)
			if img != null and img.get_size() != want:
				img = null
		if img == null:
			var t0 := Time.get_ticks_usec()
			img = at._compose(i, vram)
			var t1 := Time.get_ticks_usec()
			img = DiscUpscaleScript.upscale(img, upscale)
			img.fix_alpha_edges()
			var t2 := Time.get_ticks_usec()
			at.stats.decode_ms += (t1 - t0) / 1000.0
			at.stats.upscale_ms += (t2 - t1) / 1000.0
			img.save_png(path)
			at.stats.built += 1
		else:
			at.stats.cached += 1
		img.convert(Image.FORMAT_RGBA8)
		at.final_sizes.append(img.get_size())
		img.generate_mipmaps()
		at.textures.append(ImageTexture.create_from_image(img))
	return at

func _compose(atlas_index: int, vram) -> Image:
	var s: Vector2i = base_sizes[atlas_index]
	var img := Image.create_empty(s.x, s.y, false, Image.FORMAT_RGBA8)
	for k in entries:
		var e: Array = entries[k]
		if e[0] != atlas_index:
			continue
		var bw: int = e[5]
		var bh: int = e[6]
		var page: int = k & 0xFFFFFFFF
		var src: Image = vram.decode_rect(page >> 16, page & 0xFFFF, e[3], e[4], bw, bh, true)
		var full := Image.create_empty(bw + PAD * 2, bh + PAD * 2, false, Image.FORMAT_RGBA8)
		if e[7]:
			# windowed tile: wrap around (blit_rect clips to the image)
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					full.blit_rect(src, Rect2i(0, 0, bw, bh), Vector2i(PAD + dx * bw, PAD + dy * bh))
		else:
			# edge-extend: columns first, then full-width rows
			var mid := Image.create_empty(bw + PAD * 2, bh, false, Image.FORMAT_RGBA8)
			mid.blit_rect(src, Rect2i(0, 0, bw, bh), Vector2i(PAD, 0))
			for j in PAD:
				mid.blit_rect(src, Rect2i(0, 0, 1, bh), Vector2i(j, 0))
				mid.blit_rect(src, Rect2i(bw - 1, 0, 1, bh), Vector2i(PAD + bw + j, 0))
			full.blit_rect(mid, Rect2i(0, 0, bw + PAD * 2, bh), Vector2i(0, PAD))
			for j in PAD:
				full.blit_rect(mid, Rect2i(0, 0, bw + PAD * 2, 1), Vector2i(0, j))
				full.blit_rect(mid, Rect2i(0, bh - 1, bw + PAD * 2, 1), Vector2i(0, PAD + bh + j))
		img.blit_rect(full, Rect2i(0, 0, bw + PAD * 2, bh + PAD * 2), Vector2i(e[1] - PAD, e[2] - PAD))
	return img

func atlas_of(key: int) -> int:
	return entries[key][0] if entries.has(key) else -1

## Per-polygon shader parameters (A.x, A.y, W.x, W.y) in base-atlas pixels: the atlas pixel
## for raw texel UV t is A + mod(t, W). UVs address texel edges, so a quad spanning u 0..63
## draws texels 0..62 like the PS1 rasteriser.
func entry_param(key: int) -> Color:
	var e: Array = entries[key]
	if e[7]:
		return Color(e[1], e[2], e[5], e[6])
	return Color(e[1] - e[3], e[2] - e[4], 256, 256)

func size_of(atlas_index: int) -> Vector2:
	return Vector2(base_sizes[atlas_index])

func describe() -> String:
	var parts := PackedStringArray()
	for i in base_sizes.size():
		parts.append("%dx%d" % [final_sizes[i].x, final_sizes[i].y])
	return "%d rects (%d windowed), %d atlas(es) %s at x%d, %d texels base" % [entries.size(), stats.windows, base_sizes.size(), ", ".join(parts), scale, stats.texels]
