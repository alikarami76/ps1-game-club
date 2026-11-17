extends Node3D
## Switch nodes, animation nodes and destructible targets of a disc arena (README "Switch nodes",
## "Animation nodes", DESTRUCTIBLE). Two halves:
##
## analyse() / build_resources() (static, cached with the arena): split the level's meshes into
##   - base visual: drawn always (no switch or animation above them);
##   - base collision: every default mesh except the destructible targets';
##   - switches: per state the meshes whose innermost container is that switch ("own" meshes);
##     nested switches and animations hang below their parent's state;
##   - animations: per frame the meshes they own;
##   - targets: destructible switches (DESTRUCTIBLE tags plus 0x3F8: hit points, state 1 = wreck)
##     and tagged groups the game removes by setting their count byte to 0 (REMOVE_HP), each with
##     a collision shape per state and a hit box;
##   - hidden pickups: pickup nodes inside a target's wreck state, gated on that target.
##
## The node (one per built arena, child of the arena's Level node, so it shares its offset):
##   - one StaticBody3D per target (layer 1, meta "prop_index"), its shape swapped by state;
##   - on clients, one Node3D per switch state / animation frame holding MeshInstance3Ds; meshes
##     under a spatial split are shown on the camera's side only (like DiscArenaProvider);
##   - client-side animation: 0x03 nodes (frame time (delay + 1) / 20 s, loop or ping-pong), the
##     sparking panel 0x398 (random flicker), the foot soldiers 0x2F1-0x2F3 (frames 0-5 while a
##     vehicle is near) and "sequence" switches (more than two states, inside a target's wreck
##     state, e.g. ROOF 0x3FA/0x3FB: played once to the last state when the wreck appears).
## Which targets are destroyed is decided by the server (scripts/gameplay/destructibles.gd) and
## set here with set_destroyed(); collision follows the logical state on the server and on every
## client (sequence switches count as finished at once), visuals may animate.

const DiscDmdScript := preload("res://scripts/disc/dmd.gd")
const DiscMeshBuilderScript := preload("res://scripts/disc/mesh_builder.gd")

## Tagged groups the game removes (count byte = 0) when destroyed, with their hit points
## (README: 0x2CB 12, 0x2CC 3, 0x2D0 3, the others 2). 0x25B (SUBURB, 8 hp in the damage code,
## meaning unchecked) and 0x2D1 (PARK, not in the damage code) are left static.
const REMOVE_HP := {0x2CB: 12, 0x2CC: 3, 0x2D0: 3, 0x2DA: 2, 0x3EB: 2, 0x3EC: 2, 0x3ED: 2, 0x3F0: 2, 0x3F7: 2}
## Destructible switch tags not in DiscDmd.DESTRUCTIBLE ("tags not listed have 1 hit point").
const EXTRA_SWITCH_HP := {0x3F8: 1}
const PANEL_TAG := 0x398
const SOLDIER_TAGS := [0x2F1, 0x2F2, 0x2F3]
const MIN_HIT_SIZE := 1.0         # metres: hit boxes are at least this big on every axis
const SOLDIER_RANGE := 30.0       # metres: soldiers animate while a vehicle is this close
const SOLDIER_FRAME := 0.12       # seconds per soldier frame
const SEQUENCE_FRAME := 0.1       # seconds per state of a sequence switch

enum Role { STATIC, TARGET, SEQUENCE, PANEL, SOLDIER }

# ------------------------------------------------------------------------------------------
# analysis (static, no Godot resources)
# ------------------------------------------------------------------------------------------

## objs: DiscDmd objects of one arena file. pickup_tags: tag -> label (pickup nodes).
## Returns a Dictionary (see the header); meshes are DiscDmd meshes.
static func analyse(objs: Array, pickup_tags: Dictionary) -> Dictionary:
	var d := {"switches": [], "anims": [], "targets": [], "base_visual": [], "base_collision": [],
		"all": [], "hidden_pickups": [], "splits": {}}
	for o in objs:
		if o.id in DiscDmdScript.LEVEL_IDS:
			_analyse_object(o, pickup_tags, d)
	return d

