class_name VehicleProfile
extends RefCounted
## Driving, health, turbo and special-weapon numbers for one vehicle, in metres and seconds.
##
## Measured data (data/tuning.json, explained in games/twisted-metal/data/TUNING.md) is stored in the units the
## original game used: world units, raw speed (1/32 world unit per tick), 20 ticks per second,
## yaw units (4096 per turn). This class converts them with ONE scale constant:
## metres_per_unit (1/32 m per world unit, the scale the disc arenas and car models are built at).
##
## Turning model (measured): the steady yaw rate is proportional to speed, so each vehicle
## turns on a near-constant circle of radius turn_radius; the yaw rate ramps in at
## steer_rampup rad/s^2. The handbrake multiplies the yaw rate (x2 or x3) and slows the car.

const TICK_RATE := 20.0
const DEFAULT_METRES_PER_UNIT := 1.0 / 32.0   # same scale as the disc arenas and car models (DiscMeshBuilder.WORLD_UNIT_M)
## 1 world unit = metres_per_unit metres. The only place the unit scale lives.
static var metres_per_unit := DEFAULT_METRES_PER_UNIT
const YAW_UNITS := 4096.0

var id := ""
var display_name := "Vehicle"
var source := "builtin"          # "builtin" or "disc"

# driving (SI)
var top_speed := 18.0            # m/s
var accel_rest := 12.0           # m/s^2 from standstill
var accel_k := 0.0               # 1/s; when > 0: accel = accel_k * (v_inf - v) (measured model)
var v_inf := 0.0                 # m/s, asymptote of the measured acceleration model
var brake_decel_v := 18.0        # m/s^2
var coast_decel_v := 6.0         # m/s^2
var handbrake_decel := 6.0       # m/s^2 (handbrake alone)
var reverse_speed := 5.0         # m/s (not measured: every reverse run hit a wall)
var turn_radius := 5.0           # m
var steer_rampup := 3.0          # rad/s^2
var handbrake_turn_mult := 3.0
var mass := 1.0                  # relative, for ramming
# wheel contact points (the original's per-vehicle four corners, metres): half track, front and
# rear distance from the body origin, ride height
var wheel_track := 0.9
var wheel_front := 1.75
var wheel_rear := 2.3
var ride_height := 1.0
var ram_damage := 1.0            # health taken from the rammed car on contact (measured per vehicle)
var ram_push := 1.0              # per game tick while it keeps pushing
# health and turbo
var max_health := 100.0
var turbo_tanks := 2
var turbo_tank_time := 3.0       # s per tank (60 ticks)
var turbo_speed_mult := 1.5
var turbo_accel_mult := 3.0
# special weapon (energy pool shared rules: 20 max, +1 every 81 ticks)
var special_kind := "bolt"       # bolt, salvo, flame, shockwave, heavy
var special_damage := 12.0
var special_speed := 60.0        # m/s for projectiles
var special_cost := 5
var special_name := "Bolt"

var unmeasured: PackedStringArray = []

## The original's own driving constants (per-vehicle parameter block, read from RAM on the
## player's disc; see games/twisted-metal/data/TUNING.md "Driving model"). Raw speed units (1/32 world unit per
## tick), steer units, yaw units (4096 per turn), per game tick. Keys:
##   accel_rest, accel_top: acceleration at rest / at top speed (linear in between)
##   top, reverse_top: top speed forward / in reverse
##   brake: brake strength (added to coasting drag), also the scrub and slide-friction unit
##   slide_speed: above this speed a hard turn or the handbrake starts a slide
##   slide_exit: below this speed a slide ends
##   steer_fast, steer_slow: steering-angle change per tick at >= 1440 raw speed / at rest
##   steer_max: steering-angle limit; hb_mult: handbrake multiplies rate and limit
##   steer_div: yaw per tick = (speed / 32) * angle / steer_div
##   slide_yaw: yaw rate (units per tick) that breaks grip; scrub: speed-loss threshold term
var drive := {}

