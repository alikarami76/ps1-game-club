extends Node3D
## One deathmatch. On the server, each lobby runs one of these inside its own SubViewport (its
## own World3D and physics space) and simulates everything at a fixed 30 Hz tick. On a client
## it is the current scene: it sends inputs, predicts the local vehicle with input replay, and
## draws everyone else from interpolated snapshots.

const RESPAWN_TIME := 91.0 / 20.0  # measured: 91 game ticks from wreck to respawn
const JOIN_SPAWN_TIME := 2.0
const PICKUP_RESPAWN := 96.0       # measured: a taken pickup came back after 1910-1940 game ticks (96 s)
const OVER_DELAY := 8.0
const MAX_REWIND_TICKS := 6          # lag compensation cap: 200 ms
const HIST_TICKS := 120
const FULL_SNAP_EVERY := 40          # periodic full snapshot (2 s)
const RAM_MIN_SPEED := 6.0
const KNOCK_RAW := 1224.0          # speed a missile hit gives the target (raw units, measured)
const DestructiblesScript := preload("res://scripts/gameplay/destructibles.gd")
const VehicleDamageScript := preload("res://scripts/gameplay/vehicle_damage.gd")
const Tournament := preload("res://scripts/gameplay/tournament.gd")

var is_server := false
var lobby = null                     # server: Lobby
var roster: Dictionary = {}          # slot -> {name, color, model, bot, peer}
var settings: Dictionary = {}
var my_slot := -1

var arena: Node3D
var spawn_points: Array = []
var pickup_points: Array = []
var pickup_types: Array = []         # kind per pickup (same order on the server and clients)
var pickup_nodes: Array = []
var pickup_active: Array = []
var pickup_timers: Array = []
var ramps: Array = []
var pickup_gates: Array = []         # per pickup: destructible target that reveals it, or -1
var destructibles                    # DestructiblesScript (props of disc arenas)
var vehicles: Dictionary = {}        # slot -> Vehicle
var projectiles: Dictionary = {}     # id -> Projectile
var next_proj_id := 1
var scores: Dictionary = {}          # slot -> [kills, deaths]
var time_left := 300.0
var started := false
var over := false
var over_text := ""
var over_timer := 0.0
var wait_time := 0.0
var bot_state := {}
var tick := 0
var finished := false

# ---- server ----
var conns: Dictionary = {}           # peer -> conn dict
var world_hist: Dictionary = {}      # tick -> quantised world state
var veh_hist: Dictionary = {}        # slot -> Array [tick, pos, yaw]
var snap_accum := 0.0
var snap_seq := 0
var events: Array = []               # encoded events for this tick
var ev_seq := 0
var tick_usec_sum := 0
var tick_usec_max := 0
var tick_count := 0
var bytes_snap := 0
var snaps_sent := 0
var full_snaps := 0
var falls := 0                       # vehicles that fell out of the arena
var dmg_taken := {}                  # slot -> health lost this match (diagnostics, AI calibration)
var tour_lives := {}                 # tournament: human slot -> lives left
var tour_result := {}                # tournament: {won, level, lives_left, next} once decided
var dmg_dealt := {}                  # slot -> health taken from others
var dmg_by_weapon := {}              # victim slot -> {weapon name: health lost}
var bot_resets := 0                  # bots that used the unstuck key
var bot_stuck := 0                   # times a bot found itself stuck and backed out
var _odo_last: Dictionary = {}
var arena_id := ""
var _env: Environment

# ---- client ----
var hud: Hud
var cam: ChaseCamera
var sfx: SfxPlayer
var net_stats: NetStats
var menu_open := false
var auto_drive := false
var predict_enabled := true
var client_tick := 0
var input_hist: Dictionary = {}      # client tick -> [buttons, steer, live]
var pred_hist: Dictionary = {}       # client tick -> predicted state after that input
var snap_states: Dictionary = {}     # server tick -> decoded world state
var latest_snap := 0
var last_ack := 0
var ghosts: Dictionary = {}          # client: slot -> StaticBody3D standing in for that car (prediction only)
var ghost_track: Dictionary = {}     # client: slot -> [server tick, pos, yaw, velocity per tick, alive]
var ack_to_server := 0               # client: server tick - acknowledged input tick (from the last snapshot)
var pred_ram_cd: Dictionary = {}     # client: slot -> seconds, mirrors the server's ram cooldown
var clock_offset := 0.0              # server tick - local ticks
var clock_init := false
var jitter_ema := 0.0                # ticks
var jitter_peak := 0.0
var interp_delay := 3.0              # ticks
var last_snap_seq := -1
var snaps_recv := 0
var snaps_lost := 0
var snaps_dropped_nobase := 0
var last_snap_time := 0.0
var ev_expected := 0
var pending_events: Dictionary = {}
var corr_count := 0
var corr_sum := 0.0
var corr_max := 0.0
var corr_last := 0.0
var corr_big := 0
var corr_hist := [0, 0, 0, 0]       # reconciliation error < 5 cm, < 25 cm, < 1 m, >= 1 m
var reconcile_count := 0
var replay_ticks := 0
var pred_specials: Array = []        # predicted projectiles waiting for the server copy
var local_sp_cd := 0.0
var local_mg_cd := 0.0
var tracer_cd: Dictionary = {}
var prev_pickups: Array = []
var prev_hp: Dictionary = {}
var run_time := 0.0
var prev_keys := {}
var board_accum := 0.0
var trace_pred := false             # --trace-pred: per-tick own-vehicle state log for the prediction diff tool

func _ready() -> void:
	trace_pred = Game.args.has("trace-pred")
	process_priority = 100
	process_physics_priority = 0
	time_left = float(settings.get("time_limit", 300))
	if not is_server:
		roster = Net.match_roster
		settings = Net.match_settings
		my_slot = Net.my_slot
		time_left = float(settings.get("time_limit", 300))
		auto_drive = Game.args.has("autodrive")
		predict_enabled = not Game.args.has("no-predict")
		_build_environment()
	arena_id = str(settings.get("arena", Game.TEST_YARD))
	var provider := Game.make_arena_provider(arena_id)
	if provider == null:
		if is_server:
			push_warning("[match] arena %s is not in this server's game data; using the built-in arena" % arena_id)
			provider = ProceduralArena.new()
		else:
			Game.last_message = "This match uses the arena \"%s\" from game data, which this computer does not have. Set up your game data (Game data page) to join it." % Game.arena_label(arena_id)
			print("[match] cannot build arena %s: no local game data" % arena_id)
			Net.leave_lobby.call_deferred()
			finished = true
			return
	var t_arena := Time.get_ticks_msec()
	arena = provider.build_arena()
	add_child(arena)
	print("[match] arena %s built in %d ms%s" % [arena_id, Time.get_ticks_msec() - t_arena, " (collision only)" if is_server and arena_id != Game.TEST_YARD else ""])
	if _env != null and arena.has_meta("background"):
		# disc arenas: the game's per-arena clear colour behind the sky dome
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = arena.get_meta("background")
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_env.ambient_light_color = Color(0.8, 0.8, 0.8)
	spawn_points = arena.get_meta("spawn_points")
	pickup_points = arena.get_meta("pickup_points")
	pickup_types = arena.get_meta("pickup_types", [])
	if pickup_points.size() > Snapshot.MAX_PICKUPS:
		pickup_points = pickup_points.slice(0, Snapshot.MAX_PICKUPS)
	for i in pickup_points.size():
		if i >= pickup_types.size():
			pickup_types.append(Pickup.TYPES[i % Pickup.TYPES.size()])
	ramps = arena.get_meta("ramps", [])
	pickup_gates = arena.get_meta("pickup_gates", [])
	destructibles = DestructiblesScript.new(self, arena)
	for i in pickup_points.size():
		pickup_active.append(_pickup_gate(i) < 0)
		pickup_timers.append(0.0)
		if not is_server:
			var pk := Pickup.new()
			pk.setup(pickup_types[i])
			pk.position = pickup_points[i]
			add_child(pk)
			pickup_nodes.append(pk)
	prev_pickups = pickup_active.duplicate()
	if is_server:
		var i := 0
		for slot in roster:
			scores[slot] = [0, 0]
			var v := _spawn_vehicle(slot, Vehicle.Mode.SERVER)
			v.place(spawn_points[i % spawn_points.size()])
			i += 1
		var kinds := {}
		for v0 in vehicles.values():
			kinds[v0.vid + ":" + v0.collision_kind] = true
		print("[match] lobby %s: server match ready, %d vehicles, collision %s" % [lobby.name, vehicles.size(), ", ".join(kinds.keys())])
	else:
		sfx = SfxPlayer.new()
		add_child(sfx)
		Game.sfx = sfx
		sfx.start_music()
		cam = ChaseCamera.new()
		cam.fov = 72.0
		cam.far = 1500.0   # the largest arena is about 1260 m across
		add_child(cam)
		cam.make_current()
		hud = Hud.new()
		add_child(hud)
		hud.resume_pressed.connect(_toggle_menu)
		hud.leave_pressed.connect(func(): Net.leave_lobby())
		net_stats = NetStats.new()
		net_stats.match_node = self
		add_child(net_stats)
		Net.match_node = self
		Net.send_ctrl({"t": "match_loaded"})
		print("[match] client slot %d loaded, waiting for snapshots" % my_slot)

