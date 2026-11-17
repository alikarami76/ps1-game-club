# Disc content loader (GDScript): handoff

Paused on request. All work below is finished and tested; nothing is half-edited. No existing
game file was changed: everything is new under `scripts/disc/`, `scenes/disc/`, `tests/disc/`.

## Files added

| File | What it does |
|---|---|
| `scripts/disc/disc_files.gd` (`DiscFiles`) | The only reader of game data: `read_bytes(rel_path)` (manifest-relative, refuses absolute paths and `..`). Swap points: `DiscFiles.reader` (a Callable) or `DiscFiles.base_dir`; default is `GameData.root()`. `read_side_data()` finds `data/arenas/<ID>.json`. Named DiscFiles because `GameData` already exists. |
| `scripts/disc/manifest.gd` (`DiscManifest`) | Loads manifest.json, arena ids (`WH/part1`...), paths, vehicle names in select order, sha1 checks (`verify`, `verify_all`). |
| `scripts/disc/vram.gd` (`DiscVram`) | 1024x512 VRAM as an RG8 Image; loads TMS/TIM; decodes (tpage, clut) regions in 4/8/15-bit modes; colour 0 transparent; can mark STP texels (alpha 200). |
| `scripts/disc/dmd.gd` (`DiscDmd`) | Port of `games/twisted-metal/dmd.py` (version with normals, GTE lighting, texture windows, sprite sizes). Float64 transforms so results match Python exactly. Each function names its Python twin. |
| `scripts/disc/atlas.gd` (`DiscAtlas`) | Packs used page regions (and texture-window tiles, wrap-padded) into atlases, upscales once, caches PNG in `user://disc_cache/<manifest sha1>/`. Bump `VERSION` when decoding/packing changes. |
| `scripts/disc/upscale.gd` (`DiscUpscale`) | Scale2x (2x) and Scale2x twice (4x). |
| `scripts/disc/mesh_builder.gd` (`DiscMeshBuilder`) | ArrayMesh per arena/car, PS1 shader (texel*colour/128, cut-out, semi-transparency modes, texture-window wrap via CUSTOM0, sprites as billboards via CUSTOM1, sky at far plane), collision faces. Axis map (x,y,z) -> (x,z,-y); `WORLD_UNIT_M = 1/32`. |
| `scripts/disc/spawn_sampler.gd` (`DiscSpawnSampler`) | Floor queries on collision triangles: ground height, head-room, open-floor grid, farthest-point spreading. |
| `scripts/disc/disc_arena_provider.gd` (`DiscArenaProvider`) | ArenaProvider: level mesh, sky, trimesh collision (layer 1), spawn_points / pickup_points meta. Caches built resources per arena + upscale setting. |
| `scripts/disc/disc_vehicle_models.gd` (`DiscVehicleModels`) | VehicleModelProvider: 12 cars from the arena files by object id; `get_disc_id()` = manifest key (tuning.json key); meta `collision_shape` (convex hull), `size_m`. |
| `scripts/disc/disc_props.gd` (preloaded) | Switch states, animation frames and destructible targets of an arena: analysis, per-state meshes and collision, the runtime node (state swaps, client animation). |
| `scripts/disc/disc_vehicle_visual.gd` (preloaded) | Root script of a disc car: damage level (body switch state) and wheel frames. |
| `scripts/disc/disc_settings.gd` (`DiscSettings`) | `[disc] texture_upscale` in user://settings.cfg: 1/2/4, default 4 desktop, 2 Web. |
| `scripts/disc/sky_follow.gd`, `scripts/disc/viewer.gd`, `scenes/disc/viewer.tscn` | Sky dome follows the camera; free-fly viewer. |
| `tests/disc/disc_load_test.gd` | Headless: loads every arena + 12 cars, prints counts, timings, atlas sizes; `--upscale=N --fresh --only=ID --verify --data=DIR`. |
| `tests/disc/dmd_counts_test.gd`, `tests/disc/dmd_counts_ref.py` | Cross-check against games/twisted-metal/dmd.py (same line format). |

## Verified

- **Counts match Python exactly**: 280 object lines over 13 DMD files (meshes, polygons, vertices,
  sprites, textured, normals, texture-window polygons, and the sum of every lit vertex colour) are
  byte-identical to `dmd_counts_ref.py` output. Last checked against dmd.py md5 15a47e7e... (dmd.gd md5 5c2309cb...); the variant cross-check (switches, animations, splits) is `tests/disc/variants_test.gd` vs `tests/disc/variants_ref.py`
