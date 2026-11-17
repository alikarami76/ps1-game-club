class_name Lobby
extends RefCounted
## One lobby on the server: members (up to 8), a host who changes settings and starts, and
## while playing, its own match in its own SubViewport (separate World3D / physics space), so
## matches in different lobbies never touch each other.

const MAX_PLAYERS := 8
const MATCH_SCRIPT := preload("res://scripts/gameplay/match.gd")
const Tournament := preload("res://scripts/gameplay/tournament.gd")
const DIFFICULTIES := ["easy", "normal", "hard"]
const PICKUP_RESPAWNS := [30, 60, 96]   # seconds (deathmatch); 96 is the original's measured value
const BOT_NAMES := ["Rivet", "Sprocket", "Gasket", "Piston", "Axle", "Torque", "Camber", "Clutch"]
const PALETTE := ["#d9382b", "#2f7de1", "#f2b632", "#3cb371", "#9b59d0", "#ef7f2e", "#2bc4c4", "#e05297"]

var id := 0
var name := ""
var server: Node                       # GameServer
var host_peer := 0
var state := "waiting"                 # waiting, match
var settings := {"arena": "test_yard", "score_limit": 15, "time_limit": 300, "bots": 4, "mode": "deathmatch",
	"difficulty": "normal", "pickup_respawn": 96}
var _bots_custom := false              # the host chose the bot count: arena changes no longer reset it
var _tour_difficulty := ""             # tournament: difficulty chosen by the host ("" = each level's own)
var members: Array = []                # [{peer, name, color, vid, ready, slot, has_arena}] in join order
var bots: Array = []                   # [{slot, name, color, vid}]
var viewport: SubViewport
var match_node: Node3D
var matches_played := 0

func _init(lobby_id: int, lobby_name: String, srv: Node) -> void:
	id = lobby_id
	name = lobby_name
	server = srv

func send(peer: int, data: PackedByteArray, reliable: bool) -> void:
	server.send_to(peer, data, reliable)

func human_count() -> int:
	return members.size()

func is_tournament() -> bool:
	return Tournament.is_on(settings)

func is_full() -> bool:
	return members.size() >= (1 if is_tournament() else MAX_PLAYERS)

## The original's opening is one opponent: a disc arena starts with 1 bot, the built-in yard with 4.
static func default_bots_for(arena: String) -> int:
	return 4 if arena == Game.TEST_YARD else 1

func member(peer: int) -> Dictionary:
	for m in members:
		if m.peer == peer:
			return m
	return {}

func _used_slots() -> Dictionary:
	var used := {}
	for m in members:
		if m.slot >= 0:
			used[m.slot] = true
	for b in bots:
		used[b.slot] = true
	return used

func _free_slot() -> int:
	var used := _used_slots()
	for s in MAX_PLAYERS:
		if not used.has(s):
			return s
	return -1

func _free_color() -> String:
	var used := {}
	for m in members:
		used[m.color] = true
	for c in PALETTE:
		if not used.has(c):
			return c
	return PALETTE[randi() % PALETTE.size()]

## The member's vehicle choices: built-in ones always; game-data ones when both this server
## and the member have game data (each simulates them from the shipped tuning and builds the
## collision from its own copy).
func _vehicle_choices(peer: int) -> PackedStringArray:
	var out := Game.builtin_vehicle_ids()
	if bool(server.peers.get(peer, {}).get("disc_vehicles", false)):
		var d := Game.disc_vehicle_ids()
		if not d.is_empty():
			out = d + out
	return out

func _member_has_arena(peer: int, arena: String) -> bool:
	return arena == Game.TEST_YARD or arena in server.peers.get(peer, {}).get("arenas", [])

func _refresh_arena_flags() -> void:
	for m in members:
		m.has_arena = _member_has_arena(m.peer, str(settings.arena))