func _exit_tree() -> void:
	if not is_server:
		if Game.sfx == sfx:
			Game.sfx = null
		if Net.match_node == self:
			Net.match_node = null

func _build_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.25, 0.45, 0.75)
	sm.sky_horizon_color = Color(0.7, 0.78, 0.85)
	sm.ground_horizon_color = Color(0.5, 0.52, 0.55)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 110.0
	add_child(sun)

func _info(slot: int) -> Dictionary:
	var r: Dictionary = roster.get(slot, roster.get(str(slot), {}))
	return {"name": r.get("name", "?"), "color": Color.html(str(r.get("color", "#ffffff"))), "vid": str(r.get("vid", "builtin_1")), "bot": bool(r.get("bot", false))}

func _spawn_vehicle(slot: int, m: Vehicle.Mode) -> Vehicle:
	var v := Vehicle.new()
	v.setup(slot, _info(slot), m)
	add_child(v)
	vehicles[slot] = v
	return v

func _name_of(slot: int) -> String:
	return str(_info(slot).name) if slot >= 0 and slot < 255 else "World"

func _physics_process(delta: float) -> void:
	if finished:
		return
	if is_server:
		var t0 := Time.get_ticks_usec()
		_server_tick(delta)
		var us := Time.get_ticks_usec() - t0
		tick_usec_sum += us
		tick_usec_max = maxi(tick_usec_max, us)
		tick_count += 1
	else:
		_client_tick(delta)

# =====================================================================================
# SERVER
# =====================================================================================
func server_add_conn(peer: int, slot: int) -> void:
	conns[peer] = {"peer": peer, "slot": slot, "ready": false, "inputs": {}, "next": -1, "last": [0, 0.0],
		"ack": 0, "acked_snap": 0, "last_full": -1000, "view_tick": 0, "holds": 0, "repeats": 0, "snaps": 0}

## A player joins a running match: they spawn at the next respawn.
func server_add_player(slot: int, peer: int, info: Dictionary) -> void:
	roster[slot] = info
	scores[slot] = [0, 0]
	var v := _spawn_vehicle(slot, Vehicle.Mode.SERVER)
	v.place(spawn_points[slot % spawn_points.size()])
	v.die()
	v.respawn_timer = JOIN_SPAWN_TIME
	if peer > 0:
		server_add_conn(peer, slot)
	_ev_scores()

func server_remove_player(slot: int) -> void:
	for peer in conns.keys():
		if conns[peer].slot == slot:
			conns.erase(peer)
	if vehicles.has(slot):
		vehicles[slot].queue_free()
		vehicles.erase(slot)
	roster.erase(slot)
	scores.erase(slot)
	veh_hist.erase(slot)
	bot_state.erase(slot)
	var w := Proto.writer()
	w.put_u8(Proto.EV_LEFT)
	w.put_u8(slot)
	events.append(w.data_array)
	_ev_scores()

func server_update_info(slot: int, info: Dictionary) -> void:
	roster[slot] = info

func server_on_ready(peer: int) -> void:
	if not conns.has(peer):
		return
	conns[peer].ready = true
	conns[peer].last_full = -1000
	print("[match] lobby %s: peer %d ready" % [lobby.name, peer])
	_ev_scores()   # brings the newcomer up to date (events are only sent to ready clients)

func server_on_input(peer: int, p: PackedByteArray) -> void:
	var c: Dictionary = conns.get(peer, {})
	if c.is_empty() or p.size() < 14:
		return
	var r := Proto.reader(p)
	r.get_u8()
	var ack_snap := r.get_u32()
	var view_tick := r.get_u32()
	var newest := r.get_u32()
	var n := r.get_u8()
	if p.size() < 14 + n * 2:
		return
	if ack_snap > c.acked_snap and ack_snap <= tick:
		c.acked_snap = ack_snap
	if view_tick > c.view_tick and view_tick <= tick:
		c.view_tick = view_tick
	for i in n:
		var b := r.get_u8()
		var s := r.get_8()
		var t := newest - i
		if c.next < 0 or t >= c.next:
			c.inputs[t] = [b, s / 127.0]
	if c.next < 0 and c.inputs.size() >= 2:
		c.next = c.inputs.keys().min()
	if c.inputs.size() > 45:   # far behind (long stall): drop the backlog, keep the newest few
		var keys: Array = c.inputs.keys()
		keys.sort()
		for k in keys.slice(0, keys.size() - 4):
			c.inputs.erase(k)
		c.next = keys[keys.size() - 4]

func _consume(c: Dictionary) -> Variant:
	if c.next < 0:
		return null
	if c.inputs.has(c.next):
		var inp: Array = c.inputs[c.next]
		c.inputs.erase(c.next)
		c.last = inp
		c.ack = c.next
		c.next += 1
		return inp
	if not c.inputs.is_empty() and c.inputs.keys().min() > c.next:
		# that input was lost for good (beyond the redundancy): repeat the last one
		c.repeats += 1
		c.ack = c.next
		c.next += 1
		return c.last
	c.holds += 1
	return null   # not here yet: hold this vehicle for one tick

func _server_tick(dt: float) -> void:
	tick += 1
	if not started:
		wait_time += dt
		if _humans_ready() or wait_time > 8.0:
			started = true
			print("[match] lobby %s: started with %d vehicles" % [lobby.name, vehicles.size()])
			_tournament_start()
			_ev_scores()
	elif not over:
		time_left -= dt
		if time_left <= 0.0 and not Tournament.is_on(settings):
			time_left = 0.0
			_end_match()
	else:
		over_timer -= dt
		if over_timer <= 0.0 and not finished:
			finished = true
			lobby.on_match_finished()
			return
	# drive: humans from their input queue, bots from the bot brain
	var driven := {}
	for c in conns.values():
		var v: Vehicle = vehicles.get(c.slot)
		if v == null:
			continue
		var steps := 2 if c.inputs.size() >= 4 else 1
		for k in steps:
			var inp: Variant = _consume(c)
			if inp == null:
				break
			var ia: Array = inp
			_drive(v, ia[0], ia[1], dt, c)
			if trace_pred:
				_trace_state("tp-s slot=%d st=%d in=%d" % [c.slot, tick, c.ack], v, ia[0], ia[1])
		driven[c.slot] = true
	for slot in vehicles:
		var v2: Vehicle = vehicles[slot]
		if v2.is_bot():
			var out := BotAI.think(self, v2, dt) if started and not over else [0, 0.0, 0]
			if out[2] > 0:
				v2.weapon = out[2]
			_drive(v2, out[0], out[1], dt, {})
		elif not driven.has(slot) and not _has_conn(slot):
			_drive(v2, 0, 0.0, dt, {})   # player still loading
	for v3 in vehicles.values():
		_vehicle_tick(v3, dt)
	destructibles.server_tick(dt)
	if started and not over:
		_pickup_tick(dt)
	for slot in vehicles:
		var h: Array = veh_hist.get_or_add(slot, [])
		h.append([tick, vehicles[slot].global_position, vehicles[slot].yaw, vehicles[slot].alive])
		if h.size() > 16:
			h.pop_front()
	snap_accum += dt
	if snap_accum >= 1.0 / Proto.SNAP_RATE - 0.0001:
		snap_accum -= 1.0 / Proto.SNAP_RATE
		_send_snapshots()
	_flush_events()

## Prediction diff harness (--trace-pred): one line per simulated input with the full state.
func _trace_state(head: String, v: Vehicle, b: int, s: float) -> void:
	var p := v.global_position
	var vel := v.velocity
	print("[%s b=%d s=%.4f p=%.5f,%.5f,%.5f v=%.4f,%.4f,%.4f y=%.6f yr=%.5f g=%d f=%d" % [head, b, s, p.x, p.y, p.z, vel.x, vel.y, vel.z, v.yaw, v.yaw_rate, 1 if v.grounded else 0, 1 if v.is_on_floor() else 0])

func _has_conn(slot: int) -> bool:
	for c in conns.values():
		if c.slot == slot:
			return true
	return false

func _humans_ready() -> bool:
	for c in conns.values():
		if not c.ready:
			return false
	return true