- **Checksums**: 95/95 files match the manifest.
- **Renders** (viewer, offscreen window): Arena, Warehouse, Rooftop, Park, Suburb and the car
  line-up look right: textures, tiled roads/walls, lighting, sprites, sky, car order and facing.
- **Car sizes** at 1/32 m: ICE 4.84 m, SEMI 6.84 m, LAMBO 3.66 m, HARLEY 2.78 m.
- **Timings** (native, M4; Web estimate 3-4x slower, not measured):

| arena (part1) | cached | first load 4x | first load 2x | atlas 4x |
|---|---|---|---|---|
| XARENA | 0.21 s | 1.2 s | 0.49 s | 4096x3232 |
| WH | 0.33 s | 1.1 s | 0.64 s | 4096x2336 |
| PARK | 0.50 s | 1.9 s | 1.0 s | 4080x3600 |
| ROOF | 0.26 s | 1.7 s | 0.84 s | 4096x2624 |
| SUBURB | 1.03 s | 2.8 s | 1.9 s | 4096x3200 |
| XFWY | 0.33 s | 1.8 s | 0.98 s | 4096x2720 |

  Upscale alone: 0.6-0.9 s per arena at 4x, 0.15-0.21 s at 2x. 12 cars: 0.27 s cached, 0.9 s first at 4x.
  (First-load numbers were measured before the last two optimisations, so they are slightly high.)

## Partial / known issues

- Centres of SUBURB and XFWY are empty (same in the Python preview): a decoder gap, likely LOD or
  0x0B split nodes.
- Switch / animation nodes: done (see "Props, damage states and animations" below).
- Blending is in linear space, not PS1 gamma space; subtract mode draws only STP texels;
  textures are perspective-correct, not PS1 affine.
- Collision is one trimesh of every polygon, decorations included; no surface types.
- Spawns: only 2 starts are decoded per arena; the other 6 are generated. ROOF has 1 decoded pickup
  (topped up to 8 with floor points).
- `data/arenas/<ID>.json` is outside gamedata and not in the manifest, so the Web build cannot
  read it yet (falls back to sampled spawns).
- Web export not run; code is thread-free and reads only through DiscFiles.
- While testing, `scripts/autoload/game.gd` had parse errors from another agent's in-progress
  edits (not from this work).

## Hook-up status (2026-11-16): all 7 edits applied

1. `game.gd`: `select_providers()` (after `--data`, again when the data page saves), plus a vehicle
   catalogue by id (`builtin_N` or manifest ids), `make_arena_provider(id)`, `vehicle_collision(vid)`.
