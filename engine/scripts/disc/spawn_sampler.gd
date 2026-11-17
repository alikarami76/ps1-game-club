class_name DiscSpawnSampler
extends RefCounted
## Floor queries on an arena's collision triangles (metres, y-up), used to place spawn and
## pickup points: the ground height under a point, head-room checks, and a grid of flat,
## open floor points. Triangles are binned on an x/z grid so queries stay fast in GDScript.

const STEP := 2.0         # floor sample spacing, metres
const CELL := 4.0         # triangle binning cell, metres
const CLEARANCE := 4.0    # free height needed above a point
const UP_DOT := 0.97      # |normal.y| for "flat"
const FLOOR_TOL := 0.6    # metres from a wanted floor height

var faces := PackedVector3Array()
var lo := Vector2.ZERO
var hi := Vector2.ZERO
var nx := 0
var nz := 0
var bins: Array = []
var flat := PackedByteArray()
var main_floor_y := 0.0    # height covered by the most upward-facing area

func _init(tri_faces: PackedVector3Array) -> void:
	faces = tri_faces
	var ntri := faces.size() / 3
	lo = Vector2(INF, INF)
	hi = Vector2(-INF, -INF)
	flat.resize(ntri)
	var hist := {}
	for t in ntri:
		var a := faces[t * 3]
		var b := faces[t * 3 + 1]
		var c := faces[t * 3 + 2]
		lo = Vector2(minf(lo.x, minf(a.x, minf(b.x, c.x))), minf(lo.y, minf(a.z, minf(b.z, c.z))))
		hi = Vector2(maxf(hi.x, maxf(a.x, maxf(b.x, c.x))), maxf(hi.y, maxf(a.z, maxf(b.z, c.z))))
		var n := (b - a).cross(c - a)
		var len := n.length()
		if len > 1e-6 and absf(n.y / len) >= UP_DOT:
			flat[t] = 1
			var k := roundi((a.y + b.y + c.y) / 3.0 / 0.25)
			hist[k] = hist.get(k, 0.0) + len * 0.5
	var best_w := -1.0
	for k in hist:
		if hist[k] > best_w:
			best_w = hist[k]
			main_floor_y = k * 0.25
	if ntri == 0:
		lo = Vector2.ZERO
		hi = Vector2.ZERO
	nx = int((hi.x - lo.x) / CELL) + 1
	nz = int((hi.y - lo.y) / CELL) + 1
	bins.resize(nx * nz)
	for i in bins.size():
		bins[i] = PackedInt32Array()
	for t in ntri:
		var a := faces[t * 3]
		var b := faces[t * 3 + 1]
		var c := faces[t * 3 + 2]
		var x0 := int((minf(a.x, minf(b.x, c.x)) - lo.x) / CELL)
		var x1 := int((maxf(a.x, maxf(b.x, c.x)) - lo.x) / CELL)
		var z0 := int((minf(a.z, minf(b.z, c.z)) - lo.y) / CELL)
		var z1 := int((maxf(a.z, maxf(b.z, c.z)) - lo.y) / CELL)
		for zi in range(z0, z1 + 1):
			for xi in range(x0, x1 + 1):
				var arr: PackedInt32Array = bins[zi * nx + xi]
				arr.append(t)
				bins[zi * nx + xi] = arr

## [height, is_flat] of every triangle above or below (x, z).
func hits_at(x: float, z: float) -> Array:
	var out: Array = []
	var xi := int((x - lo.x) / CELL)
	var zi := int((z - lo.y) / CELL)
	if xi < 0 or zi < 0 or xi >= nx or zi >= nz:
		return out
	for t in bins[zi * nx + xi]:
		var h := _height_at(t, x, z)
		if not is_nan(h):
			out.append([h, flat[t] == 1])
	return out

## Highest flat surface at (x, z) no higher than below + 0.5; NAN when there is none.
func ground_at(x: float, z: float, below := INF) -> float:
	var best := NAN
	for h in hits_at(x, z):
		if h[1] and h[0] <= below + 0.5 and (is_nan(best) or h[0] > best):
			best = h[0]
	return best

## True when nothing lies between h + 0.1 and h + CLEARANCE above (x, z).
func clear_above(x: float, z: float, h: float) -> bool:
	for hit in hits_at(x, z):
		if hit[0] > h + 0.1 and hit[0] < h + CLEARANCE:
			return false
	return true