func _drive(v: Vehicle, buttons: int, steer: float, dt: float, c: Dictionary) -> void:
	var live := started and not over and v.alive
	if not live:
		buttons = 0
		steer = 0.0
	var rise := buttons & ~v.last_buttons
	var reset_edge := Proto.is_reset(buttons) and not Proto.is_reset(v.last_buttons)
	v.last_buttons = buttons
	if live and v.frozen <= 0.0:
		if reset_edge:
			v.request_upright()
			if v.is_bot():
				bot_resets += 1
		elif not Proto.is_reset(buttons):
			if rise & Proto.B_NEXT:
				_cycle(v, 1)
			if rise & Proto.B_PREV:
				_cycle(v, -1)
			if rise & Proto.B_SPECIAL:
				fire_special(v)
	# machine gun: a shot every 4 game ticks, +6 heat per shot, locks at 200 until cooled to 100
	var want_mg := live and v.frozen <= 0.0 and (buttons & Proto.B_FIRE_MG) != 0
	v.firing = false
	if want_mg and not v.mg_locked:
		v.firing = true
		if v.mg_cd <= 0.0:
			v.mg_cd = Weapons.MG_INTERVAL
			v.heat += Weapons.HEAT_PER_SHOT
			if v.heat >= Weapons.HEAT_LOCK:
				v.mg_locked = true
			_fire_mg(v, c.get("view_tick", 0) if not c.is_empty() else tick)
	else:
		v.heat = maxf(v.heat - Weapons.HEAT_COOL * dt, 0.0)
		if v.mg_locked and v.heat <= Weapons.HEAT_UNLOCK:
			v.mg_locked = false
	if v.flame_time > 0.0:
		_flame_tick(v, dt)
	v.sim_step(buttons, steer, dt)
	_process_rams(v, dt)
	destructibles.after_drive(v)

func _cycle(v: Vehicle, d: int) -> void:
	var w := v.weapon
	for i in Weapons.COUNT - 1:
		w = 1 + posmod(w - 1 + d, Weapons.COUNT - 1)
		if v.ammo_count(w) > 0:
			v.weapon = w
			return

## Ramming (measured, games/twisted-metal/data/TUNING.md "Ramming"): the rammed car loses the rammer's
## ram_damage on contact (1 for most cars, 4 SEMI, 5 HUMVEE, 12 MONSTERT, whatever the speed)
## and ram_push per game tick while the rammer keeps pushing; the rammer takes nothing.
func _process_rams(v: Vehicle, dt: float) -> void:
	for r in v.rams:
		var o: Vehicle = r[0]
		var n: Vector3 = r[1]
		var closing: float = r[2]
		if not o.alive:
			continue
		if v.ram_cd.get(o.pid, 0.0) > 0.0:
			if (v.last_buttons & Proto.B_ACCEL) != 0:
				damage(o, v.profile.ram_push * dt * VehicleProfile.TICK_RATE, v.pid, Proto.W_RAM)
			v.ram_cd[o.pid] = 0.15
			continue
		if closing < RAM_MIN_SPEED:
			continue
		v.ram_cd[o.pid] = 0.15
		var ma := v.veh_mass
		var mb := o.veh_mass
		var j := 1.3 * closing / (1.0 / ma + 1.0 / mb)
		var nh := Vector3(n.x, 0.0, n.z).normalized()
		o.add_impulse(-nh * j / mb)   # (no upward kick: it threw the wheel corners into the air, which prediction cannot follow)
		v.add_impulse(nh * j / ma * 0.5)
		_ev_ram((v.global_position + o.global_position) * 0.5, closing)
		damage(o, v.profile.ram_damage, v.pid, Proto.W_RAM)

func _vehicle_tick(v: Vehicle, dt: float) -> void:
	for k in v.ram_cd.keys():
		v.ram_cd[k] -= dt
		if v.ram_cd[k] <= 0.0:
			v.ram_cd.erase(k)
	if not v.alive:
		v.respawn_timer -= dt
		if v.respawn_timer <= 0.0 and started and not over:
			v.respawn(_pick_spawn(v))
		return
	var lp: Vector3 = _odo_last.get(v.pid, v.global_position)
	var step := Vector2(v.global_position.x - lp.x, v.global_position.z - lp.z).length()
	if step < 5.0:
		v.odometer += step
	_odo_last[v.pid] = v.global_position
	v.protect = maxf(v.protect - dt, 0.0)
	v.flip_cd = maxf(v.flip_cd - dt, 0.0)
	v.mg_cd -= dt
	v.sp_cd -= dt
	if v.energy < Weapons.ENERGY_MAX:
		v.energy_timer += dt
		if v.energy_timer >= Weapons.ENERGY_REGEN:
			v.energy_timer -= Weapons.ENERGY_REGEN
			v.energy += 1
	else:
		v.energy_timer = 0.0
	if v.global_position.y < -15.0:
		falls += 1
		print("[match] lobby %s: %s fell out of the arena at %s" % [lobby.name, _name_of(v.pid), str(v.global_position.snapped(Vector3.ONE * 0.1))])
		if not started or over or v.protect > 0.0:
			v.respawn(_pick_spawn(v))   # damage() ignores these; put it back on a spawn point
		else:
			damage(v, 9999.0, v.pid, Proto.W_FALL)

func _pick_spawn(v: Vehicle) -> Transform3D:
	var best: Transform3D = spawn_points[0]
	var best_d := -1.0
	for sp in spawn_points:
		var d := 1e9
		for o in vehicles.values():
			if o != v and o.alive:
				d = minf(d, o.global_position.distance_to(sp.origin))
		d += randf() * 10.0
		if d > best_d:
			best_d = d
			best = sp
	return best

## Hitscan machine gun with lag compensation: other vehicles are rewound to where the shooter
## saw them (view_tick), at most MAX_REWIND_TICKS back.
func _fire_mg(v: Vehicle, view_tick: int) -> void:
	var fwd := v.forward()
	var from := v.global_position + fwd * 2.2 + Vector3(0, 0.3, 0)
	var right := fwd.cross(Vector3.UP)
	var dir := (fwd + right * randf_range(-0.02, 0.02) + Vector3(0, randf_range(-0.012, 0.012), 0)).normalized()
	var max_d := Weapons.mg_range()
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * max_d, 1)
	var r := get_world_3d().direct_space_state.intersect_ray(q)
	if not r.is_empty():
		max_d = from.distance_to(r.position)
	var rewind := clampi(tick - view_tick, 0, MAX_REWIND_TICKS) if not v.is_bot() else 0
	var want := tick - rewind
	var best: Vehicle = null
	var best_t := max_d
	for o in vehicles.values():
		if o == v or not o.alive:
			continue
		var pose := _pose_at(o, want)
		if not pose[2]:
			continue
		var t := _ray_box(from, dir, pose[0], pose[1], o.half_extents)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = o
	if best != null:
		damage(best, Weapons.MG_DAMAGE, v.pid, 0)
	elif not r.is_empty():
		destructibles.on_ray_hit(r.collider, Weapons.MG_DAMAGE, v.pid)

func _pose_at(o: Vehicle, want: int) -> Array:
	var h: Array = veh_hist.get(o.pid, [])
	for i in range(h.size() - 1, -1, -1):
		if h[i][0] <= want:
			return [h[i][1], h[i][2], h[i][3]]
	return [o.global_position, o.yaw, o.alive]

static func _ray_box(o: Vector3, d: Vector3, c: Vector3, yaw: float, he := Vehicle.HALF_EXTENTS) -> float:
	var inv := Basis(Vector3.UP, -yaw)
	var lo := inv * (o - c)
	var ld := inv * d
	var tmin := -1e9
	var tmax := 1e9
	for a in 3:
		if absf(ld[a]) < 1e-6:
			if lo[a] < -he[a] or lo[a] > he[a]:
				return -1.0
		else:
			var t1 := (-he[a] - lo[a]) / ld[a]
			var t2 := (he[a] - lo[a]) / ld[a]
			tmin = maxf(tmin, minf(t1, t2))
			tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)

func fire_special(v: Vehicle) -> void:
	if not v.alive or over or v.sp_cd > 0.0 or v.ammo_count(v.weapon) <= 0:
		return
	var fwd := v.forward()
	var org := v.global_position
	var w := v.weapon
	v.sp_cd = Weapons.REFIRE
	if w == Weapons.SPECIAL:
		var pf := v.profile
		v.energy -= pf.special_cost
		match pf.special_kind:
			"bolt":
				_launch(v, Weapons.P_BOLT, fwd, pf.special_speed, pf.special_damage, false)
			"heavy":
				_launch(v, Weapons.P_HEAVY, fwd, pf.special_speed, pf.special_damage, false)
			"salvo":
				for a in [-0.09, 0.0, 0.09]:
					_launch(v, Weapons.P_BOLT, fwd.rotated(Vector3.UP, a), pf.special_speed, pf.special_damage, false)
			"flame":
				v.flame_time = 1.1
				_ev_special(v.pid, 0)
			"shockwave":
				_ev_special(v.pid, 1)
				explode(org, 15.0, pf.special_damage, v.pid, Weapons.SPECIAL, 0.0)
		_autoselect_after_use(v)
		return
	match w:
		Weapons.FIRE:
			_launch(v, Weapons.P_FIRE, fwd, Weapons.missile_speed(), Weapons.DAMAGE[w], true, Weapons.FIRE_TURN_UNITS)
		Weapons.POWER:
			_launch(v, Weapons.P_POWER, fwd, Weapons.missile_speed(), Weapons.DAMAGE[w], false)
		Weapons.HOMING:
			_launch(v, Weapons.P_HOMING, fwd, Weapons.missile_speed(), Weapons.DAMAGE[w], true)
		Weapons.FREEZE:
			_launch(v, Weapons.P_FREEZE, fwd, Weapons.missile_speed(), 0.0, false)
		Weapons.MINE:
			var mp := org - fwd * 3.0
			var q := PhysicsRayQueryParameters3D.create(mp + Vector3.UP, mp + Vector3.DOWN * 4.0, 1)
			var r := get_world_3d().direct_space_state.intersect_ray(q)
			var pos: Vector3 = r.position + Vector3(0, 0.1, 0) if not r.is_empty() else org - Vector3(0, 0.5, 0)
			var p2 := Projectile.new()
			p2.setup(Weapons.P_MINE, true, self)
			p2.id = _new_proj_id()
			p2.owner_id = v.pid
			p2.damage = Weapons.DAMAGE[Weapons.MINE]
			add_child(p2)
			p2.global_position = pos
			projectiles[p2.id] = p2
	v.ammo[w] -= 1
	_autoselect_after_use(v)