2. `DiscFiles.reader = GameData.read_bytes` (web reads user://gamedata).
3. Arena id in lobby settings and `match_start`; the server builds `DiscArenaProvider` with
   `collision_only = true` (no textures) from its own game data; `host.sh --data`.
4. `cam.far` 1500.
5. Menu rewritten (arena list, texture quality, data page text).
6. Vehicle collision: capsule for ground contact + convex hull above 0.5 m (see README).
7. `games/twisted-metal/organize.py` copies `data/arenas/*.json` to `gamedata/data/arenas/` and lists them under
   `data_files`.

Decoder follow-ups applied: per-arena background colour (camera clear colour + ground plane at
z = 0), flat collision floor at z = 0, split switching by camera (drawing; collision keeps both
sides), wreck-state pickups made available from the start, pickup kinds by tag.
Destructible props, vehicle damage states, wheel frames and prop animations: done, see below.

## Props, damage states and animations (2026-11-16)

New files: `scripts/disc/disc_props.gd` (DiscProps), `scripts/disc/disc_vehicle_visual.gd`,
`scripts/gameplay/destructibles.gd`, `scripts/gameplay/vehicle_damage.gd` (all preloaded, no
class_name). Changed: `atlas.gd` (VERSION 3), `disc_arena_provider.gd`, `disc_vehicle_models.gd`;
additive edits in `match.gd`, `net/proto.gd` (VERSION 6, `EV_PROP` = 8), `net/snapshot.gd`.
`dmd.gd` is unchanged.

- **Atlas**: arenas pack every switch state and animation frame (`DiscProps.analyse().all`),
  vehicles every body state and wheel frame. Atlas sizes did not change noticeably.
- **Arena split** (`DiscProps.analyse`): each level mesh goes to its innermost switch or animation
  (by object identity in the `states` / `frames` lists, deepest switch wins). The base mesh is
  what no switch or animation owns; switch states and animation frames are separate
  MeshInstance3Ds below `Level/Props/Visuals`, nested like the file (a switch inside a state
  hangs below that state's node). Meshes under a spatial split follow the camera's side as
  before. Roles by tag: target (DESTRUCTIBLE + 0x3F8, 1 hp), panel 0x398, soldiers 0x2F1-0x2F3,
  sequence (more than 2 states inside a target's wreck: ROOF 0x3FA, 0x3FB), static (the rest,
  e.g. XFWY 0x2BC, drawn in their default state).
- **Targets**: per arena XARENA 4, WH 4, PARK 10, ROOF 45 (19 switches + 26 removal groups),
  SUBURB 25 (20 switches + five 0x2DA groups), XFWY 3. Removal groups are tagged nodes with
  `REMOVE_HP` tags (0x2CB 12, 0x2CC 3, 0x2D0 3, 0x2DA/0x3EB-0x3ED/0x3F0/0x3F7 2); 0x25B (SUBURB) and
  0x2D1 (PARK) are left static. Each target has its own StaticBody3D (layer 1, meta
  `prop_index`) with a shape per state (wreck pickups left out); the arena trimesh leaves the
  targets out. Spawn sampling still uses every default polygon, so spawns did not move.
  A target is hittable only while intact and while every switch above it is in the state it
  hangs from (ROOF 0x3F9 sits in 0x3FA state 9 inside 0x3F8's wreck: it becomes hittable once
  0x3F8 is destroyed; sequences count as finished at once for collision, and animate on clients).
- **Server** (`destructibles.gd`, from `match.gd`): hit points from DESTRUCTIBLE / REMOVE_HP in
  the game's damage units (MG 1, missiles 7-25). Damage from `Match.explode` (falloff by distance
  to the hit box, so missiles hitting a prop and the shockwave count), machine-gun rays whose
  first hit is a target body, and rams (closing speed above 6 m/s, from the vehicle's slide
  collisions; 0.6 per m/s above that x mass, + 1; not measured). At 0: collision swap, explosion
  event, `EV_PROP` (u8 target, u8 state) reliable event. Props stay destroyed for the match.
  Full snapshots end with `u8 n` + the destroyed bitset (only when the arena has targets), for
  late joiners. Environment `TM_PROPS_TEST=<s>` on the server destroys one random hittable
  target every s seconds (tests only).
- **Pickups in wreck states**: gated on the target whose wreck holds them (`pickup_gates` meta;
  XARENA 6, WH 3, PARK 7, SUBURB 5, ROOF 17, matching the README). They become available the
  tick after the prop is destroyed. Open pickups are topped up with floor points to at least 6
  (ROOF: 1 decoded + 5) and at least 8 in all; when decoded + hidden exceed the 32 snapshot bits,
  open ones are dropped first (SUBURB 29 + 5 -> 27 + 5).
- **Clients**: `EV_PROP` and the snapshot bitset call `DiscProps.set_destroyed` (wreck state or
  removal, collision swap for the predicted car). Animations: frame time (delay + 1) / 20 s,
  first..last, loop or ping-pong, unsynchronised. Panel 0x398 flickers (sparks 0.05-0.25 s,
  plain 0.15-0.9 s). Soldiers cycle frames 0-5 every 0.12 s while a vehicle is within 30 m.
  Sequences play once at 0.1 s per state when their wreck appears.
- **Vehicles**: `disc_vehicle_models.gd` builds "Body" (meshes outside the body switch, empty for
  all 12 cars), "D0".."D2" (body switch slot 0, found by slot rather than tag: LAMBO's body switch
  has tag 0) with the hull and the wheel frames of each state (wheel switches merged per frame;
  HARLEY and MONSTERT have none). `vehicle_damage.gd` (client, per frame, from the replicated
  health): level 1 at <= 50% health, 2 while dead (the wreck stays visible where it died until
  the respawn; it has no collision then), wheel frame steps 1.5 per metre driven, at most 20 a
  second (not measured). Smoke particles at levels 1 and 2 for every model; built-in models,
  which have no damage states, darken their materials (x0.6, x0.22) instead.

Test results (headless, 2026-11-16):

| Test | Result |
|---|---|
| Solo, 7 bots, 100 s, all 12 arena parts | 0 script errors from this work (4 transient main_menu.gd parse errors in some logs came from another agent's in-progress edit). Natural play destroyed props on 7 of 12 (XARENA 4/4 both parts with all 6 pickups revealed, WH2 1/4 revealing 1, ROOF 1-2, SUBURB 1, PARK and XFWY 0): bots never aim at props, so hits are stray missiles, MG and rams. |
| Same with `TM_PROPS_TEST=2` | every target destroyed on all 12 (45/45 on ROOF incl. the nested 0x3F9), every gated pickup revealed (6, 3, 7, 17, 5), the client saw every EV_PROP, 0 errors |
| Late joiner (SUBURB/part1, test mode every 3 s, joins after 60 s) | its first full snapshot set 20 of 25 destroyed, then events took it to 25/25 like the host; 0 errors |
| 8-client lobby, SUBURB/part1, 180 s | 2.38 KB/s down / 0.86 up per client (before: 2.73 on WH), server tick 0.99 / 6.3 ms, 0 errors; 1 prop destroyed by a ram |
| disc_load_test (4x, fresh atlases, then cached) | PASS, all arenas and 12 cars |
| Test Yard with built-in cars (`--no-disc-models`), 50 s | 0 errors; deaths exercised the darkened wrecks |
| dmd counts / variants cross-checks vs games/twisted-metal/dmd.py | identical (280 / 1207 lines) |

Not done / open:
- No visual check: renders need a window, which was not allowed; checked by structure only
  (state and frame triangle counts, visibility toggles). Worth one look at a damaged car, a wreck
  with its pickups, a ROOF sequence and the soldiers.
- Ram damage, wheel frame rate and the soldier trigger distance are guesses.
- Wrecked (dead) vehicles have no collision, and dead predicted cars may coast a little.
- 0x25B (SUBURB), 0x2D1 (PARK), 0x2BC (XFWY) stay static; tags 0x263/0x265/0x2CB/0x2D0/0x3EB are
  supported but not present in these files.
- A prop destroyed while a client predicts into it gives that client a short correction
  (collision swaps when the event arrives).

## Hook-up edits that were needed (kept for reference)

1. `scripts/autoload/game.gd`: choose providers after the `--data` override in `_ready()` and again
   after the data folder is saved:
   ```gdscript
   const DiscArena := preload("res://scripts/disc/disc_arena_provider.gd")
   const DiscCars := preload("res://scripts/disc/disc_vehicle_models.gd")
   func select_providers() -> void:
       if GameData.has_data() and DiscArena.is_available() and not args.has("no-disc-models"):
           DiscArena.clear_cache()
           arena_provider = DiscArena.new(str(args.get("arena", "")))   # e.g. "WH/part1"
           vehicle_provider = DiscCars.new()
       else:
           arena_provider = ProceduralArena.new()
           vehicle_provider = ProceduralVehicleModels.new()
   ```
   Use preloads: class names resolve only after an editor import (`Godot --headless --path engine --import`).
2. `scripts/autoload/game_data.gd`: for Web, make `root()` return the user:// copy (nothing else to
   change), or add `GameData.read_bytes(rel)` and set `DiscFiles.reader = GameData.read_bytes`.
3. Netcode: send the arena id in the match config; server and clients build `DiscArena.new(cfg.arena)`.
   The dedicated server needs the game data too (collision).
4. `scripts/gameplay/match.gd`: raise `cam.far` from 400 to about 1500 (XFWY bounds are 1260 m).
5. `scripts/ui/main_menu.gd`: arena picker (`DiscArena.arena_ids()`), texture-quality picker
   (`DiscSettings.UPSCALE_LABELS`, `DiscSettings.set_texture_upscale(DiscSettings.UPSCALE_CHOICES[i])`),
   and update the data-page text (models now come from the disc too).
6. Optional, `scripts/gameplay/vehicle.gd`: use the model's meta `collision_shape` (convex hull) instead
   of the fixed box.
7. Gamedata organiser: copy `data/arenas/*.json` into gamedata and list them in the manifest
   (`data_files` map, read by `DiscFiles.read_side_data`).

## Next steps

1. Apply hook-up edits 1, 4 and 5, then run a solo match on each arena (`--host --solo --arena=WH/part1`).
2. Apply edits 2, 3 and 7, then run a Web export in Chrome: check load times, memory at 2x, and the
   user:// cache.
3. When `games/twisted-metal/dmd.py` changes again: mirror it in `dmd.gd`, rerun the count comparison (commands in
   `tests/disc/dmd_counts_test.gd`), bump `DiscAtlas.VERSION` if textures change.
4. Fix the SUBURB/XFWY centre gap once the decoder explains it. Damage states are done (see above);
   look at them once in a window.