func add_member(peer: int, pname: String) -> bool:
	if is_full():
		return false
	if members.is_empty() and state == "waiting":
		settings.arena = server.default_arena_for(peer)
		if not _bots_custom and not is_tournament():
			settings.bots = default_bots_for(str(settings.arena))
	var choices := _vehicle_choices(peer)
	var m := {"peer": peer, "name": _unique_name(pname), "color": _free_color(), "vid": choices[members.size() % choices.size()],
		"ready": false, "slot": -1, "has_arena": _member_has_arena(peer, str(settings.arena))}
	if state == "match":
		if _free_slot() < 0 and not bots.is_empty():
			var b: Dictionary = bots.pop_back()
			match_node.server_remove_player(b.slot)
		m.slot = _free_slot()
	members.append(m)
	if host_peer == 0:
		host_peer = peer
	if state == "match" and m.slot >= 0:
		match_node.server_add_player(m.slot, peer, _info_of(m))
		send(peer, Proto.ctrl({"t": "match_start", "roster": roster_json(), "settings": settings, "slot": m.slot}), true)
	broadcast_state()
	return true

func _unique_name(pname: String) -> String:
	var base := pname
	var n := 2
	var taken := func(x: String) -> bool:
		for o in members:
			if o.name == x:
				return true
		return false
	while taken.call(pname):
		pname = "%s %d" % [base.left(13), n]
		n += 1
	return pname

func remove_member(peer: int) -> void:
	var m := member(peer)
	if m.is_empty():
		return
	members.erase(m)
	if state == "match" and match_node != null and m.slot >= 0:
		match_node.server_remove_player(m.slot)
	if host_peer == peer:
		host_peer = members[0].peer if not members.is_empty() else 0
		if host_peer != 0:
			print("[lobby %s] host left, new host is %s" % [name, members[0].name])
	if members.is_empty():
		close()
	else:
		broadcast_state()

func close() -> void:
	_free_match()
	server.on_lobby_closed(self)

func set_member(peer: int, d: Dictionary) -> void:
	var m := member(peer)
	if m.is_empty():
		return
	if d.has("ready"):
		m.ready = bool(d.ready)
	if d.has("vid") and str(d.vid) in _vehicle_choices(peer):
		m.vid = str(d.vid)
	if d.has("color"):
		var c := str(d.color)
		if c.is_valid_html_color():
			m.color = "#" + Color.html(c).to_html(false)
	if d.has("name"):
		var nn := GameServer.clean_name(str(d.name))
		if nn != m.name:
			m.name = _unique_name(nn)
	if state == "match" and match_node != null and m.slot >= 0:
		match_node.server_update_info(m.slot, _info_of(m))
	broadcast_state()

func set_settings(peer: int, d: Dictionary) -> void:
	if peer != host_peer or state != "waiting":
		return
	if d.has("score_limit"):
		settings.score_limit = clampi(int(d.score_limit), 1, 100)
	if d.has("time_limit"):
		settings.time_limit = clampi(int(d.time_limit), 30, 3600)
	if d.has("mode"):
		_set_mode(peer, str(d.mode), d)
	var tour := is_tournament()
	if d.has("difficulty") and str(d.difficulty) in DIFFICULTIES:
		settings.difficulty = str(d.difficulty)
		_tour_difficulty = settings.difficulty if tour else ""
	if d.has("pickup_respawn"):
		settings.pickup_respawn = _nearest_respawn(float(d.pickup_respawn))
	if tour:
		# a tournament fixes arena, opponents and limits; only the level (test hook) and difficulty move
		if d.has("level"):
			_apply_tournament_level(clampi(int(d.level), 1, Tournament.LEVELS.size()), Tournament.LIVES)
		broadcast_state()
		return
	if d.has("score_limit"):
		settings.score_limit = clampi(int(d.score_limit), 1, 100)
	if d.has("time_limit"):
		settings.time_limit = clampi(int(d.time_limit), 30, 3600)
	if d.has("bots"):
		settings.bots = clampi(int(d.bots), 0, MAX_PLAYERS)
		_bots_custom = true
	if d.has("arena") and str(d.arena) in server.arena_ids():
		settings.arena = str(d.arena)
		if not _bots_custom:
			settings.bots = default_bots_for(str(settings.arena))
		_refresh_arena_flags()
	broadcast_state()

