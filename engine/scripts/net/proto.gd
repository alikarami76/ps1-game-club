class_name Proto
extends RefCounted
## Wire format shared by the server and the client. Every packet starts with one type byte.
##
## Control plane (lobby, rare): type CTRL + UTF-8 JSON object. Never carries game data files.
## Game stream (binary, little endian, see docs in game/README.md "Netcode"):
##   C_INPUT  client -> server, every sim tick (30 Hz), unreliable class
##   S_SNAP   server -> client, 20 Hz, unreliable class, delta against the client's last ack
##   S_EVENTS server -> client, reliable + sequence number (kills, explosions, scores, end)
##   PING/PONG for round-trip time.

const VERSION := 9   # 9: game-tick phase in the owner block; 8: wheel corners (height, vertical speed, airtime) in the owner block; 5: u32 pickup bits, vehicle ids in the lobby; 6: EV_PROP, prop bits in full snapshots; 7: driving state (speed, steering angle, travel direction, slide, reverse, stop ticks) in the owner block

# packet types
const CTRL := 0x01
const C_INPUT := 0x10
const C_PING := 0x11
const S_SNAP := 0x20
const S_EVENTS := 0x21
const S_PONG := 0x22

# simulation
const TICK_RATE := 30
const TICK_DT := 1.0 / TICK_RATE
const SNAP_RATE := 20.0
const INPUT_REDUNDANCY := 4
const MAX_SLOTS := 8

# input buttons (one byte per tick)
const B_ACCEL := 1
const B_BRAKE := 2
const B_HANDBRAKE := 4
const B_FIRE_MG := 8
const B_SPECIAL := 16       # edge-triggered on the server
const B_NEXT := 32          # edge-triggered
const B_PREV := 64          # edge-triggered
const B_TURBO := 128        # held
const B_RESET := B_ACCEL | B_BRAKE   # both pedals at once (never sent otherwise): edge-triggered unstuck

# event kinds (inside S_EVENTS)
const EV_KILL := 1          # u8 killer slot (255 = world), u8 victim slot, u8 weapon
const EV_EXPLOSION := 2     # i16 x3 pos (1/32 m), u8 radius (1/4 m)
const EV_SCORES := 3        # u8 n, n x (u8 slot, u16 kills, u16 deaths)
const EV_OVER := 4          # u8 winner slot
const EV_LEFT := 5          # u8 slot
const EV_RAM := 6           # i16 x3 pos, u8 strength
const EV_SPECIAL := 7       # u8 slot, u8 kind (0 flame, 1 shockwave) for effects
const EV_PROP := 8          # u8 target index (DiscProps), u8 state (1 = destroyed)

const WEAPON_IDS := ["Machine Gun", "Fire Missile", "Homing Missile", "Power Missile", "Freeze Missile", "Mine", "Special", "Ram", "Fall"]
const W_RAM := 7
const W_FALL := 8

# quantisation
const POS_Q := 32.0         # 1/32 m, +-1024 m in int16
const OWN_POS_Q := 1000.0   # mm, int32 (owner reconciliation needs more precision)
const VEL_Q := 100.0        # cm/s, int16
const YAWRATE_Q := 1000.0   # mrad/s, int16
const SPD_Q := 4.0          # owner driving state: signed speed in raw units (1/32 unit per game tick), int16
const STEER_Q := 16.0       # owner driving state: steering angle in raw units, int16

static func q_pos(v: float) -> int:
	return clampi(roundi(v * POS_Q), -32768, 32767)

static func q_yaw(yaw: float) -> int:
	return posmod(roundi(yaw / TAU * 65536.0), 65536)

static func dq_yaw(u: int) -> float:
	return float(u) / 65536.0 * TAU

static func q_angle8(a: float) -> int:   # +-90 degrees in int8
	return clampi(roundi(a / (PI * 0.5) * 127.0), -127, 127)

static func dq_angle8(i: int) -> float:
	return float(i) / 127.0 * PI * 0.5

static func q_steer(s: float) -> int:
	return clampi(roundi(s * 127.0), -127, 127)

## Wrap-safe "a is newer than b" for 32-bit ticks (they never wrap in practice; kept simple).
static func newer(a: int, b: int) -> bool:
	return a > b

static func ctrl(d: Dictionary) -> PackedByteArray:
	var out := PackedByteArray([CTRL])
	out.append_array(JSON.stringify(d).to_utf8_buffer())
	return out

static func parse_ctrl(p: PackedByteArray) -> Dictionary:
	if p.size() < 2:
		return {}
	var d = JSON.parse_string(p.slice(1).get_string_from_utf8())
	return d if typeof(d) == TYPE_DICTIONARY else {}

static func writer() -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	return b

static func reader(p: PackedByteArray) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = p
	return b

static func buttons_from(throttle: float, hb: bool, mg: bool, special: bool, nxt: bool, prv: bool, reset: bool, turbo := false) -> int:
	var b := 0
	if reset:
		b |= B_RESET
	elif throttle > 0.3:
		b |= B_ACCEL
	elif throttle < -0.3:
		b |= B_BRAKE
	if turbo:
		b |= B_TURBO
	if hb:
		b |= B_HANDBRAKE
	if mg:
		b |= B_FIRE_MG
	if special:
		b |= B_SPECIAL
	if nxt:
		b |= B_NEXT
	if prv:
		b |= B_PREV
	return b

static func is_reset(b: int) -> bool:
	return (b & B_RESET) == B_RESET