func _launch(v: Vehicle, kind: int, dir: Vector3, spd: float, dmg: float, homing: bool, turn_units := Weapons.HOMING_TURN_UNITS) -> void:
	var p := Projectile.new()
	p.setup(kind, true, self)
	p.id = _new_proj_id()
	p.owner_id = v.pid
	p.velocity = dir * spd
	p.damage = dmg
	if homing:
		p.target = _pick_target(v)
		p.turn = Weapons.turn_rate(turn_units)
	add_child(p)
	p.global_position = v.global_position + dir * 2.8 + Vector3(0, 0.2, 0)
	p.global_transform.basis = Basis.looking_at(dir, Vector3.UP)
	projectiles[p.id] = p

func _autoselect_after_use(v: Vehicle) -> void:
	if v.ammo_count(v.weapon) <= 0:
		_cycle(v, 1)

## Flame special: about 1 damage per game tick to anything in a short cone in front.
func _flame_tick(v: Vehicle, dt: float) -> void:
	v.flame_time -= dt
	var fwd := v.forward()
	for o in vehicles.values():
		if o == v or not o.alive:
			continue
		var to: Vector3 = o.global_position - v.global_position
		var d := to.length()
		if d < 14.0 and d > 0.1 and fwd.dot(to / d) > 0.8:
			damage(o, v.profile.special_damage * dt * clampf(1.2 - d / 14.0, 0.0, 1.0), v.pid, Weapons.SPECIAL)

func _ev_special(slot: int, kind: int) -> void:
	var w := Proto.writer()
	w.put_u8(Proto.EV_SPECIAL)
	w.put_u8(slot)
	w.put_u8(kind)
	events.append(w.data_array)

func _new_proj_id() -> int:
	var id := next_proj_id
	next_proj_id = next_proj_id % 65000 + 1
	return id

func _pick_target(v: Vehicle) -> Vehicle:
	var fwd := v.forward()
	var best: Vehicle = null
	var best_d := 1e9
	for o in vehicles.values():
		if o == v or not o.alive:
			continue
		var to: Vector3 = o.global_position - v.global_position
		var d := to.length()
		if d > 0.1 and d < best_d and fwd.dot(to / d) > Weapons.LOCK_COS:
			best_d = d
			best = o
	return best

func explode(pos: Vector3, radius: float, dmg: float, owner_id: int, weapon_id: int, push := 1.0) -> void:
	_ev_explosion(pos, radius)
	destructibles.on_explosion(pos, radius, dmg, owner_id)
	for v in vehicles.values():
		if not v.alive or v.pid == owner_id:
			continue
		var d: float = v.global_position.distance_to(pos)
		if d < radius:
			var f := 1.0 - 0.5 * (d / radius)
			damage(v, dmg * f, owner_id, weapon_id)
			if v.alive and push > 0.0:
				var dir: Vector3 = (v.global_position - pos)
				dir.y = 0.0
				# measured: a fire-missile hit on a parked ICE set its speed to 1224 raw units away from the
				# blast and it slid to a stop (spinning); no lift, no pitch or roll
				v.knock(dir.normalized() if dir.length() > 0.01 else -v.forward(), KNOCK_RAW * f * push)

## Freeze missile: no damage, the target cannot move for 3 s.
func freeze(pos: Vector3, owner_id: int) -> void:
	_ev_explosion(pos, 2.0)
	for v in vehicles.values():
		if v.alive and v.pid != owner_id and v.global_position.distance_to(pos) < 3.0 and v.protect <= 0.0:
			v.frozen = Weapons.FREEZE_TIME
			v.velocity = Vector3.ZERO

func damage(victim: Vehicle, amount: float, attacker: int, weapon_id: int) -> void:
	if not victim.alive or victim.protect > 0.0 or over or not started:
		return
	dmg_taken[victim.pid] = dmg_taken.get(victim.pid, 0.0) + minf(amount, victim.hp)
	if attacker != victim.pid:
		dmg_dealt[attacker] = dmg_dealt.get(attacker, 0.0) + minf(amount, victim.hp)
		var wn: String = Proto.WEAPON_IDS[weapon_id] if weapon_id < Proto.WEAPON_IDS.size() else str(weapon_id)
		var bw: Dictionary = dmg_by_weapon.get_or_add(victim.pid, {})
		bw[wn] = bw.get(wn, 0.0) + minf(amount, victim.hp)
	if victim.apply_damage(amount):
		_on_kill(victim, attacker, weapon_id)

## Tournament: lives for the humans, the boss's health on the last level.
func _tournament_start() -> void:
	if not Tournament.is_on(settings):
		return
	var lv := Tournament.level_of(settings)
	var info := Tournament.level_info(lv)
	var bots: Array = []
	for slot in vehicles:
		if vehicles[slot].is_bot():
			bots.append(slot)
		else:
			tour_lives[slot] = int(settings.get("lives_left", Tournament.LIVES))
	if info.boss and not bots.is_empty():
		var boss: Vehicle = vehicles[bots.max()]
		boss.max_hp = Tournament.BOSS_HEALTH
		boss.hp = boss.max_hp
	print("[match] lobby %s: tournament level %d (%s), %d opponents, lives %s" % [lobby.name, lv, info.arena, bots.size(), str(tour_lives)])

## Tournament after a wreck: opponents stay down; a human uses a life. Ends the level when every
## opponent is down (won) or the humans are out of lives (lost).
func _tournament_after_kill(victim: Vehicle) -> void:
	if victim.is_bot():
		victim.respawn_timer = INF
	else:
		tour_lives[victim.pid] = int(tour_lives.get(victim.pid, Tournament.LIVES)) - 1
		if tour_lives[victim.pid] <= 0:
			victim.respawn_timer = INF
	var bots_left := 0
	var humans_left := 0
	for v in vehicles.values():
		if v.is_bot():
			bots_left += 1 if v.alive else 0
		elif v.alive or int(tour_lives.get(v.pid, 0)) > 0:
			humans_left += 1
	if bots_left == 0 or humans_left == 0:
		var lives := 0
		for k in tour_lives:
			lives = maxi(lives, int(tour_lives[k]))
		var won := bots_left == 0 and humans_left > 0
		tour_result = {"won": won, "level": Tournament.level_of(settings), "lives_left": lives,
			"next": Tournament.next_settings(settings, won, lives)}
		_end_match()

func _on_kill(victim: Vehicle, attacker: int, weapon_id: int) -> void:
	victim.die()
	victim.respawn_timer = RESPAWN_TIME
	if scores.has(victim.pid):
		scores[victim.pid][1] += 1
	var killer := attacker
	if attacker == victim.pid or not scores.has(attacker):
		killer = 255
	else:
		scores[attacker][0] += 1
	var w := Proto.writer()
	w.put_u8(Proto.EV_KILL)
	w.put_u8(killer)
	w.put_u8(victim.pid)
	w.put_u8(weapon_id)
	events.append(w.data_array)
	print("[match] lobby %s: kill %s -> %s (%s)" % [lobby.name, _name_of(killer) if killer != 255 else "world", _name_of(victim.pid), Proto.WEAPON_IDS[weapon_id] if weapon_id < Proto.WEAPON_IDS.size() else "?"])
	_ev_explosion(victim.global_position, 5.0)
	_ev_scores()
	if Tournament.is_on(settings):
		_tournament_after_kill(victim)
	elif killer != 255 and scores[killer][0] >= int(settings.get("score_limit", 15)):
		_end_match()