static func _analyse_object(o, pickup_tags: Dictionary, d: Dictionary) -> void:
	var sbase: int = d.switches.size()
	var abase: int = d.anims.size()
	for sp in o.splits:
		d.splits[sp.offset] = sp
	# depth of each switch (parents are always registered before their children)
	var depth := PackedInt32Array()
	for sw in o.switches:
		depth.append(0 if sw.parent.is_empty() else depth[sw.parent[0]] + 1)
	# innermost container of each mesh: [0 switch / 1 animation, index, state, depth]
	var cont := {}
	for si in o.switches.size():
		var sw = o.switches[si]
		for k in sw.states.size():
			for m in sw.states[k]:
				var c: Array = cont.get(m, [])
				if c.is_empty() or (c[0] == 0 and c[3] < depth[si]):
					cont[m] = [0, si, k, depth[si]]
	for ai in o.animations.size():
		var a = o.animations[ai]
		for k in a.frames.size():
			for m in a.frames[k]:
				cont[m] = [1, ai, k, 1 << 20]   # animations sit below switches
	# roles
	var roles := PackedInt32Array()
	for si in o.switches.size():
		var sw = o.switches[si]
		var role := Role.STATIC
		if DiscDmdScript.DESTRUCTIBLE.has(sw.id) or EXTRA_SWITCH_HP.has(sw.id):
			role = Role.TARGET
		elif sw.id == PANEL_TAG:
			role = Role.PANEL
		elif sw.id in SOLDIER_TAGS:
			role = Role.SOLDIER
		elif not sw.parent.is_empty() and sw.count > 2 and roles[sw.parent[0]] in [Role.TARGET, Role.SEQUENCE]:
			role = Role.SEQUENCE
		roles.append(role)
	# switch definitions
	var target_of := {}   # local switch index -> target index
	for si in o.switches.size():
		var sw = o.switches[si]
		var own: Array = []
		for k in sw.count:
			own.append([])
		var sd := {"role": roles[si], "id": sw.id, "slot": sw.slot, "count": sw.count, "default": sw.default,
			"parent": [] if sw.parent.is_empty() else [sbase + sw.parent[0], sw.parent[1]], "target": -1,
			"own": own, "center": Vector3.ZERO}
		if roles[si] == Role.TARGET:
			var hp: int = DiscDmdScript.DESTRUCTIBLE[sw.id][0] if DiscDmdScript.DESTRUCTIBLE.has(sw.id) else EXTRA_SWITCH_HP[sw.id]
			var states: Array = []
			for k in sw.count:
				var keep: Array = []
				for m in sw.states[k]:
					if _under_other_target(cont, m, si, o, roles):
						continue
					if k != sw.default and pickup_tags.has(m.tag):
						continue
					keep.append(m)
				states.append(keep)
			target_of[si] = d.targets.size()
			sd.target = d.targets.size()
			d.targets.append({"kind": "switch", "tag": sw.id, "slot": sw.slot, "hp": hp, "switch": sbase + si,
				"states": states, "hit": sw.states[sw.default] if not sw.states[sw.default].is_empty() else sw.states[mini(1, sw.count - 1)]})
		d.switches.append(sd)
	for ai in o.animations.size():
		var a = o.animations[ai]
		var frames: Array = []
		for k in a.count:
			frames.append([])
		d.anims.append({"delay": a.delay, "first": a.first, "last": a.last, "mode": a.mode, "count": a.count,
			"default": a.default, "parent": [] if a.parent.is_empty() else [sbase + a.parent[0], a.parent[1]], "frames": frames})
	for m in cont:
		var c2: Array = cont[m]
		if c2[0] == 0:
			d.switches[sbase + c2[1]].own[c2[2]].append(m)
		else:
			d.anims[abase + c2[1]].frames[c2[2]].append(m)
	# removed-by-count targets: default meshes with a REMOVE_HP tag, outside any switch/animation
	var removal := {}   # tag node -> target index
	var removed_meshes := {}
	for m in o.meshes:
		if REMOVE_HP.has(m.tag) and m.tag_node >= 0 and not cont.has(m):
			if not removal.has(m.tag_node):
				removal[m.tag_node] = d.targets.size()
				d.targets.append({"kind": "remove", "tag": m.tag, "slot": 0, "hp": REMOVE_HP[m.tag], "switch": -1,
					"states": [[], []], "hit": []})
			var t: Dictionary = d.targets[removal[m.tag_node]]
			t.states[0].append(m)
			t.hit.append(m)
			removed_meshes[m] = true
	# base lists
	var in_target := {}
	for si in target_of:
		for m in o.switches[si].states[o.switches[si].default]:
			in_target[m] = true
	for m in o.meshes:
		if removed_meshes.has(m):
			continue
		if not cont.has(m):
			d.base_visual.append(m)
		if not in_target.has(m):
			d.base_collision.append(m)
	d.all.append_array(o.meshes)
	var is_default := {}
	for m in o.meshes:
		is_default[m] = true
	for m in cont:
		if not is_default.has(m):
			d.all.append(m)
	# pickups inside non-default states, gated on the nearest target whose wreck holds them
	var nodes := {}   # pickup tag node -> [sum of centres, count, tag, gate]
	for m in cont:
		if not pickup_tags.has(m.tag) or m.tag_node < 0:
			continue
		var c3: Array = cont[m]
		var si2: int = c3[1]
		var k2: int = c3[2]
		if c3[0] == 1:   # in an animation: start from the animation's parent switch
			var ap: Array = o.animations[c3[1]].parent
			if ap.is_empty():
				continue
			si2 = ap[0]
			k2 = ap[1]
		var gate := -1
		var hidden := false
		while si2 >= 0:
			var sw2 = o.switches[si2]
			if k2 != sw2.default:
				hidden = true
				if target_of.has(si2):
					gate = target_of[si2]
					break
			if sw2.parent.is_empty():
				break
			k2 = sw2.parent[1]
			si2 = sw2.parent[0]
		if not hidden:
			continue
		var e: Array = nodes.get_or_add(m.tag_node, [Vector3.ZERO, 0, m.tag, gate])
		e[0] += m.center
		e[1] += 1
	var keys := nodes.keys()
	keys.sort()
	for k3 in keys:
		var e2: Array = nodes[k3]
		d.hidden_pickups.append([e2[0] / e2[1], pickup_tags[e2[2]], e2[3]])

