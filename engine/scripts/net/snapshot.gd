class_name Snapshot
extends RefCounted
## Quantised world state and its delta encoding.
##
## A world state is {"v": {slot: PackedInt32Array(V_LEN)}, "p": {id: PackedInt32Array(P_LEN)}}.
## Values are already quantised, so "changed" means "the client would decode something
## different", and delta + base reproduces the full state exactly.
##
## S_SNAP layout (little endian):
##   u8 type, u32 tick, u32 base_tick (0 = full), u32 ack_input_tick, u8 seq, u8 flags
##   (bit0 started, bit1 over), u16 time_left (1/10 s), u32 pickup bits (MAX_PICKUPS)
##   owner block: u8 present; if 1: i32 x,y,z (mm), u16 yaw, i16 yaw_rate (mrad/s),
##     i16 vx,vy,vz (cm/s), u8 oflags (bit0 alive, bit1 grounded, bit2 gun locked, bit3 sliding,
##     bit4 reverse mode),
##     u32 ammo (4 bits each: fire, homing, power, freeze, mine; bits 20-24 special energy),
##     u8 weapon, u8 heat, u8 turbo (1/30 s), u8 frozen (1/30 s),
##     driving state: i16 spd (1/4 raw unit), i16 steer angle (1/16), u16 travel yaw, u8 stop ticks,
##     wheel corners FL FR RL RR: i16 height - y (mm), i16 vertical speed (cm/s), u8 airtime (1/4 tick, 255 = on the ground), u8 game-tick phase (1/240)  (61 bytes)
##   u8 nv, nv x (u8 slot, u8 mask, fields by mask)
##     mask bit0 pos i16 x3 (1/32 m) | bit1 yaw u16 | bit2 tilt i8 pitch, i8 roll | bit3 hp u8
##     | bit4 armor u8 | bit5 state u8 (bit0 alive, bit1 protect, bit2 firing mg,
##     bit3-5 weapon, bit6 frozen, bit7 turbo) | bit7 removed
##   u8 np, np x (u16 id, u8 mask, fields)
##     mask bit0 pos i16 x3 | bit1 yaw u16 + pitch i8 | bit2 kind u8 + owner slot u8 | bit7 removed
##   full snapshots only (base_tick 0), when the arena has destructible props: u8 n, n bytes of
##     destroyed-prop bits (target i = bit i % 8 of byte i / 8); hdr.props on both sides

# vehicle fields
const VX := 0
const VY := 1
const VZ := 2
const VYAW := 3
const VPITCH := 4
const VROLL := 5
const VHP := 6
const VARMOR := 7
const VSTATE := 8
const V_LEN := 9
# projectile fields
const PX := 0
const PY := 1
const PZ := 2
const PYAW := 3
const PPITCH := 4
const PKIND := 5
const POWNER := 6
const P_LEN := 7
const MAX_PICKUPS := 32   # one bit each in the header

const ST_ALIVE := 1
const ST_PROTECT := 2
const ST_FIRING := 4
const ST_FROZEN := 64
const ST_TURBO := 128

static func empty_state() -> Dictionary:
	return {"v": {}, "p": {}}

static func _vmask(cur: PackedInt32Array, base) -> int:
	if base == null:
		return 0x3F
	var b: PackedInt32Array = base
	var m := 0
	if cur[VX] != b[VX] or cur[VY] != b[VY] or cur[VZ] != b[VZ]:
		m |= 1
	if cur[VYAW] != b[VYAW]:
		m |= 2
	if cur[VPITCH] != b[VPITCH] or cur[VROLL] != b[VROLL]:
		m |= 4
	if cur[VHP] != b[VHP]:
		m |= 8
	if cur[VARMOR] != b[VARMOR]:
		m |= 16
	if cur[VSTATE] != b[VSTATE]:
		m |= 32
	return m

static func _pmask(cur: PackedInt32Array, base) -> int:
	if base == null:
		return 7
	var b: PackedInt32Array = base
	var m := 0
	if cur[PX] != b[PX] or cur[PY] != b[PY] or cur[PZ] != b[PZ]:
		m |= 1
	if cur[PYAW] != b[PYAW] or cur[PPITCH] != b[PPITCH]:
		m |= 2
	if cur[PKIND] != b[PKIND] or cur[POWNER] != b[POWNER]:
		m |= 4
	return m

