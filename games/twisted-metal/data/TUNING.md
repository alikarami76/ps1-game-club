# Gameplay tuning: how the numbers were measured

All numbers in `data/tuning.json` were read from the player's own disc in the headless emulator
(`tools/emu_harness.py`). No window was opened. Working files and frames are in `cache/emu/measure2/`
and are not for publishing. The game logic runs once every 3 emulator frames (20 ticks per second).

Units: a *tick* is 1/20 s. *Raw speed* is the game's own speed field, 1/32 of a world unit per tick
(world units per tick = raw / 32). *Yaw* is 4096 per full turn. Damage is in health points.

## Correction to earlier numbers

`0x80191768/0x8019176C`, which the first pass used as the player position, is the camera's
view-space translation. Every speed and turn rate taken from it is replaced here. The player's world
position is at `0x801A1B24/0x801A1B28` (vehicle struct `0x801A179C` + 0x388/+0x38C) and the heading at
`0x801A1B44` (+0x3A8). The same values also sit in the placed-object record (from `0x8019171C`, 0x10C
bytes each, heading +0x58, x/y/z +0x5C..+0x64). `tools/measure.py` now reads these. Note that running
`measure.py` rewrites `tuning.json` from scratch and would drop the sections added here.

## How each number was found

**RAM layout.** I found health by recording RAM every 15 frames while the opponent attacked an idle
player and keeping values that only fell. Then I diffed the player struct while pressing each button
alone against an idle run. The fields were identified like this:

- the speed field rises under Up/Square and falls under Down/Circle;
- the turbo counter runs only while Triangle is held;
- the ammo array changes when L2 fires;
- the gun temperature rises under R2;
- the weapon index changes under L/R.

The opponent struct was found from the same field signature (1, 1, health, max health). The full map
is in `ram_layout`. Confidence: high for the fields listed, which were each checked against behaviour.

**Vehicle constants.** Each vehicle's parameter block (`0x801A1908..`) was dumped for all 12
vehicles. Max health, top speed and the from-rest acceleration were read from it, and the handbrake
multiplier was matched to it. Each one agrees exactly with the measured behaviour. Confidence: high.

**Top speed and acceleration.** I held Up for 80 ticks from the match start and read the speed field
each tick. World-position displacement agrees with raw/32 to within rounding. Acceleration fits
`dv = k (v_inf - v)` per tick, clamped at the top speed. The fitted value at rest matches the parameter
block. Confidence: high for top speed and the from-rest value, medium for k and v_inf, which are least-squares fits.

**Brake, coast, handbrake.** I took the speed field after 25 ticks of throttle followed by Down, then
no input, then Cross alone. Braking is close to a constant amount per tick, with a slight proportional
part for SEMI, LAMBO and HARLEY. Confidence: medium.

**Turning.** I read the heading field every frame while holding Left at a fixed speed (Up was
pressed only when below the target), at 25%, 50%, 75% and 100% of top speed, with and without Cross.
The steady yaw rate is proportional to speed, so each vehicle turns on a near-constant circle:
`yaw units per tick = raw speed / speed_per_yaw_unit`. That ratio is 12 to 18 depending on the
vehicle, and the radius is about 240 to 370 world units. The rate builds up by `steer_rampup` yaw
units per tick each tick before it levels off. Cross (handbrake) multiplies the yaw rate by 3, or by
2 for SEMI, HUMVEE and MONSTERT (parameter +0x314), and also slows the car. Confidence: medium. Wall
hits cut some runs short, and the 75% and 100% runs often had not levelled off yet.

**Turbo.** I held Triangle and compared the HUD number with the RAM. Each player has 2 tanks of 180
frames (60 ticks). Boost speed is exactly 1.5 times the top speed (from the speed field, all 12
vehicles), and the extra acceleration equals the parameter value, which is 3 times the from-rest
acceleration. Nothing recharged in 3 minutes. Confidence: high, except for recharge.

**Damage.** I moved the opponent to a fixed point in front of or behind the player by writing its
position every frame. Its speed and weapons were zeroed so it stayed passive, and the player's health
was held at full. Then I fired one weapon and read the opponent's health each frame. Each weapon's
damage was the same at every distance and against SEMI, LAMBO and MONSTERT targets, so damage does not
depend on the target. Projectile speed comes from the difference in hit time between two distances.
The refire time is how often ammo dropped while L2 was held. For dropped weapons, I dropped one, drove
away, then swept the opponent across the drop point. Confidence: high for missile, gun and special
damage; medium for speeds (±10%); medium for mines and spikes (one trial each).

**Machine gun.** I held R2 on the target for 1500 frames. Each hit does 1 damage, and the gun fires
every 4 ticks. Each shot adds 6 heat and nothing cools while firing. The gun locks at 200 and fires
again once it has cooled to 100, cooling 1 per tick. All 12 vehicles are the same. MONSTERT missed a
target 600 units away but hit one 1200 away, probably because its gun sits higher. Confidence: high.