const DRIVE_KEYS := ["accel_rest", "accel_top", "top", "reverse_top", "brake", "slide_speed", "slide_exit",
	"steer_fast", "steer_slow", "steer_max", "hb_mult", "steer_div", "slide_yaw", "scrub"]

static func ms_to_raw(v: float) -> float:
	return v / (TICK_RATE * metres_per_unit) * 32.0

## Fills drive{} for profiles without measured constants (built-in stand-ins), from the SI numbers.
func derive_drive() -> void:
	if drive.size() == DRIVE_KEYS.size():
		return
	var a8 := ms_to_raw(top_speed)
	var a4 := ms_to_raw(accel_rest) / TICK_RATE * 1.85   # the linear model reaches 90 % later; keeps the stand-in's t90
	var r_units := turn_radius / metres_per_unit
	var d := {"accel_rest": a4, "accel_top": a4 / 6.0, "top": a8, "reverse_top": a8 * 2.0 / 3.0,
		"brake": maxf(ms_to_raw(brake_decel_v) / TICK_RATE - a4 / 6.0, 10.0), "slide_speed": a8 * 0.5,
		"slide_exit": a4 * 3.0, "steer_fast": 6.0, "steer_slow": 30.0, "steer_max": 150.0,
		"hb_mult": handbrake_turn_mult, "steer_div": r_units * 150.0 * TAU / YAW_UNITS, "slide_yaw": 75.0, "scrub": 120.0}
	for k in DRIVE_KEYS:
		if not drive.has(k):
			drive[k] = d[k]

static func u_to_m(units: float) -> float:
	return units * metres_per_unit

## Raw speed (1/32 world unit per tick) to m/s.
static func raw_to_ms(raw: float) -> float:
	return raw / 32.0 * TICK_RATE * metres_per_unit

## Raw speed change per tick to m/s^2.
static func raw_accel_to_ms2(raw_per_tick: float) -> float:
	return raw_to_ms(raw_per_tick) * TICK_RATE

## Speed per tick in world units to m/s.
static func speed_to_ms(units_per_tick: float) -> float:
	return units_per_tick * TICK_RATE * metres_per_unit

static func ticks_to_s(ticks: float) -> float:
	return ticks / TICK_RATE

## Yaw units per tick per tick to rad/s^2.
static func yaw_accel_to_rad(u: float) -> float:
	return u / YAW_UNITS * TAU * TICK_RATE * TICK_RATE

# ---- values used by vehicle.gd ----
## Forward acceleration (m/s^2) at forward speed v (m/s), the original's model: linear from
## accel_rest at a standstill to accel_top at top speed.
func accel_at(v: float) -> float:
	var D := drive
	if D.is_empty():
		return accel_rest
	var vr := ms_to_raw(v)
	var a: float = D.accel_rest - (D.accel_rest - D.accel_top) * absf(vr) / maxf(float(D.top), vr)
	return raw_accel_to_ms2(a) if vr < float(D.top) else 0.0

## Braking deceleration (m/s^2) at speed v: brake plus rolling drag.
func brake_decel(v := -1.0) -> float:
	if drive.is_empty():
		return brake_decel_v
	var vr := ms_to_raw(v if v >= 0.0 else top_speed)
	return raw_accel_to_ms2(float(drive.brake) + coast_raw(vr))

func coast_raw(vr: float) -> float:
	return maxf((float(drive.brake) - float(drive.accel_top)) * absf(vr) / maxf(float(drive.top), absf(vr)) / 2.0, float(drive.accel_top))

func coast_decel() -> float:
	return raw_accel_to_ms2(coast_raw(ms_to_raw(top_speed))) if not drive.is_empty() else coast_decel_v

func reverse_accel() -> float:
	return accel_rest

## Steady yaw rate (rad/s) at full steer for a forward speed in m/s: constant turning circle.
func yaw_rate(speed: float) -> float:
	return absf(speed) / maxf(turn_radius, 0.5)