## hdr: tick, base_tick, ack, seq, flags, time_left, pickups. own: {} or the owner block values.
static func encode(cur: Dictionary, base, hdr: Dictionary, own: Dictionary) -> PackedByteArray:
	var w := Proto.writer()
	w.put_u8(Proto.S_SNAP)
	w.put_u32(hdr.tick)
	w.put_u32(hdr.base_tick if base != null else 0)
	w.put_u32(hdr.ack)
	w.put_u8(hdr.seq & 0xFF)
	w.put_u8(hdr.flags)
	w.put_u16(clampi(roundi(hdr.time_left * 10.0), 0, 65535))
	w.put_u32(hdr.pickups & 0xFFFFFFFF)
	if own.is_empty():
		w.put_u8(0)
	else:
		w.put_u8(1)
		var p: Vector3 = own.pos
		w.put_32(roundi(p.x * Proto.OWN_POS_Q))
		w.put_32(roundi(p.y * Proto.OWN_POS_Q))
		w.put_32(roundi(p.z * Proto.OWN_POS_Q))
		w.put_u16(Proto.q_yaw(own.yaw))
		w.put_16(clampi(roundi(own.yaw_rate * Proto.YAWRATE_Q), -32768, 32767))
		var v: Vector3 = own.vel
		w.put_16(clampi(roundi(v.x * Proto.VEL_Q), -32768, 32767))
		w.put_16(clampi(roundi(v.y * Proto.VEL_Q), -32768, 32767))
		w.put_16(clampi(roundi(v.z * Proto.VEL_Q), -32768, 32767))
		w.put_u8((1 if own.alive else 0) | (2 if own.grounded else 0) | (4 if own.locked else 0) | (8 if own.get("sliding", false) else 0) | (16 if own.get("reverse_mode", false) else 0))
		var a: Array = own.ammo
		var packed := 0
		for i in 5:
			packed |= mini(a[i + 1], 15) << (4 * i)
		packed |= mini(own.energy, 31) << 20
		w.put_u32(packed)
		w.put_u8(own.weapon)
		w.put_u8(clampi(roundi(own.heat), 0, 255))
		w.put_u8(clampi(roundi(own.turbo * 30.0), 0, 255))
		w.put_u8(clampi(ceili(own.frozen * 30.0), 0, 255))
		w.put_16(clampi(roundi(own.get("spd", 0.0) * Proto.SPD_Q), -32768, 32767))
		w.put_16(clampi(roundi(own.get("steer_s", 0.0) * Proto.STEER_Q), -32768, 32767))
		w.put_u16(Proto.q_yaw(own.get("travel", own.yaw)))
		w.put_u8(clampi(roundi(own.get("stop_ticks", 0.0)), 0, 255))
		var wh: PackedFloat32Array = own.get("wh", PackedFloat32Array([0, 0, 0, 0]))
		var wv: PackedFloat32Array = own.get("wv", PackedFloat32Array([0, 0, 0, 0]))
		var wn: PackedFloat32Array = own.get("wn", PackedFloat32Array([-1, -1, -1, -1]))
		for i in 4:
			w.put_16(clampi(roundi((wh[i] - p.y) * Proto.OWN_POS_Q), -32768, 32767))
			w.put_16(clampi(roundi(wv[i] * Proto.VEL_Q), -32768, 32767))
			w.put_u8(255 if wn[i] < 0.0 else clampi(roundi(wn[i] * 4.0), 0, 254))
		w.put_u8(clampi(roundi(float(own.get("phase", 0.0)) * 240.0), 0, 239))
	# vehicles
	var bv: Dictionary = base.v if base != null else {}
	var vlist: Array = []
	for slot in cur.v:
		var m := _vmask(cur.v[slot], bv.get(slot))
		if m != 0:
			vlist.append([slot, m])
	for slot in bv:
		if not cur.v.has(slot):
			vlist.append([slot, 0x80])
	w.put_u8(vlist.size())
	for e in vlist:
		w.put_u8(e[0])
		w.put_u8(e[1])
		if e[1] & 0x80:
			continue
		var s: PackedInt32Array = cur.v[e[0]]
		var m: int = e[1]
		if m & 1:
			w.put_16(s[VX]); w.put_16(s[VY]); w.put_16(s[VZ])
		if m & 2:
			w.put_u16(s[VYAW])
		if m & 4:
			w.put_8(s[VPITCH]); w.put_8(s[VROLL])
		if m & 8:
			w.put_u8(s[VHP])
		if m & 16:
			w.put_u8(s[VARMOR])
		if m & 32:
			w.put_u8(s[VSTATE])
	# projectiles
	var bp: Dictionary = base.p if base != null else {}
	var plist: Array = []
	for id in cur.p:
		var pm := _pmask(cur.p[id], bp.get(id))
		if pm != 0:
			plist.append([id, pm])
	for id in bp:
		if not cur.p.has(id):
			plist.append([id, 0x80])
	plist = plist.slice(0, 255)
	w.put_u8(plist.size())
	for e in plist:
		w.put_u16(e[0])
		w.put_u8(e[1])
		if e[1] & 0x80:
			continue
		var s2: PackedInt32Array = cur.p[e[0]]
		var m2: int = e[1]
		if m2 & 1:
			w.put_16(s2[PX]); w.put_16(s2[PY]); w.put_16(s2[PZ])
		if m2 & 2:
			w.put_u16(s2[PYAW]); w.put_8(s2[PPITCH])
		if m2 & 4:
			w.put_u8(s2[PKIND]); w.put_u8(s2[POWNER])
	var props: PackedByteArray = hdr.get("props", PackedByteArray())
	if base == null and not props.is_empty():
		w.put_u8(mini(props.size(), 255))
		w.put_data(props.slice(0, 255))
	return w.data_array