## True when mesh m sits below another destructible switch nested inside switch si (that
## target has its own collision).
static func _under_other_target(cont: Dictionary, m, si: int, o, roles: PackedInt32Array) -> bool:
	var c: Array = cont.get(m, [])
	if c.is_empty():
		return false
	var cur: int = c[1]
	if c[0] == 1:
		var ap: Array = o.animations[c[1]].parent
		if ap.is_empty():
			return false
		cur = ap[0]
	while cur >= 0 and cur != si:
		if roles[cur] == Role.TARGET:
			return true
		var p: Array = o.switches[cur].parent
		cur = p[0] if not p.is_empty() else -1
	return false

# ------------------------------------------------------------------------------------------
# resources (meshes need an atlas; collision shapes and hit boxes are always built)
# ------------------------------------------------------------------------------------------

## Adds to d: "sw_meshes" (per switch, per state: [[split offset, side, ArrayMesh]]),
## "anim_meshes" (per animation, per frame), "remove_meshes" (per target, removal only),
## "shapes" (per target, per state: ConcavePolygonShape3D or null), "boxes" (per target AABB),
## "sw_centers" (per switch, Vector3). atlas = null: collision only.
static func build_resources(d: Dictionary, atlas, xf: Transform3D) -> void:
	var unit: float = xf.basis.get_scale().x
	d.shapes = []
	d.boxes = []
	for t in d.targets:
		var per: Array = []
		for st in t.states:
			var faces: PackedVector3Array = DiscMeshBuilderScript.collision_faces(st, xf)
			if faces.is_empty():
				per.append(null)
			else:
				var sh := ConcavePolygonShape3D.new()
				sh.backface_collision = true
				sh.set_faces(faces)
				per.append(sh)
		d.shapes.append(per)
		d.boxes.append(_box_of(t.hit, xf, unit))
	d.sw_centers = []
	for sd in d.switches:
		var all: Array = []
		for st2 in sd.own:
			all.append_array(st2)
		d.sw_centers.append(_box_of(all, xf, unit).get_center())
	d.sw_meshes = []
	d.anim_meshes = []
	d.remove_meshes = []
	d.has_visuals = atlas != null
	if atlas == null:
		return
	for sd2 in d.switches:
		var per2: Array = []
		for st3 in sd2.own:
			per2.append(_split_meshes(st3, atlas, xf))
		d.sw_meshes.append(per2)
	for ad in d.anims:
		var per3: Array = []
		for fr in ad.frames:
			per3.append(_split_meshes(fr, atlas, xf))
		d.anim_meshes.append(per3)
	for t2 in d.targets:
		d.remove_meshes.append(_split_meshes(t2.states[0], atlas, xf) if t2.kind == "remove" else [])

