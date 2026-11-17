class_name Weapons
extends RefCounted
## Weapon rules. Damage, rates, heat, energy and turbo numbers follow games/twisted-metal/data/TUNING.md (measured):
## machine gun 1 damage every 4 ticks with heat, every other weapon refires after 21 ticks,
## missiles fly ~140 units/tick. Names and looks are this game's own.

const TICK := 1.0 / 20.0                 # one original game tick

# machine gun
const MG_DAMAGE := 1.0
const MG_INTERVAL := 4 * TICK            # 5 shots/s
const MG_RANGE_UNITS := 3500.0          # hits at 3500 world units (measured; further not tested)
const HEAT_PER_SHOT := 6.0
const HEAT_LOCK := 200.0                 # locks here...
const HEAT_UNLOCK := 100.0               # ...and fires again once cooled to this
const HEAT_COOL := 1.0 / TICK            # 1 per tick = 20 per second (not while firing)

const REFIRE := 21 * TICK                # every weapon
const MISSILE_UNITS_PER_TICK := 150.0   # every missile, from the object table (fire, homing, power, freeze, tag, rear)
const HOMING_TURN_UNITS := 50.0          # homing missile: yaw units (4096/turn) per tick
const FIRE_TURN_UNITS := 10.0            # the plain fire missile also steers, weakly
const LOCK_COS := 0.62                   # lock needs the target within ~52 deg of the nose (45 locks, 60 does not)
const FREEZE_TIME := 60 * TICK           # 3 s

# special energy
const ENERGY_MAX := 20
const ENERGY_REGEN := 81 * TICK          # +1 per 81 ticks

# weapon slots (index into Vehicle.ammo); 0 is the machine gun
const FIRE := 1
const HOMING := 2
const POWER := 3
const FREEZE := 4
const MINE := 5
const SPECIAL := 6
const COUNT := 7
const NAMES := ["Machine Gun", "Fire Missile", "Homing Missile", "Power Missile", "Freeze Missile", "Mine", "Special"]
const DAMAGE := [1.0, 7.0, 15.0, 25.0, 0.0, 15.0, 0.0]
const START_AMMO := [0, 2, 0, 0, 0, 0, 0]
const MAX_AMMO := 15

## Pickup kinds placed in arenas, and what each gives (health amount is not measured: 40).
const PICKUPS := {"fire": [FIRE, 4], "homing": [HOMING, 2], "power": [POWER, 1], "freeze": [FREEZE, 1], "mine": [MINE, 2]}

static func missile_speed() -> float:
	return VehicleProfile.speed_to_ms(MISSILE_UNITS_PER_TICK)

static func mg_range() -> float:
	return VehicleProfile.u_to_m(MG_RANGE_UNITS)

## Missile turn rate in rad/s from yaw units per game tick.
static func turn_rate(units_per_tick: float) -> float:
	return units_per_tick / VehicleProfile.YAW_UNITS * TAU * VehicleProfile.TICK_RATE

# projectile kinds (sent in snapshots)
const P_FIRE := 0
const P_HOMING := 1
const P_POWER := 2
const P_FREEZE := 3
const P_MINE := 4
const P_BOLT := 5
const P_HEAVY := 6

static func proj_kind_for(weapon: int) -> int:
	match weapon:
		FIRE: return P_FIRE
		HOMING: return P_HOMING
		POWER: return P_POWER
		FREEZE: return P_FREEZE
		MINE: return P_MINE
	return P_BOLT

static func proj_color(kind: int) -> Color:
	match kind:
		P_FIRE: return Color(1.0, 0.45, 0.1)
		P_HOMING: return Color(1.0, 0.85, 0.2)
		P_POWER: return Color(1.0, 0.2, 0.15)
		P_FREEZE: return Color(0.4, 0.8, 1.0)
		P_MINE: return Color(0.9, 0.1, 0.1)
		P_HEAVY: return Color(0.8, 0.5, 1.0)
	return Color(0.6, 1.0, 0.5)