**Special energy.** Every vehicle starts with 20 energy (also the maximum) and regains 1 every 81 ticks.
The cost per shot depends on the vehicle (3 to 9), and the HUD count is energy divided by cost,
rounded down. Confidence: high.

**Rules.** I counted active opponent health slots after killing all opponents by RAM write, level by
level. The counts were 1, 3, 5, 6 and 8, then a final level with 3 opponents and a 250-health boss,
followed by the ending. I also forced the player's death four times. There are 3 spare lives, and the
4th death returns to the title screen. Respawn takes about 91 ticks, with full health, at the start
point. Opponents have no spare lives. A level-1 match ran 12 minutes without a time limit. Confidence:
high for counts and lives, medium for the respawn delay.

## Gaps

- The MONSTERT special did nothing on L2 and used no energy, so its trigger is unknown.
- Weapon 6 (a dropped item) and oil did no damage, and their effects were not identified.
- Freeze missile flight speed was not measured. Its freeze lasts about 60 ticks (from when the target started moving again).
- Reverse top speed is unknown, because every reverse run hit a wall. Reverse uses the forward acceleration.
- No health pickup was seen in the first arena. Weapon pickups gave 4 fire missiles or 2 mines.
- Ram damage is rough. A target pinned in place keeps overlapping, so contact damage repeats (about 1 per contact tick, more for SEMI and MONSTERT).
- The lives counter's RAM address was not found; lives were counted from the HUD and game-over.
- Whether turbo refills on respawn or from pickups was not measured.
- Most parameter-block entries are still unidentified. They are dumped per vehicle in `cache/emu/measure2/` (see `ram_layout.player.params_block`).

## Fidelity pass (2026-11-16): code read from RAM, checked by replaying inputs

Method: the same per-tick input scripts run in the headless emulator (from `cache/emu/match_KK.state`,
XARENA, opponent pinned far away) and in the engine (`game/scenes/tests/fidelity_runner.tscn`, same arena
from the disc, same start). Harness, scenarios and results are in `cache/fidelity/physics/`
(`scenarios.py`, `run_emu.py`, `rungd.sh`, `compare.py`; not for publishing).

**Unit scale.** The disc arenas and car models are built at 1/32 m per world unit, but vehicle speeds
were converted at 1/64, so every car drove at half its speed relative to the arena.
`VehicleProfile.metres_per_unit` is now 1/32. Confidence: high (position traces match to ~1 %).

**Driving model** (`vehicles[*].drive_params`, from the per-vehicle block at vehicle struct + 0x138 and
the disassembled routines at 0x80112A1C, 0x80113CF0, 0x801142E8, 0x801145B8, 0x8011406C). Per tick, raw units:
- acceleration = accel_rest - (accel_rest - accel_top) x |speed| / max(speed, top); turbo uses 4 x accel_rest and 1.5 x top.
- no throttle: drag = max((brake - accel_top) x |speed| / top / 2, accel_top). Braking = brake + drag;
  below accel_rest the car snaps to 0, then waits 8 ticks before reversing. Reverse uses the same
  acceleration up to reverse_top (2/3 of top; measured top reverse speed overshoots by one step, about 3 %).
- steering angle S ramps by steer_slow - (steer_slow - steer_fast) x speed / 1440 per tick (steer_fast above
  1440), doubled when starting from centre or countersteering, x hb_mult with the handbrake (which
  also multiplies the limit steer_max). Released, S halves each tick and snaps to 0 below steer_slow.
  Yaw per tick = (speed / 32) x S / steer_div.
- grip breaks when speed > slide_speed and |yaw per tick| > slide_yaw: the direction of travel then stays
  fixed while the car keeps rotating. No drive while sliding. Slide friction by slip angle: brake/4
  (< 60 deg), brake/2 (< 90), brake (< 120), 2 x brake (3 x with throttle). Recovery turns the travel
  direction toward the nose by 3 deg/tick (7 deg countersteering, none steering into the slide; doubled
  with throttle); the slide ends below slide_exit speed.
- steering hard at speed scrubs `brake` per tick when |S| > m - (m - scrub) x speed / top (m = 2 x steer_max, or
  hb_mult x steer_max with the handbrake).
- The handbrake only acts together with a steer direction (pad code at 0x80113544). Its "hold the slide"
  flag never set in any recorded run, so it is not modelled.

**Walls** (26 runs at 0-80 degrees from head-on, ICE and LAMBO): speed x0.51 up to ~47 deg, x0.68 to ~67,
x0.78 beyond; below ~62 deg the travel direction mirrors off the wall, above it turns along the wall; the
car then slides. Not modelled: the small heading turn after a hit, and the original's narrow side
collision (cars graze walls at 70-80 deg where ours already touch). Confidence: medium.