## [[split offset or -1, side, ArrayMesh]] for a mesh list, one entry per split side.
static func _split_meshes(meshes: Array, atlas, xf: Transform3D) -> Array:
	var groups := {}
	for m in meshes:
		var k: Array = [m.split_node, m.split_side] if m.split_node >= 0 else [-1, -1]
		groups.get_or_add(k, []).append(m)
	var out: Array = []
	for k2 in groups:
		var am: ArrayMesh = DiscMeshBuilderScript.build_mesh(groups[k2], atlas, xf)
		if am.get_surface_count() > 0:
			out.append([k2[0], k2[1], am])
	return out

## Bounds (Godot axes, after xf) of the polygons and sprites, at least MIN_HIT_SIZE per axis.
static func _box_of(meshes: Array, xf: Transform3D, unit: float) -> AABB:
	var box := AABB()
	var first := true
	for m in meshes:
		for v in m.vertices:
			var g: Vector3 = xf * DiscMeshBuilderScript.to_godot(v)
			box = AABB(g, Vector3.ZERO) if first else box.expand(g)
			first = false
		for s in m.sprites:
			var c: Vector3 = xf * DiscMeshBuilderScript.to_godot(s[0])
			var half := Vector3(s[1].size.x, s[1].size.y, s[1].size.x) * unit
			var sb := AABB(c - half, half * 2.0)
			box = sb if first else box.merge(sb)
			first = false
	var grow := Vector3(maxf(MIN_HIT_SIZE - box.size.x, 0.0), maxf(MIN_HIT_SIZE - box.size.y, 0.0), maxf(MIN_HIT_SIZE - box.size.z, 0.0))
	return AABB(box.position - grow * 0.5, box.size + grow)

# ------------------------------------------------------------------------------------------
# runtime node
# ------------------------------------------------------------------------------------------

var defs: Dictionary = {}
var visual := false
var destroyed := PackedByteArray()          # per target: 1 = destroyed (wreck shown / removed)
var vehicle_points: Array = []              # world positions of vehicles (soldiers react to them)
var _shapes: Array = []                     # per target: CollisionShape3D
var _sw_nodes: Array = []                   # per switch: Array of state Node3D (clients)
var _sw_state := PackedInt32Array()         # per switch: visible state (clients)
var _sw_timer := PackedFloat32Array()
var _seq_running := PackedByteArray()
var _anim_nodes: Array = []                 # per animation: Array of frame Node3D
var _anim_frame := PackedInt32Array()
var _anim_dir := PackedInt32Array()
var _anim_timer := PackedFloat32Array()
var _remove_nodes: Array = []               # per target: Node3D or null
var _split_items: Array = []                # [DmdSplit, MeshInstance3D, side]

## res: the analysed + built resources (shared, read only). with_visuals: build mesh nodes.
func setup(res: Dictionary, with_visuals: bool) -> void:
	defs = res
	visual = with_visuals and bool(res.get("has_visuals", false))
	var n_t: int = defs.targets.size()
	destroyed.resize(n_t)
	destroyed.fill(0)
	for i in n_t:
		var body := StaticBody3D.new()
		body.name = "Target%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta("prop_index", i)
		var cs := CollisionShape3D.new()
		body.add_child(cs)
		add_child(body)
		_shapes.append(cs)
	var n_s: int = defs.switches.size()
	_sw_state.resize(n_s)
	_sw_timer.resize(n_s)
	_seq_running.resize(n_s)
	for si in n_s:
		_sw_state[si] = defs.switches[si].default
		_sw_timer[si] = randf() * 0.5
	if visual:
		_build_visuals()
	set_process(visual)
	refresh()