func _end_match() -> void:
	if over:
		return
	over = true
	over_timer = OVER_DELAY
	var best := -1
	var best_k := -1
	var best_d := 1 << 30
	for slot in scores:
		var k: int = scores[slot][0]
		var d: int = scores[slot][1]
		if k > best_k or (k == best_k and d < best_d):
			best = slot
			best_k = k
			best_d = d
	over_text = "%s wins!" % _name_of(best)
	if not tour_result.is_empty():
		over_text = ("Level %d cleared!" % tour_result.level) if tour_result.won else "Game over"
		if tour_result.won and tour_result.next.is_empty():
			over_text = "Tournament won!"
	print("[match] lobby %s: over, %s (kills %d)%s" % [lobby.name, over_text, best_k, (" tournament " + str(tour_result)) if not tour_result.is_empty() else ""])
	var dstat := []
	for slot in scores:
		dstat.append("%s%s taken %.0f %s dealt %.0f" % [_name_of(slot), " (bot)" if vehicles.has(slot) and vehicles[slot].is_bot() else "", dmg_taken.get(slot, 0.0), str(dmg_by_weapon.get(slot, {})), dmg_dealt.get(slot, 0.0)])
	print("[match] lobby %s: damage after %.0f s: %s" % [lobby.name, float(settings.get("time_limit", 300)) - time_left, ", ".join(dstat)])
	if destructibles.count() > 0:
		print("[match] lobby %s: props destroyed %d of %d (%s), gated pickups revealed %d of %d" % [lobby.name, destructibles.destroyed_count(), destructibles.count(), str(destructibles.stats), _revealed_pickups(), pickup_gates.filter(func(g): return g >= 0).size()])
	var w := Proto.writer()
	w.put_u8(Proto.EV_OVER)
	w.put_u8(maxi(best, 0))
	events.append(w.data_array)
	_ev_scores()

## Destructible target whose wreck holds pickup i (it is taken only after that), or -1.
func _pickup_gate(i: int) -> int:
	return int(pickup_gates[i]) if i < pickup_gates.size() else -1

func _revealed_pickups() -> int:
	var n := 0
	for i in pickup_points.size():
		if _pickup_gate(i) >= 0 and destructibles.is_destroyed(_pickup_gate(i)):
			n += 1
	return n

func _pickup_tick(dt: float) -> void:
	for i in pickup_points.size():
		if not pickup_active[i]:
			if _pickup_gate(i) >= 0 and not destructibles.is_destroyed(_pickup_gate(i)):
				continue   # still inside its prop
			pickup_timers[i] -= dt
			if pickup_timers[i] <= 0.0:
				pickup_active[i] = true
			continue
		for v in vehicles.values():
			if v.alive and v.global_position.distance_to(pickup_points[i]) < 2.8:
				if _give(v, pickup_types[i]):
					pickup_active[i] = false
					pickup_timers[i] = _pickup_respawn()
					break

## Seconds until a taken pickup returns: the lobby's setting (30/60/96 s) in deathmatch, the original's 96 s in a tournament.
func _pickup_respawn() -> float:
	if Tournament.is_on(settings):
		return PICKUP_RESPAWN
	return float(settings.get("pickup_respawn", PICKUP_RESPAWN))

func _give(v: Vehicle, type: String) -> bool:
	if type == "health":
		if v.hp >= v.max_hp:
			return false
		v.hp = minf(v.hp + 40.0, v.max_hp)   # amount not measured
		return true
	if type == "random":   # unlabelled icon: a random weapon (server side, so everyone agrees)
		var kinds := ["fire", "homing", "power", "freeze", "mine"]
		type = kinds[randi() % kinds.size()]
	var g: Array = Weapons.PICKUPS.get(type, [])
	if g.is_empty():
		return false
	var w: int = g[0]
	if v.ammo[w] >= Weapons.MAX_AMMO:
		return false
	v.ammo[w] = mini(v.ammo[w] + g[1], Weapons.MAX_AMMO)
	if v.ammo_count(v.weapon) <= 0:
		v.weapon = w
	return true

# ---- events ----
func _scores_event() -> PackedByteArray:
	var w := Proto.writer()
	w.put_u8(Proto.EV_SCORES)
	w.put_u8(scores.size())
	for slot in scores:
		w.put_u8(slot)
		w.put_u16(scores[slot][0])
		w.put_u16(scores[slot][1])
	return w.data_array

func _ev_scores() -> void:
	# keep only the newest scores event in this tick's batch
	for i in range(events.size() - 1, -1, -1):
		if events[i][0] == Proto.EV_SCORES:
			events.remove_at(i)
	events.append(_scores_event())

func _ev_explosion(pos: Vector3, radius: float) -> void:
	var w := Proto.writer()
	w.put_u8(Proto.EV_EXPLOSION)
	w.put_16(Proto.q_pos(pos.x)); w.put_16(Proto.q_pos(pos.y)); w.put_16(Proto.q_pos(pos.z))
	w.put_u8(clampi(roundi(radius * 4.0), 0, 255))
	events.append(w.data_array)

func _ev_ram(pos: Vector3, strength: float) -> void:
	var w := Proto.writer()
	w.put_u8(Proto.EV_RAM)
	w.put_16(Proto.q_pos(pos.x)); w.put_16(Proto.q_pos(pos.y)); w.put_16(Proto.q_pos(pos.z))
	w.put_u8(clampi(roundi(strength * 4.0), 0, 255))
	events.append(w.data_array)

func _flush_events() -> void:
	if events.is_empty():
		return
	var w := Proto.writer()
	w.put_u8(Proto.S_EVENTS)
	w.put_u16(ev_seq & 0xFFFF)
	w.put_u8(mini(events.size(), 255))
	for e in events.slice(0, 255):
		w.put_data(e)
	ev_seq += 1
	events.clear()
	var data := w.data_array
	for c in conns.values():
		if c.ready:
			lobby.send(c.peer, data, true)

# ---- snapshots ----
func _world_state() -> Dictionary:
	var st := Snapshot.empty_state()
	for slot in vehicles:
		var v: Vehicle = vehicles[slot]
		var s := PackedInt32Array()
		s.resize(Snapshot.V_LEN)
		var p := v.global_position
		s[0] = Proto.q_pos(p.x); s[1] = Proto.q_pos(p.y); s[2] = Proto.q_pos(p.z)
		s[3] = Proto.q_yaw(v.yaw)
		s[4] = Proto.q_angle8(v.tilt.x); s[5] = Proto.q_angle8(v.tilt.y)
		s[6] = clampi(ceili(v.hp), 0, 255)
		s[7] = clampi(ceili(v.armor), 0, 255)
		s[8] = (Snapshot.ST_ALIVE if v.alive else 0) | (Snapshot.ST_PROTECT if v.protect > 0.0 else 0) | (Snapshot.ST_FIRING if v.firing else 0) \
			| ((v.weapon & 7) << 3) | (Snapshot.ST_FROZEN if v.frozen > 0.0 else 0) | (Snapshot.ST_TURBO if v.boosting else 0)
		st.v[slot] = s
	for id in projectiles:
		var pr: Projectile = projectiles[id]
		var s2 := PackedInt32Array()
		s2.resize(Snapshot.P_LEN)
		var pp := pr.global_position
		s2[0] = Proto.q_pos(pp.x); s2[1] = Proto.q_pos(pp.y); s2[2] = Proto.q_pos(pp.z)
		var f := -pr.global_transform.basis.z
		s2[3] = Proto.q_yaw(atan2(-f.x, -f.z))
		s2[4] = Proto.q_angle8(asin(clampf(f.y, -1.0, 1.0)))
		s2[5] = pr.type
		s2[6] = pr.owner_id
		st.p[id] = s2
	return st

func _send_snapshots() -> void:
	var st := _world_state()
	world_hist[tick] = st
	world_hist.erase(tick - 90)
	snap_seq = (snap_seq + 1) & 0xFF
	var pk := 0
	for i in mini(pickup_active.size(), Snapshot.MAX_PICKUPS):
		if pickup_active[i]:
			pk |= 1 << i
	var flags := (1 if started else 0) | (2 if over else 0)
	var prop_bits: PackedByteArray = destructibles.bitset()
	for c in conns.values():
		if not c.ready:
			continue
		c.snaps += 1
		var base = null
		var base_tick := 0
		if c.acked_snap > 0 and world_hist.has(c.acked_snap) and c.snaps - c.last_full < FULL_SNAP_EVERY:
			base = world_hist[c.acked_snap]
			base_tick = c.acked_snap
		else:
			c.last_full = c.snaps
			full_snaps += 1
		var own := {}
		var v: Vehicle = vehicles.get(c.slot)
		if v != null:
			own = {"pos": v.global_position, "yaw": v.yaw, "yaw_rate": v.yaw_rate, "vel": v.velocity,
				"alive": v.alive, "grounded": v.grounded, "ammo": v.ammo, "weapon": v.weapon, "energy": v.energy,
				"heat": v.heat, "locked": v.mg_locked, "turbo": v.turbo_fuel, "frozen": v.frozen,
				"spd": v.spd, "steer_s": v.steer_s, "travel": v.travel, "sliding": v.sliding, "reverse_mode": v.reverse_mode, "stop_ticks": v.stop_ticks,
				"wh": v.wh, "wv": v.wv, "wn": v.wn, "phase": v.drive_phase}
		var hdr := {"tick": tick, "base_tick": base_tick, "ack": c.ack, "seq": snap_seq, "flags": flags,
			"time_left": time_left, "pickups": pk, "props": prop_bits}
		var data := Snapshot.encode(st, base, hdr, own)
		bytes_snap += data.size()
		snaps_sent += 1
		lobby.send(c.peer, data, false)