**Ramming** (all 12 vehicles into a pinned opponent from 400 and 900 units): the rammed car loses
`ram_damage` once (1; SEMI 4; HUMVEE 5; MONSTERT 12), independent of speed, then `ram_push_damage_per_tick`
while the rammer keeps pushing (1; SEMI/HUMVEE 2; MONSTERT 0.3). The rammer takes nothing.

**Missiles** (object table at 0x8019171C, 0x10C per object: heading +0x58, x/y/z +0x5C): every missile flies
150 world units per tick (not 140). Homing turns 50 yaw units per tick; the plain fire missile also homes at
10 per tick; power, freeze and tag fly straight. Lock: target within 45 deg locks, 60 does not.

**Pickups**: a fire pickup gives 4 missiles; a taken pickup came back after 1910-1940 ticks (~96 s).

**Respawn**: 91 ticks (4.55 s), used for the match respawn time.

**Opponent AI** (player idle or driving, health pinned, 90 s per level state; `ai_emu.py`, `ai_an.py`):
level 1's single opponent does 3.4 health/s to a parked player (about half machine-gun hits, first hit
after ~3 s, parks ~300 units away) and 1.0/s to a moving one; it drives at about half its top speed when
chasing. Levels 2-6 add opponents (3, 5, 6, 8, 3 + boss); they also fight each other, so damage per
opponent falls (2.3, 1.2, 1.0, 0.2-0.5 /s). Our "normal" bot skill is set from level 1
(`BotAI.SKILL`; 1.8-2.6 /s to a parked player in our engine, with ramming now ~1 per contact).

**Jumps, slopes and body angles** (2026-11-16; `ramp_wheels.py`, `drop*.py`, `rampfit.py`). The original
has no single vertical velocity. Each car has four wheel corners (vehicle struct + 0x29C + 0x44 k:
local x/y/z offset, then world x, y and height), set per vehicle (`vehicles[*].wheels`: half track,
front, rear, ride height; e.g. ICE 32/56/80/32, SEMI 32/100/100/32, MONSTERT 43/64/80/66). Each corner
rides the ground or flies on its own; the body's height, pitch (+0x3A0, 4096/turn, positive = nose
down) and roll (+0x3A4) follow the corners. Writing the body z or a corner height has no effect: they
are recomputed every tick. Measured on the XARENA ramp (320 units long, 80 high, slope 14 deg):
- on the ramp the body pitches to -155 units (the slope); front corners rise ~10 units per tick;
- after the top, gravity on a flying corner grows with its airtime: about 0.6 + 0.4 x ticks airborne
  (world units per tick per tick, least-squares fit over 12 runs), falls capped at 56 units per tick
  (the counter at +0x40 of the first and third corner blocks stops at -1575);
- in the air the nose drops (pitch to +400 = 35 deg nose down before landing for ICE) because the
  front corners leave first; a car that clips a ramp edge rolls up to 57 deg;
- while any corner is off the ground the direction of travel holds (routine 0x8012153C) and a released
  steering angle decays by 1/16 per tick instead of halving; steering keeps turning the car in the air;
  a car that lands pointing away from its travel lands in a slide;
- in the air there is no drive: the speed coasts (ICE -15 per tick, LAMBO about -50).
Second pass:
- Body height: the reported body z sits at the geometric point between the corners (rear + (front -
  rear) x rear/(front + rear)) but about 0.7 tick ahead of them (z = that point + 0.7 x its vertical
  speed per tick; rms 5.6 units over 12 ramp runs, against 6.6 for a fixed 0.7 front / 0.3 rear mix).
- Landing: z dips 5-15 units for 1-2 ticks, then pitch and roll rock as a damped spring (pitch
  about 20 units nose up first, period ~16 ticks; roll 40-125 units, period ~20 ticks, sign varies;
  about 0.65 left after each half swing).
- Slopes (all 12 cars, XARENA ramp at 13-16 deg, both directions, 400-2000 raw): with all corners on the
  slope the speed changes by accel_rest / 3 per tick, down going up and up going down, whatever the
  speed (ICE 30, CAB 60, SEMI 24, LAMBO 78, HUMVEE 35, HARLEY 42, MONSTERT 60 ...). A 2.3 deg slope
  (PARK) showed no effect; the threshold is somewhere between 2.3 and 9.8 deg (ours: 5.7).
- Missile hits: a fire-missile hit on a parked ICE set its speed to 1224 raw units away from the blast
  (sliding, spinning, slowing 75 per tick); the car did not lift, pitch or roll.
- ROOF: the slope near (14400-14800, 1500-2300) is in the level model (object 1, outside half of the
  split) and in our collision (raycast 7820-7980 there). The difference is the collision rule: the
  original drives onto that ramp across its 40-80 unit side face, where our hull is stopped.