func _build_visuals() -> void:
	var holder := Node3D.new()
	holder.name = "Visuals"
	add_child(holder)
	for si in defs.switches.size():
		var sd: Dictionary = defs.switches[si]
		var sn := Node3D.new()
		sn.name = "S%d_%x" % [si, sd.id]
		var states: Array = []
		for k in sd.count:
			var st := Node3D.new()
			st.name = "st%d" % k
			st.visible = k == sd.default
			for e in defs.sw_meshes[si][k]:
				_add_instance(st, e)
			sn.add_child(st)
			states.append(st)
		_sw_nodes.append(states)
		var parent: Node3D = holder if sd.parent.is_empty() else _sw_nodes[sd.parent[0]][sd.parent[1]]
		parent.add_child(sn)
	for ai in defs.anims.size():
		var ad: Dictionary = defs.anims[ai]
		var an := Node3D.new()
		an.name = "A%d" % ai
		var frames: Array = []
		for k in ad.count:
			var fr := Node3D.new()
			fr.name = "f%d" % k
			fr.visible = k == ad.default
			for e in defs.anim_meshes[ai][k]:
				_add_instance(fr, e)
			an.add_child(fr)
			frames.append(fr)
		_anim_nodes.append(frames)
		_anim_frame.append(ad.default)
		_anim_dir.append(1)
		_anim_timer.append(0.0)
		var parent2: Node3D = holder if ad.parent.is_empty() else _sw_nodes[ad.parent[0]][ad.parent[1]]
		parent2.add_child(an)
	for i in defs.targets.size():
		var rn: Node3D = null
		if defs.targets[i].kind == "remove":
			rn = Node3D.new()
			rn.name = "R%d_%x" % [i, defs.targets[i].tag]
			for e in defs.remove_meshes[i]:
				_add_instance(rn, e)
			holder.add_child(rn)
		_remove_nodes.append(rn)

func _add_instance(parent: Node3D, e: Array) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = e[2]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	if e[0] >= 0 and defs.splits.has(e[0]):
		mi.visible = e[1] == 0
		_split_items.append([defs.splits[e[0]], mi, e[1]])

func target_count() -> int:
	return destroyed.size()

func target_tag(i: int) -> int:
	return defs.targets[i].tag

func target_hp(i: int) -> int:
	return defs.targets[i].hp

## Hit box of target i in world space (axis-aligned in the arena's frame).
func target_box(i: int) -> AABB:
	return global_transform * (defs.boxes[i] as AABB)

## A target can be hit while it is intact and every switch above it shows the state it is in.
func is_active(i: int) -> bool:
	if destroyed[i]:
		return false
	var si: int = defs.targets[i].switch
	return si < 0 or _chain_active(si)

func is_destroyed(i: int) -> bool:
	return destroyed[i] != 0

func set_destroyed(i: int, on: bool) -> void:
	if i < 0 or i >= destroyed.size() or (destroyed[i] != 0) == on:
		return
	destroyed[i] = 1 if on else 0
	refresh()

## Logical state of switch si: what collision and the server use.
func _logical_state(si: int) -> int:
	var sd: Dictionary = defs.switches[si]
	match sd.role:
		Role.TARGET:
			return 1 if destroyed[sd.target] else sd.default
		Role.SEQUENCE:
			return sd.count - 1 if _chain_active(si) else sd.default
	return sd.default

## True when every switch above si is in the state si hangs from.
func _chain_active(si: int) -> bool:
	var p: Array = defs.switches[si].parent
	while not p.is_empty():
		if _logical_state(p[0]) != p[1]:
			return false
		p = defs.switches[p[0]].parent
	return true

## Re-applies collision (and target / sequence visuals) from the destroyed flags.
func refresh() -> void:
	for i in destroyed.size():
		var t: Dictionary = defs.targets[i]
		var cs: CollisionShape3D = _shapes[i]
		var shape = null
		if t.kind == "remove":
			shape = null if destroyed[i] else defs.shapes[i][0]
		elif t.switch < 0 or _chain_active(t.switch):
			shape = defs.shapes[i][1 if destroyed[i] else defs.switches[t.switch].default]
		cs.shape = shape
		cs.disabled = shape == null
	if not visual:
		return
	for si in defs.switches.size():
		var sd: Dictionary = defs.switches[si]
		if sd.role == Role.TARGET:
			_show_state(si, _logical_state(si))
		elif sd.role == Role.SEQUENCE:
			var on := _chain_active(si)
			if on and _seq_running[si] == 0 and _sw_state[si] == sd.default:
				_seq_running[si] = 1   # play it once, from the default to the last state
				_sw_timer[si] = 0.0
			elif not on:
				_seq_running[si] = 0
				_show_state(si, sd.default)
	for i in destroyed.size():
		if _remove_nodes[i] != null:
			_remove_nodes[i].visible = destroyed[i] == 0

func _show_state(si: int, k: int) -> void:
	if _sw_state[si] == k:
		return
	var nodes: Array = _sw_nodes[si]
	if _sw_state[si] < nodes.size():
		nodes[_sw_state[si]].visible = false
	if k < nodes.size():
		nodes[k].visible = true
	_sw_state[si] = k