# =====================================================================================
# CLIENT
# =====================================================================================
func _now_ticks() -> float:
	return Time.get_ticks_usec() / 1000000.0 * Proto.TICK_RATE

## Estimated current server tick.
func server_now() -> float:
	return _now_ticks() + clock_offset

func render_tick() -> float:
	return server_now() - interp_delay

func _key(action: String) -> bool:
	return Input.is_action_pressed(action)

func _sample_input() -> Array:
	var me: Vehicle = vehicles.get(my_slot)
	if auto_drive:
		if me == null:
			return [Proto.B_ACCEL, 0.0]
		var out := BotAI.think(self, me, Proto.TICK_DT)
		var b: int = out[0]
		# the bot brain asks for a weapon; a player can only cycle, so press "next" until it matches
		if out[2] > 0 and out[2] != me.weapon and (client_tick % 4) == 0:
			b |= Proto.B_NEXT
		return [b, out[1]]
	if menu_open or over:
		return [0, 0.0]
	var t := Input.get_axis("brake", "accelerate")
	var s := Input.get_axis("steer_left", "steer_right")
	var b2 := Proto.buttons_from(t, _key("handbrake"), _key("fire_mg"), _key("fire_special"), _key("weapon_next"), _key("weapon_prev"), _key("reset_vehicle"), _key("turbo"))
	return [b2, s]

func _client_tick(dt: float) -> void:
	run_time += dt
	client_tick += 1
	var me: Vehicle = vehicles.get(my_slot)
	var inp := _sample_input()
	var buttons: int = inp[0]
	var steer: float = float(Proto.q_steer(inp[1])) / 127.0   # exactly what the server will see
	var live := started and not over and me != null and me.alive
	input_hist[client_tick] = [buttons, steer, live]
	if me != null and me.mode == Vehicle.Mode.PREDICTED:
		_predict_effects(me, buttons, live, dt)
		if live and me.frozen <= 0.0 and Proto.is_reset(buttons) and not Proto.is_reset(prev_keys.get(0, 0)):
			me.request_upright()
		me.flip_cd = maxf(me.flip_cd - dt, 0.0)
		_place_ghosts(client_tick)
		me.sim_step(buttons if live else 0, steer if live else 0.0, dt)
		_predict_rams(me, dt)
		var ps := me.get_state()
		ps.ram_cd = pred_ram_cd.duplicate()
		ps.alive = me.alive
		ps.flip_cd = me.flip_cd
		pred_hist[client_tick] = ps
		if trace_pred:
			_trace_state("tp-c slot=%d t=%d live=%d" % [my_slot, client_tick, 1 if live else 0], me, buttons if live else 0, steer if live else 0.0)
	prev_keys[0] = buttons
	input_hist.erase(client_tick - HIST_TICKS)
	pred_hist.erase(client_tick - HIST_TICKS)
	_send_input()

func _send_input() -> void:
	var w := Proto.writer()
	w.put_u8(Proto.C_INPUT)
	w.put_u32(latest_snap)
	w.put_u32(maxi(roundi(render_tick()), 0))
	w.put_u32(client_tick)
	var n := mini(Proto.INPUT_REDUNDANCY, client_tick)
	w.put_u8(n)
	for i in n:
		var e: Array = input_hist.get(client_tick - i, [0, 0.0, false])
		w.put_u8(e[0] if e[2] else 0)   # not live here (before the start we have seen): the server must not drive either
		w.put_8(Proto.q_steer(e[1]))
	Net.send_game(w.data_array, false)

## Things the shooter should see immediately: own machine-gun tracers and missiles/mines.
func _predict_effects(me: Vehicle, buttons: int, live: bool, dt: float) -> void:
	local_sp_cd -= dt
	local_mg_cd -= dt
	var prev: int = prev_keys.get(0, 0)
	if not live or me.frozen > 0.0:
		return
	if buttons & Proto.B_FIRE_MG and local_mg_cd <= 0.0 and not me.mg_locked:
		local_mg_cd = Weapons.MG_INTERVAL
		_tracer_from(me, true)
	if (buttons & ~prev) & Proto.B_SPECIAL and not Proto.is_reset(buttons) and local_sp_cd <= 0.0 and me.ammo_count(me.weapon) > 0:
		local_sp_cd = Weapons.REFIRE
		var fwd := me.forward()
		var kind := Weapons.proj_kind_for(me.weapon)
		var spd := Weapons.missile_speed()
		if me.weapon == Weapons.SPECIAL:
			if not (me.profile.special_kind in ["bolt", "heavy"]):
				return
			kind = Weapons.P_HEAVY if me.profile.special_kind == "heavy" else Weapons.P_BOLT
			spd = me.profile.special_speed
		var p := Projectile.new()
		p.setup(kind, false, self)
		p.predicted = true
		p.own = true
		p.owner_id = my_slot
		add_child(p)
		if kind == Weapons.P_MINE:
			p.global_position = me.global_position - fwd * 3.0 + Vector3(0, -0.45, 0)
		else:
			p.velocity = fwd * spd
			p.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), me.global_position + fwd * 2.8 + Vector3(0, 0.2, 0))
			Game.play_sfx("missile", p.global_position)
		pred_specials.append(p)

func _tracer_from(v: Vehicle, predicted_shot: bool) -> void:
	var xf := v.visual_xf
	var fwd := -xf.basis.z
	var from := xf.origin + fwd * 2.2 + Vector3(0, 0.3, 0)
	var to := from + fwd * 80.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	var r := get_world_3d().direct_space_state.intersect_ray(q)
	if not r.is_empty():
		to = r.position
	Fx.tracer(self, from, to)
	Game.play_sfx("mg", from, -4.0 if predicted_shot else -8.0)

## Called by Net for every game packet while this match is the current scene.
func on_packet(p: PackedByteArray) -> void:
	if p.is_empty():
		return
	if p[0] == Proto.S_SNAP:
		_on_snapshot(p)
	elif p[0] == Proto.S_EVENTS:
		_on_events(p)

func _on_snapshot(p: PackedByteArray) -> void:
	var base_tick := Snapshot.peek_base(p)
	var base = null
	if base_tick > 0:
		if not snap_states.has(base_tick):
			snaps_dropped_nobase += 1
			return
		base = snap_states[base_tick]
	var d := Snapshot.decode(p, base)
	if d.is_empty():
		return
	var hdr: Dictionary = d.hdr
	if hdr.tick <= latest_snap:
		return   # old or duplicate
	snaps_recv += 1
	if last_snap_seq >= 0:
		var gap: int = (hdr.seq - last_snap_seq) & 0xFF
		if gap > 1 and gap < 100:
			snaps_lost += gap - 1
	last_snap_seq = hdr.seq
	var now := _now_ticks()
	last_snap_time = now
	_update_clock(hdr.tick, now)
	latest_snap = hdr.tick
	snap_states[hdr.tick] = d.state
	for k in snap_states.keys():
		if k < hdr.tick - 64:
			snap_states.erase(k)
	time_left = hdr.time_left
	started = (hdr.flags & 1) != 0
	if (hdr.flags & 2) != 0:
		over = true
	for i in mini(pickup_active.size(), Snapshot.MAX_PICKUPS):
		pickup_active[i] = (hdr.pickups & (1 << i)) != 0
	if hdr.has("props"):
		var before: int = destructibles.destroyed_count()
		destructibles.apply_bitset(hdr.props)
		if destructibles.destroyed_count() != before:
			print("[match] props from full snapshot: %d of %d destroyed" % [destructibles.destroyed_count(), destructibles.count()])
	_apply_vehicles(d.state, hdr.tick)
	_apply_projectiles(d.state, hdr.tick)
	if not d.own.is_empty():
		_reconcile(hdr.ack, d.own)

func _update_clock(stick: int, now: float) -> void:
	var sample := float(stick) - now
	if not clock_init:
		clock_init = true
		clock_offset = sample
		return
	if sample > clock_offset:
		clock_offset = lerpf(clock_offset, sample, 0.3)   # this packet was faster than our estimate
	else:
		clock_offset -= 0.01                              # drift down slowly (0.2 ticks/s)
	var dev := maxf(clock_offset - sample, 0.0)
	jitter_ema = lerpf(jitter_ema, dev, 0.08)
	jitter_peak = maxf(dev, jitter_peak * 0.985)
	var target := clampf(1.6 + 0.6 + maxf(2.0 * jitter_ema, 0.7 * jitter_peak), 2.0, 10.0)
	# move the delay slowly so remote vehicles never visibly speed up or slow down
	var step := 0.04 if target > interp_delay else 0.01
	interp_delay = move_toward(interp_delay, target, step)