## Time to 90 % of top speed from standstill (s), from the acceleration model.
func time_to_90() -> float:
	var v := 0.0
	var t := 0.0
	var dt := 1.0 / 240.0
	while v < 0.9 * top_speed and t < 30.0:
		v = minf(v + accel_at(v) * dt, top_speed + 0.01)
		t += dt
	return t

## Built-in stand-in from a VehicleProfiles.BUILTIN entry (original numbers in SI units).
static func from_builtin(entry_id: String, e: Dictionary) -> VehicleProfile:
	var p := VehicleProfile.new()
	p.id = entry_id
	p.display_name = str(e.name)
	p.top_speed = float(e.top_speed)
	p.accel_rest = 0.9 * p.top_speed / float(e.t90)
	p.brake_decel_v = p.top_speed / float(e.brake_time)
	p.coast_decel_v = p.top_speed / float(e.coast_time)
	p.handbrake_decel = p.coast_decel_v
	p.reverse_speed = p.top_speed * 0.3
	p.turn_radius = float(e.turn_radius)
	p.steer_rampup = float(e.steer_rampup)
	p.handbrake_turn_mult = float(e.get("handbrake_mult", 3.0))
	p.mass = float(e.mass)
	p.ram_damage = 4.0 if p.mass >= 1.3 else 1.0
	p.ram_push = 2.0 if p.mass >= 1.3 else 1.0
	p.max_health = float(e.health)
	var sp: Dictionary = e.special
	p.special_kind = str(sp.kind)
	p.special_name = str(sp.name)
	p.special_damage = float(sp.damage)
	p.special_speed = float(sp.get("speed", 60.0))
	p.special_cost = int(sp.cost)
	p.derive_drive()
	return p