## Destroyed flags as a bitset (target i = bit i % 8 of byte i / 8).
func bitset() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize((destroyed.size() + 7) / 8)
	out.fill(0)
	for i in destroyed.size():
		if destroyed[i]:
			out[i >> 3] |= 1 << (i & 7)
	return out

## Applies a bitset; returns the targets that changed to destroyed.
func apply_bitset(bits: PackedByteArray) -> Array:
	var changed: Array = []
	var any := false
	for i in destroyed.size():
		var on := (i >> 3) < bits.size() and (bits[i >> 3] & (1 << (i & 7))) != 0
		if on != (destroyed[i] != 0):
			destroyed[i] = 1 if on else 0
			any = true
			if on:
				changed.append(i)
	if any:
		refresh()
	return changed

# ---------------- client animation ----------------
func _ready() -> void:
	set_process(visual)   # Godot turns processing on at ready when _process exists

func _process(delta: float) -> void:
	if not visual:
		return
	_animate(delta)
	_update_splits()

func _animate(delta: float) -> void:
	for ai in _anim_nodes.size():
		var ad: Dictionary = defs.anims[ai]
		if ad.count < 2:
			continue
		_anim_timer[ai] += delta
		var ft: float = (ad.delay + 1) / 20.0
		if _anim_timer[ai] < ft:
			continue
		_anim_timer[ai] -= ft
		if _anim_timer[ai] > ft:
			_anim_timer[ai] = 0.0
		var first: int = clampi(ad.first, 0, ad.count - 1)
		var last: int = clampi(ad.last, first, ad.count - 1)
		var f := _anim_frame[ai]
		if ad.mode == 1:   # ping-pong
			if f + _anim_dir[ai] > last or f + _anim_dir[ai] < first:
				_anim_dir[ai] = -_anim_dir[ai]
			f = clampi(f + _anim_dir[ai], first, last)
		else:
			f = first if f >= last or f < first else f + 1
		if f != _anim_frame[ai]:
			_anim_nodes[ai][_anim_frame[ai]].visible = false
			_anim_nodes[ai][f].visible = true
			_anim_frame[ai] = f
	var inv := global_transform.affine_inverse()
	var near_pts: Array = []
	for p in vehicle_points:
		near_pts.append(inv * (p as Vector3))
	for si in defs.switches.size():
		var sd: Dictionary = defs.switches[si]
		match sd.role:
			Role.PANEL:
				# sparks on for a moment, then plain (set by game code, not by damage)
				_sw_timer[si] -= delta
				if _sw_timer[si] <= 0.0:
					var sparks := _sw_state[si] != 0
					_show_state(si, 0 if sparks else mini(1, sd.count - 1))
					_sw_timer[si] = randf_range(0.05, 0.25) if sparks else randf_range(0.15, 0.9)
			Role.SOLDIER:
				var near := false
				for q in near_pts:
					if (q as Vector3).distance_to(defs.sw_centers[si]) < SOLDIER_RANGE:
						near = true
						break
				if not near and _sw_state[si] == sd.default:
					continue
				_sw_timer[si] -= delta
				if _sw_timer[si] <= 0.0:
					_sw_timer[si] = SOLDIER_FRAME
					var frames: int = maxi(sd.count - 1, 1)   # the last state is empty
					var nk: int = (_sw_state[si] + 1) % frames
					if not near and nk == 0:
						nk = sd.default
					_show_state(si, nk)
			Role.SEQUENCE:
				if _seq_running[si] == 0:
					continue
				_sw_timer[si] -= delta
				if _sw_timer[si] <= 0.0:
					_sw_timer[si] = SEQUENCE_FRAME
					var nk2: int = _sw_state[si] + 1
					if nk2 >= sd.count - 1:
						nk2 = sd.count - 1
						_seq_running[si] = 0
					_show_state(si, nk2)

func _update_splits() -> void:
	if _split_items.is_empty():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var p: Vector3 = (get_parent() as Node3D).global_transform.affine_inverse() * cam.global_position
	var u: float = 1.0 / DiscMeshBuilderScript.WORLD_UNIT_M
	var w := Vector3(p.x, -p.z, p.y) * u
	var cache := {}
	for e in _split_items:
		var inside: bool = cache.get(e[0], false) if cache.has(e[0]) else e[0].contains(w)
		cache[e[0]] = inside
		e[1].visible = (e[2] == 1) == inside