func _apply_vehicles(st: Dictionary, stick: int) -> void:
	for slot in st.v:
		var s: PackedInt32Array = st.v[slot]
		var v: Vehicle = vehicles.get(slot)
		if v == null:
			var m := Vehicle.Mode.PROXY
			if slot == my_slot and predict_enabled:
				m = Vehicle.Mode.PREDICTED
			v = _spawn_vehicle(slot, m)
			v.place(Transform3D(Basis(Vector3.UP, Proto.dq_yaw(s[3])), Snapshot.pos_of(s)))
		var was_alive := v.alive
		var hp := float(s[Snapshot.VHP])
		if hp < prev_hp.get(slot, hp) - 0.5 and (s[8] & Snapshot.ST_ALIVE):
			Game.play_sfx("hit", v.visual_xf.origin, -4.0)
		prev_hp[slot] = hp
		v.hp = hp
		v.armor = float(s[Snapshot.VARMOR])
		v.alive = (s[8] & Snapshot.ST_ALIVE) != 0
		v.protect = 1.0 if (s[8] & Snapshot.ST_PROTECT) else 0.0
		v.firing = (s[8] & Snapshot.ST_FIRING) != 0
		v.boosting = (s[8] & Snapshot.ST_TURBO) != 0
		if v.mode == Vehicle.Mode.PROXY:
			v.weapon = (s[8] >> 3) & 7
			v.frozen = 1.0 if (s[8] & Snapshot.ST_FROZEN) else 0.0
			v.push_sample(stick, Snapshot.pos_of(s), Proto.dq_yaw(s[3]), Proto.dq_angle8(s[4]), Proto.dq_angle8(s[5]))
			_track_ghost(slot, stick, Snapshot.pos_of(s), Proto.dq_yaw(s[3]), v.alive)
		if v.alive != was_alive:
			v.set_visual_alive(v.alive)
	for slot in vehicles.keys():
		if not st.v.has(slot):
			vehicles[slot].queue_free()
			vehicles.erase(slot)

## Car-to-car prediction: each other car gets a collision stand-in in our predicted world, put
## where the server will have it at the tick being predicted (its last snapshot position moved on
## at its last measured velocity, at most 10 ticks ahead).
func _track_ghost(slot: int, stick: int, pos: Vector3, y: float, alive: bool) -> void:
	var tr: Array = ghost_track.get(slot, [])
	var vel := Vector3.ZERO
	if not tr.is_empty() and stick > int(tr[0]) and (pos - (tr[1] as Vector3)).length() < 12.0:
		vel = (pos - (tr[1] as Vector3)) / float(stick - int(tr[0]))
	ghost_track[slot] = [stick, pos, y, vel, alive]
	if not ghosts.has(slot) and predict_enabled and not Game.args.has("no-ghosts"):
		var col: Dictionary = Game.vehicle_collision(str(_info(slot).vid))
		var b := StaticBody3D.new()
		b.collision_layer = Vehicle.GHOST_LAYER
		b.collision_mask = 0
		b.set_meta("ghost_slot", slot)
		b.set_meta("ghost_vel", Vector3.ZERO)
		for sh in col.get("shapes", []):
			var cs := CollisionShape3D.new()
			cs.shape = sh[0]
			cs.transform = sh[1]
			b.add_child(cs)
		add_child(b)
		ghosts[slot] = b

## Moves the stand-ins to client tick t (in server ticks: t + ack_to_server).
func _place_ghosts(t: int) -> void:
	for slot in ghosts:
		var b: StaticBody3D = ghosts[slot]
		var tr: Array = ghost_track.get(slot, [])
		if tr.is_empty() or not vehicles.has(slot) or not bool(tr[4]):
			b.process_mode = Node.PROCESS_MODE_DISABLED
			b.global_position = Vector3(0, -1000, 0)
			continue
		b.process_mode = Node.PROCESS_MODE_INHERIT
		var ahead := clampf(float(t + ack_to_server - int(tr[0])), 0.0, 10.0)
		b.global_transform = Transform3D(Basis(Vector3.UP, tr[2]), (tr[1] as Vector3) + (tr[3] as Vector3) * ahead)
		b.set_meta("ghost_vel", (tr[3] as Vector3) * Proto.TICK_RATE)

## Our side of a predicted ram: the push the server gives the rammer (the rammed car's damage and
## shove are the server's business).
func _predict_rams(me: Vehicle, dt: float) -> void:
	for k in pred_ram_cd.keys():
		pred_ram_cd[k] -= dt
		if pred_ram_cd[k] <= 0.0:
			pred_ram_cd.erase(k)
	for r in me.rams:
		var slot: int = (r[0] as Node).get_meta("ghost_slot")
		var closing: float = r[2]
		if pred_ram_cd.get(slot, 0.0) > 0.0:
			pred_ram_cd[slot] = 0.15
			continue
		if closing < RAM_MIN_SPEED:
			continue
		pred_ram_cd[slot] = 0.15
		var o: Vehicle = vehicles.get(slot)
		var mb: float = o.veh_mass if o != null else 1.0
		var ma := me.veh_mass
		var j := 1.3 * closing / (1.0 / ma + 1.0 / mb)
		var n: Vector3 = r[1]
		me.add_impulse(Vector3(n.x, 0.0, n.z).normalized() * j / ma * 0.5)

func _apply_projectiles(st: Dictionary, stick: int) -> void:
	for id in st.p:
		var s: PackedInt32Array = st.p[id]
		var pr: Projectile = projectiles.get(id)
		if pr == null:
			var kind: int = s[Snapshot.PKIND]
			var owner: int = s[Snapshot.POWNER]
			if owner == my_slot:
				for i in pred_specials.size():
					var cand: Projectile = pred_specials[i]
					if is_instance_valid(cand) and cand.type == kind:
						pr = cand
						pred_specials.remove_at(i)
						break
			if pr == null:
				pr = Projectile.new()
				pr.setup(kind, false, self)
				add_child(pr)
				if kind != Weapons.P_MINE and owner != my_slot:
					Game.play_sfx("missile", Snapshot.pos_of(s))
			pr.id = id
			pr.owner_id = owner
			pr.own = owner == my_slot
			projectiles[id] = pr
		pr.push_sample(stick, Snapshot.pos_of(s), Proto.dq_yaw(s[3]), Proto.dq_angle8(s[4]))
	for id in projectiles.keys():
		if not st.p.has(id):
			var gone: Projectile = projectiles[id]
			if is_instance_valid(gone):
				gone.queue_free()
			projectiles.erase(id)
	# predicted shots the server never confirmed
	for i in range(pred_specials.size() - 1, -1, -1):
		if not is_instance_valid(pred_specials[i]):
			pred_specials.remove_at(i)

## Server state for our vehicle at input tick `ack`: compare with what we predicted for that
## tick; if different, rewind to the server state and replay the newer inputs, then hide the
## jump with a decaying visual offset.
## True when the predicted and the server's driving state agree within the wire resolution.
func _drive_state_close(pred: Dictionary, own: Dictionary) -> bool:
	return pred.sliding == own.sliding and pred.reverse_mode == own.reverse_mode \
		and absf(pred.spd - own.spd) < 1.0 and absf(pred.steer_s - own.steer_s) < 0.5 \
		and absf(angle_difference(pred.travel, own.travel)) < 0.002 and _wheels_close(pred, own) \
		and absf(float(pred.get("phase", 0.0)) - float(own.get("phase", 0.0))) < 0.01

## Wheel corners (height, vertical speed, airtime) match what the server sent, to its precision.
func _wheels_close(pred: Dictionary, own: Dictionary) -> bool:
	if not own.has("wh") or not pred.has("wh"):
		return true
	for i in 4:
		if absf(pred.wh[i] - own.wh[i]) > 0.003 or absf(pred.wv[i] - own.wv[i]) > 0.02 or (pred.wn[i] < 0.0) != (own.wn[i] < 0.0) \
				or absf(maxf(pred.wn[i], 0.0) - maxf(own.wn[i], 0.0)) > 0.3:
			return false
	return true