## Build from one vehicle entry in data/tuning.json (measured on the player's own disc).
## Old-format entries (top_speed_per_tick, ticks_to_90pct, ...) still load.
static func from_tuning_entry(entry_id: String, e: Dictionary, pname := "") -> VehicleProfile:
	var p := VehicleProfile.new()
	p.id = entry_id
	p.display_name = pname if pname != "" else entry_id
	p.source = "disc"
	if e.has("top_speed_raw"):
		p.top_speed = raw_to_ms(float(e.top_speed_raw))
	else:
		p.top_speed = speed_to_ms(float(e.get("top_speed_per_tick", 55.0)))
	if e.has("accel_from_rest_raw_per_tick"):
		p.accel_rest = raw_accel_to_ms2(float(e.accel_from_rest_raw_per_tick))
		var am = e.get("accel_model")
		if typeof(am) == TYPE_DICTIONARY and am.has("k") and am.has("v_inf_raw"):
			p.accel_k = float(am.k) * TICK_RATE
			p.v_inf = raw_to_ms(float(am.v_inf_raw))
	else:
		p.accel_rest = 0.9 * p.top_speed / ticks_to_s(float(e.get("ticks_to_90pct", 25)))
	if e.has("brake_decel_raw_per_tick"):
		p.brake_decel_v = raw_accel_to_ms2(float(e.brake_decel_raw_per_tick))
	else:
		p.brake_decel_v = p.top_speed / ticks_to_s(float(e.get("ticks_to_stop", 22)))
	var coast = e.get("coast_decel_raw_per_tick_near_top")
	p.coast_decel_v = raw_accel_to_ms2(float(coast)) if coast != null else p.brake_decel_v / 1.6
	var hbd = e.get("handbrake_only_decel_raw_per_tick")
	p.handbrake_decel = raw_accel_to_ms2(float(hbd)) if hbd != null else p.coast_decel_v
	if e.has("reverse_speed_per_tick"):
		p.reverse_speed = speed_to_ms(float(e.reverse_speed_per_tick))
	else:
		p.reverse_speed = p.top_speed * 0.3
		p.unmeasured.append("reverse_speed")
	if e.has("turn_radius_world_units"):
		p.turn_radius = u_to_m(float(e.turn_radius_world_units))
	elif e.has("speed_per_yaw_unit"):
		# yaw units/tick = raw / ratio -> radius = (raw/32 units/tick) / (rad/tick)
		p.turn_radius = u_to_m(float(e.speed_per_yaw_unit) / 32.0 * YAW_UNITS / TAU)
	if e.has("steer_rampup_yaw_units_per_tick2"):
		p.steer_rampup = yaw_accel_to_rad(float(e.steer_rampup_yaw_units_per_tick2))
	p.handbrake_turn_mult = float(e.get("handbrake_turn_multiplier", 3))
	p.max_health = float(e.get("max_health", 100))
	p.mass = clampf(p.max_health / 110.0, 0.85, 1.4)
	p.ram_damage = float(e.get("ram_damage", 1))
	var wh = e.get("wheels")
	if typeof(wh) == TYPE_DICTIONARY:
		p.wheel_track = u_to_m(float(wh.half_track))
		p.wheel_front = u_to_m(float(wh.front))
		p.wheel_rear = u_to_m(float(wh.rear))
		p.ride_height = u_to_m(float(wh.ride))
	p.ram_push = float(e.get("ram_push_damage_per_tick", 1))
	if e.has("turbo_extra_accel_raw_per_tick") and e.has("accel_from_rest_raw_per_tick"):
		p.turbo_accel_mult = float(e.turbo_extra_accel_raw_per_tick) / maxf(float(e.accel_from_rest_raw_per_tick), 1.0)
	if e.has("turbo_top_speed_raw") and e.has("top_speed_raw"):
		p.turbo_speed_mult = float(e.turbo_top_speed_raw) / float(e.top_speed_raw)
	var dp = e.get("drive_params")
	if typeof(dp) == TYPE_DICTIONARY:
		for k in DRIVE_KEYS:
			if dp.has(k):
				p.drive[k] = float(dp[k])
		p.reverse_speed = raw_to_ms(float(dp.get("reverse_top", 0.0)) * 1.03) if dp.has("reverse_top") else p.reverse_speed
	p.derive_drive()
	var sp = e.get("special")
	if typeof(sp) == TYPE_DICTIONARY:
		var note := str(sp.get("note", ""))
		var kind := str(sp.get("kind", ""))   # game/data/tuning.json carries the kind instead of notes
		if kind == "salvo":
			note = "several"
		elif kind == "flame":
			note = "stream"
		p.special_cost = int(sp.cost) if sp.get("cost") != null else 6
		if sp.get("damage") != null and sp.get("speed") != null:
			p.special_kind = "salvo" if note.contains("several") else "bolt"
			p.special_damage = float(sp.damage) / (3.0 if p.special_kind == "salvo" else 1.0)
			p.special_speed = speed_to_ms(float(sp.speed))
		elif note.contains("stream"):
			p.special_kind = "flame"
			p.special_damage = 20.0     # damage per second at close range (1 per game tick)
		elif sp.get("damage") != null:
			p.special_kind = "shockwave"
			p.special_damage = float(sp.damage)
		else:
			p.special_kind = "shockwave"   # trigger unknown on the disc: stand-in, not measured
			p.special_damage = 10.0
			p.unmeasured.append("special")
		p.special_name = p.special_kind.capitalize()
	return p

func describe() -> String:
	return "%s top=%.2f m/s t90=%.2fs brake=%.1f m/s2 coast=%.1f m/s2 radius=%.2f m rampup=%.1f rad/s2 hb_turn=x%.0f hp=%.0f special=%s(%.0f, cost %d)" % [
		display_name, top_speed, time_to_90(), brake_decel_v, coast_decel_v, turn_radius, steer_rampup,
		handbrake_turn_mult, max_health, special_kind, special_damage, special_cost]