## Reads the header only (to find the base tick before decoding).
static func peek_base(p: PackedByteArray) -> int:
	if p.size() < 9:
		return -1
	return p.decode_u32(5)

## Decodes against base (a world state, or null when base_tick is 0). Returns
## {"hdr":..., "own":..., "state":...} or {} when the packet is malformed.
static func decode(p: PackedByteArray, base) -> Dictionary:
	var r := Proto.reader(p)
	if p.size() < 20 or r.get_u8() != Proto.S_SNAP:
		return {}
	var hdr := {}
	hdr.tick = r.get_u32()
	hdr.base_tick = r.get_u32()
	hdr.ack = r.get_u32()
	hdr.seq = r.get_u8()
	hdr.flags = r.get_u8()
	hdr.time_left = r.get_u16() / 10.0
	hdr.pickups = r.get_u32()
	var own := {}
	if r.get_u8() == 1:
		own.pos = Vector3(r.get_32(), r.get_32(), r.get_32()) / Proto.OWN_POS_Q
		own.yaw = Proto.dq_yaw(r.get_u16())
		own.yaw_rate = r.get_16() / Proto.YAWRATE_Q
		own.vel = Vector3(r.get_16(), r.get_16(), r.get_16()) / Proto.VEL_Q
		var of := r.get_u8()
		own.alive = (of & 1) != 0
		own.grounded = (of & 2) != 0
		own.locked = (of & 4) != 0
		own.sliding = (of & 8) != 0
		own.reverse_mode = (of & 16) != 0
		var am := r.get_u32()
		own.ammo = [0]
		for i in 5:
			own.ammo.append((am >> (4 * i)) & 15)
		own.ammo.append(0)
		own.energy = (am >> 20) & 31
		own.weapon = r.get_u8()
		own.heat = float(r.get_u8())
		own.turbo = r.get_u8() / 30.0
		own.frozen = r.get_u8() / 30.0
		own.spd = r.get_16() / Proto.SPD_Q
		own.steer_s = r.get_16() / Proto.STEER_Q
		own.travel = Proto.dq_yaw(r.get_u16())
		own.stop_ticks = float(r.get_u8())
		var wh := PackedFloat32Array([0, 0, 0, 0])
		var wv := PackedFloat32Array([0, 0, 0, 0])
		var wn := PackedFloat32Array([0, 0, 0, 0])
		for i in 4:
			wh[i] = own.pos.y + r.get_16() / Proto.OWN_POS_Q
			wv[i] = r.get_16() / Proto.VEL_Q
			var a := r.get_u8()
			wn[i] = -1.0 if a == 255 else a / 4.0
		own.wh = wh
		own.phase = r.get_u8() / 240.0
		own.wv = wv
		own.wn = wn
	var st := empty_state()
	if base != null:
		for k in base.v:
			st.v[k] = (base.v[k] as PackedInt32Array).duplicate()
		for k in base.p:
			st.p[k] = (base.p[k] as PackedInt32Array).duplicate()
	var nv := r.get_u8()
	for i in nv:
		var slot := r.get_u8()
		var m := r.get_u8()
		if m & 0x80:
			st.v.erase(slot)
			continue
		var s: PackedInt32Array = st.v.get(slot, PackedInt32Array())
		if s.is_empty():
			s.resize(V_LEN)
		if m & 1:
			s[VX] = r.get_16(); s[VY] = r.get_16(); s[VZ] = r.get_16()
		if m & 2:
			s[VYAW] = r.get_u16()
		if m & 4:
			s[VPITCH] = r.get_8(); s[VROLL] = r.get_8()
		if m & 8:
			s[VHP] = r.get_u8()
		if m & 16:
			s[VARMOR] = r.get_u8()
		if m & 32:
			s[VSTATE] = r.get_u8()
		st.v[slot] = s
	var np := r.get_u8()
	for i in np:
		var id := r.get_u16()
		var m2 := r.get_u8()
		if m2 & 0x80:
			st.p.erase(id)
			continue
		var s2: PackedInt32Array = st.p.get(id, PackedInt32Array())
		if s2.is_empty():
			s2.resize(P_LEN)
		if m2 & 1:
			s2[PX] = r.get_16(); s2[PY] = r.get_16(); s2[PZ] = r.get_16()
		if m2 & 2:
			s2[PYAW] = r.get_u16(); s2[PPITCH] = r.get_8()
		if m2 & 4:
			s2[PKIND] = r.get_u8(); s2[POWNER] = r.get_u8()
		st.p[id] = s2
	if r.get_position() > p.size():
		return {}
	if hdr.base_tick == 0 and r.get_available_bytes() >= 1:
		var nb := r.get_u8()
		if r.get_available_bytes() >= nb:
			hdr.props = r.get_data(nb)[1]
	return {"hdr": hdr, "own": own, "state": st}

static func pos_of(s: PackedInt32Array) -> Vector3:
	return Vector3(s[0], s[1], s[2]) / Proto.POS_Q