## Grid points (x, floor height, z) on flat open floor within FLOOR_TOL of one of the wanted
## heights, whose four neighbours are floor too (keeps a margin from walls). area (x/z rect in
## metres, optional) limits the search.
func floor_points(heights: Array, area := Rect2()) -> Array:
	var a_lo := lo
	var a_hi := hi
	if area.has_area():
		a_lo = Vector2(maxf(lo.x, area.position.x), maxf(lo.y, area.position.y))
		a_hi = Vector2(minf(hi.x, area.end.x), minf(hi.y, area.end.y))
	var gx := maxi(int((a_hi.x - a_lo.x) / STEP), 0)
	var gz := maxi(int((a_hi.y - a_lo.y) / STEP), 0)
	var hgt := PackedFloat32Array()
	hgt.resize(gx * gz)
	hgt.fill(NAN)
	for zi in gz:
		for xi in gx:
			var px := a_lo.x + (xi + 0.5) * STEP
			var pz := a_lo.y + (zi + 0.5) * STEP
			var fh := NAN
			for hit in hits_at(px, pz):
				if not hit[1]:
					continue
				for want in heights:
					if absf(hit[0] - want) < FLOOR_TOL and (is_nan(fh) or hit[0] > fh):
						fh = hit[0]
			if not is_nan(fh) and clear_above(px, pz, fh):
				hgt[zi * gx + xi] = fh
	var out: Array = []
	for zi in range(1, gz - 1):
		for xi in range(1, gx - 1):
			var i := zi * gx + xi
			if not is_nan(hgt[i]) and not is_nan(hgt[i - 1]) and not is_nan(hgt[i + 1]) and not is_nan(hgt[i - gx]) and not is_nan(hgt[i + gx]):
				out.append(Vector3(a_lo.x + (xi + 0.5) * STEP, hgt[i], a_lo.y + (zi + 0.5) * STEP))
	return out

## The largest 4-connected patch of floor_points() output (STEP grid).
static func largest_patch(pts: Array) -> Array:
	var index := {}
	for i in pts.size():
		var p: Vector3 = pts[i]
		index[Vector2i(roundi(p.x / STEP * 2), roundi(p.z / STEP * 2))] = i
	var seen := PackedByteArray()
	seen.resize(pts.size())
	var best: Array = []
	for start in pts.size():
		if seen[start]:
			continue
		var members: Array = [start]
		seen[start] = 1
		var head := 0
		while head < members.size():
			var p: Vector3 = pts[members[head]]
			head += 1
			var k := Vector2i(roundi(p.x / STEP * 2), roundi(p.z / STEP * 2))
			for d in [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2)]:
				var j: int = index.get(k + d, -1)
				if j >= 0 and not seen[j]:
					seen[j] = 1
					members.append(j)
		if members.size() > best.size():
			best = members
	return best.map(func(i): return pts[i])

## Farthest-point sampling: n points from pts, each as far as possible from the seeds and the
## points already chosen. With no seeds it starts from the point farthest from the centroid.
static func farthest_points(pts: Array, seeds: Array, n: int) -> Array:
	var out: Array = []
	if pts.is_empty() or n <= 0:
		return out
	var dist := PackedFloat32Array()
	dist.resize(pts.size())
	dist.fill(INF)
	var chosen: Array = seeds.duplicate()
	if chosen.is_empty():
		var centre := Vector3.ZERO
		for p in pts:
			centre += p
		centre /= pts.size()
		var far := -1.0
		var first: Vector3 = pts[0]
		for p in pts:
			if p.distance_squared_to(centre) > far:
				far = p.distance_squared_to(centre)
				first = p
		out.append(first)
		chosen.append(first)
	for s in chosen:
		for i in pts.size():
			dist[i] = minf(dist[i], pts[i].distance_squared_to(s))
	while out.size() < mini(n, pts.size()):
		var best := 0
		for i in pts.size():
			if dist[i] > dist[best]:
				best = i
		var p: Vector3 = pts[best]
		out.append(p)
		for i in pts.size():
			dist[i] = minf(dist[i], pts[i].distance_squared_to(p))
	return out

## Height of triangle t at (x, z), or NAN when (x, z) is outside it.
func _height_at(t: int, x: float, z: float) -> float:
	var a := faces[t * 3]
	var b := faces[t * 3 + 1]
	var c := faces[t * 3 + 2]
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1e-9:
		return NAN
	var l1 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
	var l2 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
	var l3 := 1.0 - l1 - l2
	if l1 < -1e-4 or l2 < -1e-4 or l3 < -1e-4:
		return NAN
	return l1 * a.y + l2 * b.y + l3 * c.y
