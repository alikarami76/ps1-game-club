class_name WavLoader
extends RefCounted
## Reads a PCM WAV file from disk at runtime (16-bit, mono or stereo) into an AudioStreamWAV.
## Honours a "smpl" loop chunk. Returns null if the file is missing or not 16-bit PCM.
## A path ending in .ogg is read as OGG Vorbis instead (deployment copies of the music use it);
## it returns an AudioStreamOggVorbis, which plays like any other AudioStream.

static func load_file(path: String, loop_override := Vector2i(-1, -1)) -> AudioStream:
	if not FileAccess.file_exists(path):
		return null
	if path.get_extension().to_lower() == "ogg":
		return load_ogg(path)
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 44 or b.slice(0, 4).get_string_from_ascii() != "RIFF" or b.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null
	var pos := 12
	var channels := 1
	var rate := 44100
	var bits := 16
	var data_off := -1
	var data_len := 0
	var loop_a := -1
	var loop_b := -1
	while pos + 8 <= b.size():
		var cid := b.slice(pos, pos + 4).get_string_from_ascii()
		var sz := b.decode_u32(pos + 4)
		var body := pos + 8
		if cid == "fmt ":
			var tag := b.decode_u16(body)
			channels = b.decode_u16(body + 2)
			rate = b.decode_u32(body + 4)
			bits = b.decode_u16(body + 14)
			if tag != 1 and tag != 0xFFFE:
				return null
		elif cid == "data":
			data_off = body
			data_len = mini(sz, b.size() - body)
		elif cid == "smpl" and sz >= 60 and b.decode_u32(body + 28) > 0:
			loop_a = b.decode_u32(body + 44)
			loop_b = b.decode_u32(body + 48)
		pos = body + sz + (sz & 1)
	if data_off < 0 or bits != 16 or channels < 1 or channels > 2:
		return null
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = channels == 2
	w.data = b.slice(data_off, data_off + data_len)
	if loop_override.x >= 0 and loop_override.y > loop_override.x:
		loop_a = loop_override.x
		loop_b = loop_override.y
	if loop_a >= 0 and loop_b > loop_a:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = loop_a
		w.loop_end = loop_b
	return w

static func load_ogg(path: String) -> AudioStream:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 4 or bytes.slice(0, 4).get_string_from_ascii() != "OggS":
		return null
	return AudioStreamOggVorbis.load_from_buffer(bytes)