static func _nearest_respawn(v: float) -> int:
	var best: int = PICKUP_RESPAWNS[0]
	for o in PICKUP_RESPAWNS:
		if absf(float(o) - v) < absf(float(best) - v):
			best = o
	return best

## Switches between deathmatch and the one-player tournament. A tournament lobby takes one human.
func _set_mode(peer: int, mode: String, d: Dictionary) -> void:
	if mode == str(settings.get("mode", "deathmatch")):
		return
	if mode == "tournament":
		if members.size() > 1:
			send(peer, Proto.ctrl({"t": "error", "msg": "A tournament is for one player: everyone else must leave the lobby first"}), true)
			return
		var diff: String = str(d.difficulty) if str(d.get("difficulty", "")) in DIFFICULTIES else ""
		_tour_difficulty = diff
		_apply_tournament_level(clampi(int(d.get("level", 1)), 1, Tournament.LEVELS.size()), Tournament.LIVES)
	elif mode == "deathmatch":
		_tour_difficulty = ""
		var respawn = settings.get("pickup_respawn", 96)
		settings = {"arena": server.default_arena_for(members[0].peer) if not members.is_empty() else Game.TEST_YARD,
			"score_limit": 15, "time_limit": 300, "bots": 4, "mode": "deathmatch", "difficulty": "normal", "pickup_respawn": respawn}
		settings.bots = default_bots_for(str(settings.arena))
		_bots_custom = false
		_refresh_arena_flags()

## Settings for tournament level `lv` (level 1 is Tournament.start_settings()), keeping the
## host's difficulty choice; the original's 96 s pickup respawn.
func _apply_tournament_level(lv: int, lives: int) -> void:
	var s: Dictionary = Tournament.start_settings()
	if lv > 1:
		var l := Tournament.level_info(lv)
		s.level = lv
		s.arena = l.arena
		s.bots = Tournament.bot_count(lv) + 1
		s.difficulty = l.difficulty
	s.lives_left = lives
	if _tour_difficulty != "":
		s.difficulty = _tour_difficulty
	s.pickup_respawn = 96
	settings = s
	_refresh_arena_flags()

func _info_of(m: Dictionary) -> Dictionary:
	return {"name": m.name, "color": m.color, "vid": m.vid, "bot": false, "peer": m.peer}

func roster() -> Dictionary:
	var r := {}
	for m in members:
		if m.slot >= 0:
			r[m.slot] = _info_of(m)
	for b in bots:
		r[b.slot] = {"name": b.name, "color": b.color, "vid": b.vid, "bot": true, "peer": 0}
	return r

func roster_json() -> Dictionary:
	var r := {}
	var ro := roster()
	for k in ro:
		r[str(k)] = ro[k]
	return r

func start(peer: int) -> void:
	if peer != host_peer or state != "waiting":
		return
	_start_match(peer)

