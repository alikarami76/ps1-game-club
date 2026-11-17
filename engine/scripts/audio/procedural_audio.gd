class_name ProceduralAudio
extends AudioProvider
## Original sounds synthesised in code (noise, sine sweeps, harmonics). No external data.

const RATE := 22050
var _cache := {}

func get_sfx(sfx_name: String) -> AudioStream:
	if not _cache.has(sfx_name):
		match sfx_name:
			"mg": _cache[sfx_name] = _mg()
			"missile": _cache[sfx_name] = _missile()
			"explosion": _cache[sfx_name] = _explosion()
			"pickup": _cache[sfx_name] = _pickup()
			"hit": _cache[sfx_name] = _hit()
			_: return null
	return _cache[sfx_name]

func get_engine() -> AudioStream:
	if not _cache.has("engine"):
		_cache["engine"] = _engine()
	return _cache["engine"]

func describe() -> String:
	return "procedural (synthesised)"

# ---- helpers ----
static func to_wav(buf: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = buf.size()
	return w

func _rng(seed_v: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	return r

func _noise(n: int, seed_v: int, lowpass: float) -> PackedFloat32Array:
	# lowpass 1.0 = white noise, smaller = darker
	var r := _rng(seed_v)
	var out := PackedFloat32Array()
	out.resize(n)
	var y := 0.0
	for i in n:
		y += (r.randf_range(-1.0, 1.0) - y) * lowpass
		out[i] = y
	return out

func _engine() -> AudioStreamWAV:
	# 0.4 s loop holding a whole number of cycles of the fundamental, so it loops cleanly.
	var n := int(RATE * 0.4)
	var cycles := 22
	var buf := PackedFloat32Array()
	buf.resize(n)
	var r := _rng(11)
	var phases: Array = []
	for h in 8:
		phases.append(r.randf() * TAU)
	for i in n:
		var ph := TAU * cycles * float(i) / n
		var s := 0.0
		for h in 8:
			s += sin(ph * (h + 1) + phases[h]) / pow(h + 1.0, 1.15)
		var wob := 0.85 + 0.15 * sin(TAU * 4.0 * float(i) / n)   # 10 Hz rumble, periodic in the loop
		buf[i] = s * 0.32 * wob
	return to_wav(buf, true)

func _mg() -> AudioStreamWAV:
	var n := int(RATE * 0.09)
	var nz := _noise(n, 3, 0.6)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for i in n:
		var t := float(i) / RATE
		buf[i] = (nz[i] * 0.8 + sin(TAU * 170.0 * t) * 0.5) * exp(-t * 45.0)
	return to_wav(buf)

func _missile() -> AudioStreamWAV:
	var n := int(RATE * 0.8)
	var nz := _noise(n, 5, 0.25)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := minf(t * 20.0, 1.0) * exp(-t * 2.2)
		ph += TAU * (90.0 + 260.0 * t) / RATE
		buf[i] = (nz[i] * 1.6 + sin(ph) * 0.4) * env * 0.7
	return to_wav(buf)

func _explosion() -> AudioStreamWAV:
	var n := int(RATE * 1.2)
	var nz := _noise(n, 7, 0.12)
	var buf := PackedFloat32Array()
	buf.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		ph += TAU * (70.0 * exp(-t * 2.0) + 28.0) / RATE
		buf[i] = (nz[i] * 2.4 + sin(ph) * 0.9) * minf(t * 200.0, 1.0) * exp(-t * 3.2) * 0.8
	return to_wav(buf)

func _pickup() -> AudioStreamWAV:
	var n := int(RATE * 0.32)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for i in n:
		var t := float(i) / RATE
		var f := 660.0 if t < 0.12 else 990.0
		var lt := t if t < 0.12 else t - 0.12
		buf[i] = sin(TAU * f * t) * exp(-lt * 12.0) * 0.5
	return to_wav(buf)

func _hit() -> AudioStreamWAV:
	var n := int(RATE * 0.14)
	var nz := _noise(n, 9, 0.5)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for i in n:
		var t := float(i) / RATE
		buf[i] = (nz[i] * 0.7 + sin(TAU * 320.0 * t) * 0.6) * exp(-t * 32.0)
	return to_wav(buf)