func _reconcile(ack: int, own: Dictionary) -> void:
	var me: Vehicle = vehicles.get(my_slot)
	if me == null:
		return
	me.ammo = own.ammo
	me.weapon = own.weapon
	me.energy = own.energy
	me.heat = own.heat
	me.mg_locked = own.locked
	if me.mode != Vehicle.Mode.PREDICTED or ack <= last_ack or ack <= 0:
		return
	last_ack = ack
	ack_to_server = latest_snap - ack
	if not own.alive:
		me.alive = false
		return
	var pred = pred_hist.get(ack)
	if pred != null and not pred.get("alive", true):
		pred = null   # we were dead at that tick: this is a respawn, not a prediction error
	var err := 1e9
	if pred != null:
		err = (pred.pos as Vector3).distance_to(own.pos)
		corr_count += 1
		corr_sum += err
		corr_max = maxf(corr_max, err)
		corr_last = err
		if err > 1.0:
			corr_big += 1
		if err > float(Game.args.get("diag-min", "0.25")) and Game.args.has("diag"):
			var near := 99.0
			for o in vehicles.values():
				if o != me and o.alive:
					near = minf(near, o.global_position.distance_to(own.pos))
			print("[diag] t=%d err=%.2f near=%.1f gr=%s/%s spd=%.1f/%.1f dvy=%.2f turbo=%.2f/%.2f fz=%.2f/%.2f pos=%s" % [ack, err, near, pred.grounded, own.grounded, (pred.vel as Vector3).length(), (own.vel as Vector3).length(), (pred.vel as Vector3).y - (own.vel as Vector3).y, pred.turbo, own.turbo, pred.frozen, own.frozen, str((own.pos as Vector3).snapped(Vector3.ONE * 0.1))])
		if trace_pred:
			print("[tp-r slot=%d ack=%d ct=%d err=%.4f sp=%.5f,%.5f,%.5f sv=%.4f,%.4f,%.4f sy=%.6f sg=%d" % [my_slot, ack, client_tick, err, own.pos.x, own.pos.y, own.pos.z, own.vel.x, own.vel.y, own.vel.z, own.yaw, 1 if own.grounded else 0])
		var bucket := 0 if err < 0.05 else (1 if err < 0.25 else (2 if err < 1.0 else 3))
		corr_hist[bucket] += 1
		var dyaw := absf(angle_difference(pred.yaw, own.yaw))
		var dvel := (pred.vel as Vector3).distance_to(own.vel)
		if err < 0.003 and dyaw < 0.002 and dvel < 0.02 and pred.grounded == own.grounded and absf(pred.turbo - own.turbo) < 0.05 and absf(pred.frozen - own.frozen) < 0.05 and _drive_state_close(pred, own):
			return
	reconcile_count += 1
	var before := me.global_position
	var before_yaw := me.yaw
	me.alive = true
	var at_ack = pred_hist.get(ack)
	me.set_state(own)   # includes the driving state (speed, steering angle, travel direction, slide, reverse, stop ticks)
	if at_ack != null and at_ack.has("flip_cd"):
		me.flip_cd = at_ack.flip_cd   # the unstuck cooldown is not in the snapshot; ours mirrors the server's
	if at_ack != null and at_ack.has("ram_cd"):
		pred_ram_cd = (at_ack.ram_cd as Dictionary).duplicate()
	for t in range(ack + 1, client_tick + 1):
		var e: Array = input_hist.get(t, [0, 0.0, false])
		var lv: bool = e[2] and me.alive
		# replay the R-key unstuck exactly as _client_tick predicted it (edge of the reset chord)
		var prev_b: int = input_hist.get(t - 1, [0, 0.0, false])[0]
		if lv and me.frozen <= 0.0 and Proto.is_reset(e[0]) and not Proto.is_reset(prev_b):
			me.request_upright()
		me.flip_cd = maxf(me.flip_cd - Proto.TICK_DT, 0.0)
		_place_ghosts(t)
		me.sim_step(e[0] if lv else 0, e[1] if lv else 0.0, Proto.TICK_DT)
		_predict_rams(me, Proto.TICK_DT)
		var ps := me.get_state()
		ps.alive = me.alive
		ps.flip_cd = me.flip_cd
		ps.ram_cd = pred_ram_cd.duplicate()
		pred_hist[t] = ps
		replay_ticks += 1
	if pred == null or before.distance_to(me.global_position) > 8.0:
		me.reset_render_history()
		me.vis_offset = Vector3.ZERO
		me.vis_yaw_offset = 0.0
	else:
		me.add_correction(before - me.global_position, angle_difference(me.yaw, before_yaw))

func _on_events(p: PackedByteArray) -> void:
	var r := Proto.reader(p)
	r.get_u8()
	var seq := r.get_u16()
	var n := r.get_u8()
	# sequenced: drop anything older than what we already applied (16-bit wrap-safe)
	if ev_expected > 0 and ((seq - ev_expected) & 0xFFFF) >= 0x8000:
		return
	for i in n:
		var kind := r.get_u8()
		match kind:
			Proto.EV_KILL:
				var killer := r.get_u8()
				var victim := r.get_u8()
				var wid := r.get_u8()
				var wname: String = Proto.WEAPON_IDS[wid] if wid < Proto.WEAPON_IDS.size() else "?"
				var text := ("%s crashed" % _name_of(victim)) if killer == 255 else ("%s [%s] %s" % [_name_of(killer), wname, _name_of(victim)])
				hud.add_feed(text)
				if Game.args.has("verbose"):
					print("[match] kill: %s" % text)
			Proto.EV_EXPLOSION:
				var pos := Vector3(r.get_16(), r.get_16(), r.get_16()) / Proto.POS_Q
				var rad := r.get_u8() / 4.0
				Fx.explosion(self, pos, rad)
				Game.play_sfx("explosion", pos)
			Proto.EV_RAM:
				var pos2 := Vector3(r.get_16(), r.get_16(), r.get_16()) / Proto.POS_Q
				r.get_u8()
				Game.play_sfx("hit", pos2)
			Proto.EV_SCORES:
				var cnt := r.get_u8()
				var s := {}
				for k in cnt:
					var slot := r.get_u8()
					s[slot] = [r.get_u16(), r.get_u16()]
				scores = s
			Proto.EV_OVER:
				var win := r.get_u8()
				over = true
				over_text = "%s wins!" % _name_of(win)
				_store_results.call_deferred(win)
			Proto.EV_SPECIAL:
				var sslot := r.get_u8()
				var skind := r.get_u8()
				var sv: Vehicle = vehicles.get(sslot)
				if sv != null:
					if skind == 0:
						Fx.flame(self, sv)
					else:
						Fx.shockwave(self, sv.visual_xf.origin)
			Proto.EV_LEFT:
				var slot2 := r.get_u8()
				hud.add_feed("%s left the game" % _name_of(slot2))
			Proto.EV_PROP:
				var prop_i := r.get_u8()
				var prop_state := r.get_u8()
				destructibles.on_event(prop_i, prop_state)
				if Game.args.has("verbose"):
					print("[match] prop %d -> state %d (%d of %d destroyed)" % [prop_i, prop_state, destructibles.destroyed_count(), destructibles.count()])
			_:
				push_warning("[match] unknown event %d" % kind)
				return
	ev_expected = seq + 1

## Final standings for the results page (shown in the menu after the match).
func _store_results(win: int) -> void:
	Game.last_results = {"winner": _name_of(win), "arena": arena_id, "rows": _board_rows(),
		"me": _name_of(my_slot), "time": Time.get_unix_time_from_system()}

func on_roster(new_roster: Dictionary) -> void:
	roster = new_roster
	for slot in vehicles:
		vehicles[slot].update_info(_info(slot))

# ---------------- client per-frame ----------------
func _process(delta: float) -> void:
	if is_server or finished:
		return
	var rt := render_tick()
	var now_t := server_now()
	for v in vehicles.values():
		if v.mode == Vehicle.Mode.PROXY:
			v.render_at(rt)
		v.update_visual(delta)
		VehicleDamageScript.update(v, delta)
		if v.mode == Vehicle.Mode.PROXY:
			if v.firing and v.alive:
				tracer_cd[v.pid] = tracer_cd.get(v.pid, 0.0) - delta
				if tracer_cd[v.pid] <= 0.0:
					tracer_cd[v.pid] = 0.1
					_tracer_from(v, false)
	for pr in projectiles.values():
		if is_instance_valid(pr):
			pr.render(rt, now_t, delta)
	for pr2 in pred_specials:
		if is_instance_valid(pr2):
			pr2.render(rt, now_t, delta)
	destructibles.client_process(vehicles)
	var me: Vehicle = vehicles.get(my_slot)
	if me != null:
		cam.follow(me.visual_xf, delta)
	for i in pickup_nodes.size():
		pickup_nodes[i].visible = pickup_active[i]
	for i in mini(pickup_active.size(), prev_pickups.size()):
		if prev_pickups[i] and not pickup_active[i]:
			Game.play_sfx("pickup", pickup_points[i])
	prev_pickups = pickup_active.duplicate()
	var kills: int = scores.get(my_slot, [0, 0])[0]
	hud.update_local(me, kills, int(settings.get("score_limit", 15)), time_left)
	var msg := ""
	if over_text != "":
		msg = over_text
	elif not started:
		msg = "Waiting for players..."
	elif me == null:
		msg = "Joining the match..."
	elif not me.alive:
		msg = "Destroyed - respawning..."
	hud.set_center(msg)
	var show_board := Input.is_action_pressed("scoreboard") or over
	hud.board_panel.visible = show_board
	board_accum -= delta
	if show_board and board_accum <= 0.0:
		board_accum = 0.25
		hud.update_board(_board_rows())

func _board_rows() -> Array:
	var rows: Array = []
	for slot in scores:
		rows.append([_name_of(slot), _info(slot).color, scores[slot][0], scores[slot][1]])
	rows.sort_custom(func(a, b): return a[2] > b[2] or (a[2] == b[2] and a[3] < b[3]))
	return rows

func _unhandled_input(event: InputEvent) -> void:
	if is_server:
		return
	if event.is_action_pressed("pause_menu"):
		_toggle_menu()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		net_stats.toggle_overlay()

func _toggle_menu() -> void:
	menu_open = not menu_open
	hud.pause_panel.visible = menu_open