func _start_match(peer: int) -> void:
	if members.is_empty():
		return
	_refresh_arena_flags()
	var missing: Array = []
	for m in members:
		if not m.has_arena:
			missing.append(m.name)
	if not missing.is_empty():
		send(peer, Proto.ctrl({"t": "error", "msg": "%s cannot load this arena (no game data). Pick the built-in arena or wait until they set up their game data." % ", ".join(missing)}), true)
		return
	bots.clear()
	for i in members.size():
		members[i].slot = i
	var want := clampi(int(settings.bots), 0, MAX_PLAYERS) - members.size()
	var bot_vids := Game.disc_vehicle_ids()
	if bot_vids.is_empty():
		bot_vids = Game.builtin_vehicle_ids()
	for i in maxi(want, 0):
		var slot := _free_slot()
		bots.append({"slot": slot, "name": BOT_NAMES[slot % BOT_NAMES.size()], "color": PALETTE[(slot + 3) % PALETTE.size()], "vid": bot_vids[randi() % bot_vids.size()]})
	if roster().size() < 2:
		send(peer, Proto.ctrl({"t": "error", "msg": "Need at least 2 vehicles: add bots or wait for players"}), true)
		bots.clear()
		return
	state = "match"
	matches_played += 1
	viewport = SubViewport.new()
	viewport.name = "Lobby_%d_%d" % [id, matches_played]
	viewport.own_world_3d = true
	viewport.size = Vector2i(2, 2)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	server.add_child(viewport)
	match_node = Node3D.new()
	match_node.set_script(MATCH_SCRIPT)
	match_node.name = "Match"
	match_node.is_server = true
	match_node.lobby = self
	match_node.roster = roster()
	match_node.settings = settings.duplicate()
	for m in members:
		match_node.server_add_conn(m.peer, m.slot)
	viewport.add_child(match_node)
	var r := roster_json()
	for m in members:
		send(m.peer, Proto.ctrl({"t": "match_start", "roster": r, "settings": settings, "slot": m.slot}), true)
	print("[lobby %s] match %d started: %d players, %d bots" % [name, matches_played, members.size(), bots.size()])
	broadcast_state()

## Called by the match when its end screen is over: everyone returns to the lobby.
func on_match_finished() -> void:
	server.report_match(self)
	var tour: Dictionary = match_node.tour_result.duplicate(true) if match_node != null and "tour_result" in match_node else {}
	_free_match()
	state = "waiting"
	bots.clear()
	if not tour.is_empty() and tour.get("won", false) and not tour.get("next", {}).is_empty():
		# tournament: level won, start the next one with the lives that are left
		var nxt: Dictionary = tour.next
		var lv := int(nxt.get("level", 2))
		_apply_tournament_level(lv, int(nxt.get("lives_left", Tournament.LIVES)))
		print("[lobby %s] tournament: level %d cleared, starting level %d with %d lives" % [name, lv - 1, lv, int(settings.lives_left)])
		for m in members:
			m.slot = -1
		_start_match(host_peer)
		if state == "match":
			return
	for m in members:
		m.ready = false
		m.slot = -1
	if is_tournament():
		# game over or victory: back to the lobby, ready for a fresh run (level 1, 4 lives)
		print("[lobby %s] tournament over: %s at level %d" % [name, "won" if tour.get("won", false) else "game over", int(tour.get("level", 1))])
		_apply_tournament_level(1, Tournament.LIVES)
	for m in members:
		send(m.peer, Proto.ctrl({"t": "match_end", "tour": {"won": bool(tour.get("won", false)), "level": int(tour.get("level", 0)),
			"finished": not tour.is_empty()}}), true)
	broadcast_state()

func _free_match() -> void:
	if viewport != null and is_instance_valid(viewport):
		viewport.get_parent().remove_child(viewport)   # leaves the tree now; the next match may reuse the lobby at once
		viewport.queue_free()
	viewport = null
	match_node = null

func list_entry() -> Dictionary:
	var host_name := ""
	var hm := member(host_peer)
	if not hm.is_empty():
		host_name = hm.name
	return {"id": id, "name": name, "players": members.size(), "max": MAX_PLAYERS, "state": state, "host": host_name, "arena": settings.arena,
		"bots": int(settings.bots), "mode": str(settings.get("mode", "deathmatch"))}

func state_dict() -> Dictionary:
	return {"id": id, "name": name, "host": host_peer, "state": state, "settings": settings, "members": members, "bots": bots,
		"arenas": server.arena_ids(), "vehicles": Game.builtin_vehicle_ids() + Game.disc_vehicle_ids()}

func broadcast_state() -> void:
	var msg := {"t": "lobby", "lobby": state_dict()}
	if state == "match":
		msg.roster = roster_json()
	var data := Proto.ctrl(msg)
	for m in members:
		send(m.peer, data, true)
	server.lobbies_dirty = true
