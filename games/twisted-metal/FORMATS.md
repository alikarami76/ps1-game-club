# Twisted Metal (USA, PS1): file formats

Everything below was worked out from the player's own disc, with the tools in `tools/` and
`games/twisted-metal/dmd.py`, and checked against the running game in the headless emulator. No game files are
included in this repository. Addresses (`0x80...`) are PS1 RAM addresses in the USA release (`SCUS_943.04`).

The disc layout: `tools/disc.py` extracts the 164 ISO 9660 files of the data track and wraps the 8 CD-audio
tracks as WAV. The interesting files are under `UADMD/` (arena and car models, `.DMD`, with texture sets,
`.TMS`), `UATIM/`, `UASCREEN/`, `UABIOS/` (TIM images for the front end), `UADASH/` (dashboard textures),
`SND/UACORE.VAB` (sound effects) and the `.STR` movies.

## Disc and model formats

**TMS (textures):** `"TXSPC\0\0\0"`, u32 level id (matches its DMD), u32 count, then `count` x
(u32 size, TIM image). Each TIM carries its own video-memory position.

**DMD (models):** `"DXSPC\0\0\0"`, u32 level id, a pointer to itself, a pointer to the count,
u32 count, `count` top-level object pointers. The file is a memory image loaded at `0x800188B8`;
every pointer is an absolute PS1 address. Layout: one shared vertex pool (int16 x,y,z + pad) from
0x78, then a shared normal pool (int16, 4096 = 1.0), then the nodes and polygon lists, written
children first, so the top-level objects come last.

Each top-level object is a scene graph. A node's first word is `id << 16 | b1 << 8 | type`; the
id is a game object id (0 for most inner nodes); b1 is often the record length in words but is
not needed. Every node with children stores the child pointers inline:

| type | node | layout (offsets from the node) |
|---|---|---|
| 0x00 (`0x????FF00`) | mesh body | +4 vertices, +8 normals, +0xC polygons, +0x10 polygon count, +0x14/+0x18 flags, +0x1C bounding sphere (int32 x,y,z,r); polygons start at +0x2C, or at +0x5C when bit 31 of +0x18 is set (then a 3x3 int16 matrix, int32 vector and 4 words come first; that matrix does not place the mesh) |
| 0x01 | group | +4 bounding sphere (int32 x,y,z,r), +0x14 count (byte), +0x15 flags (bit 1 hidden, bit 2 never culled), +0x18 children |
| 0x02 | level of detail | +4 int32 x,y,z = the local point the camera distance is measured from, +0x10 count, +0x14 entries; each entry is (u32 far dist², u32 near dist², node) and the first one with near ≤ dist² < far is drawn. One model's levels can be spread over sibling LOD nodes |
| 0x03 | animation | +6 u16 delay, +8 first frame, +9 last frame, +0xA mode (0 loop, 1 ping-pong), +0xB frame count, +0xC current frame, +0xD direction, +0xE u16 timer, +0x10 one child per frame |
| 0x04 | translate | +4 int32 x,y,z, +0x12 count, +0x13 flags (bit 1 hidden), +0x14 children |
| 0x05 | rotate + translate | +4 3x3 int16 matrix stored column by column (4096 = 1.0), +0x18 int32 x,y,z, +0x26 count, +0x27 flags (bit 1 hidden), +0x28 children |
| 0x09 | switch | +4 slot (instance number), +6 count, +7 current state, +8 children (one per state) |
| 0x0B | spatial split | +4 flags (bit 1 hidden), +0xA region count n, +0xC child drawn when the camera is outside every region, +0x10 child drawn when it is inside one, +0x14 n pointers to region blocks |
| `0x????FF07`, `0x????FF08` | box leaf | matrix and extents, likely collision; no geometry |

The game's renderer walks the graph through a node-type jump table (dispatch at 0x800FDC80 in the
executable, table at 0x800F81B4). It skips hidden nodes and everything under them; in the files only
empty (collision-only) groups are hidden, so `dmd.py` (in this folder) skipping them changes nothing. To remove a
destroyed object or a taken pickup, the game sets the node's count byte (translate +0x12, group
+0x14) to 0.

A **region block** (0x0B) holds a 3x3 int16 matrix (+0, row by row, padded to 0x14 bytes), int32
x,y,z (+0x14, not used by the test), int16 x,y,z `low` at +0x20 and int16 x,y,z `size` at +0x28.
The game (0x800FE608) takes the camera position relative to the node, multiplies it by the matrix
(4096 = 1.0) to get p, and counts the camera inside when 0 < low + p < size on every axis. SUBURB
has one split: identity matrix, low (400, 1200, 800), size (29600, 16800, 2400), so the town box is
x -400..29200, y -1200..15600, z -800..1600. Inside it the game draws only the town (+0x10), outside
it only the outer freeway ring (+0xC); the halves do not overlap. ROOF has 17 splits (matrices -I or
a z flip): inside / outside versions of rooftop structures, e.g. node 0x7E49C draws a small room
(camera within x 9200..12400, y 3600..6800, z 7400..8000) instead of 256 exterior meshes. Checked in
the emulator by matching the frame's draw list against each child's polygons, at three camera spots.
`dmd.load()` returns both children of every split (as before), so ROOF's pairs overlap; an engine
should toggle them with `Split.contains(camera)` (see the variants API below).

**Placement rule:** world = M · local + T, accumulated from the root down: a translate node adds
M·t to T; a rotate+translate node adds M·t to T, then sets M = M·R. Meshes are shared and placed
many times (the Arena floor is one 2800x2800 quarter placed four times with 90° turns). The world
is z-up (sky dome and walls rise in +z, car wheels sit below the body).

**Top-level object ids:** 1 = the level (all scenery, floor included), 2 = the sky dome, 3 = the
Arena's floor (Arena only, which has no sky), 0x0A, 0x14 ... 0x78 = the vehicles, 0 = small
helper objects (explosion and smoke sprites, the cockpit, the HUD sheet), 0x138 = a pitchfork
(weapon), 0xC9 = a missile, 0x82 and 0x3F5 = the Rooftop boss models (only in ROOF), 0x2EE and
0x2F0 have no polygons. `dmd.load()` returns ids 1 and 3 in world space.

**Arena centres and the background colour:** the centres of SUBURB (the lot inside the graffiti
wall, and the back yards inside each block of houses) and XFWY (everything inside the sunken freeway
ring) have no polygons in any branch of the file. The game draws nothing there. Each level's start-up
code sets a screen clear colour (three int32 at 0x801B2B34), the GPU fills the frame with it, and the
sky dome covers the upper half. An emulator frame from inside SUBURB's lot shows flat ground of exactly
that colour, with no primitive under it in the frame's draw list, and the preview from the same spot
matches once its background is set to it. The car still drives on z = 0 there. `dmd.BACKGROUND` (and
`DiscDmd.BACKGROUND`) holds the colours, which `preview.py` now uses by default:

| arena | clear colour (r, g, b) |
|---|---|
| XARENA | 40, 40, 40 |
| WH | 75, 70, 55 |
| XFWY | 60, 45, 20 |
| PARK | 75, 60, 30 |
| SUBURB | 110, 110, 100 |
| ROOF | 0, 20, 0 |

An engine should use it as the camera's clear colour, and add a flat collision floor at z = 0 where
there is no polygon (SUBURB's lot). The PS1 shows these at 5 bits per channel, so 110 appears as 104.

**Switch nodes** draw only their current child (byte +7, 0 in every file). Meaning by tag, from the
game code and from rendering each state:

| switch tag | where | states | meaning |
|---|---|---|---|
| vehicle id + 1 (e.g. 0x0B for ICE) | each vehicle, slot 0 | 3 | body: intact, damaged, wrecked |
| vehicle id + 2 | each vehicle, slots 1-3, inside each body state | 2 or 3 | wheel (or track) frames; the game cycles them while the car moves |
| 0x258, 0x259 | XARENA, PARK | 2 | destructible prop: intact, wreck (the wreck state holds pickups) |
| 0x262 | WH, XFWY, PARK | 2 | destructible prop, 23 polygons: intact, wreck (with pickups in WH and PARK) |
| 0x264 | SUBURB | 2 | parked van: intact, burnt wreck (3 of them hide pickups) |
| 0x302 | SUBURB | 2 | sprite of a person in a lawn chair: normal, destroyed |
| 0x386 | SUBURB | 2 | grate over a pit: closed, open with two pickups |
| 0x398 | all but XARENA | 2 | sparking power panel: sparks, plain (set by game code around 0x80137064, not by damage) |
| 0x2F1, 0x2F2, 0x2F3 | all but XARENA | 7 | a foot soldier sprite (red armour): six frames, then an empty state; 0x2F3 climbs out of a hole. It animates when a car comes near |
| 0x2BC | XFWY | 2 | two-polygon prop, meaning not checked |
| 0x3E8-0x3EA, 0x3F1, 0x3F2, 0x3F8-0x3FB | ROOF | 2 | rooftop props; 0x3E8 is the 536-polygon centre piece; 0x3EA, 0x3F1, 0x3F2 and 0x3F9 hide 17 pickups |
| 0 (helper object 0x2EE and others) | all | 4-7 | explosion, smoke and pickup-icon frames, cycled by code |

At level start the game registers destructible targets by tag and slot (code at 0x80142690, up to
30) and gives each hit points (code at 0x80149700; `dmd.DESTRUCTIBLE`): 0x258 8, 0x259 3, 0x262 5,
0x263 15, 0x264 10, 0x265 20, 0x302 1, 0x386 25, 0x3E8 100, 0x3E9 1, 0x3EA 4, 0x3F1 and 0x3F2 4,
0x3F9 8. When a target reaches 0 the game spawns an explosion and, for these tags, sets the switch to
state 1 (routine 0x80142C30: `if state < count: node[7] = state`). Other targets (groups 0x2CB 12 hp,
0x2CC 3, 0x2D0 3, 0x2DA, 0x3EB-0x3ED, 0x3F0, 0x3F7 2) are removed instead by setting their count
byte to 0 (routine 0x80143150). Damage units are the game's weapon damage values.

**Animation nodes** draw frame byte +0xC (0 in every file). The timer counts renders (20 per second,
one per 3 emulator frames) and a frame lasts delay + 1 renders; the frame then steps from first to
last and wraps (mode 0) or bounces (mode 1, unused in the files). Measured: WH's delay-7 animation
changes frame every 24 emulator frames (0.4 s). Delays in the files: 7 (WH, PARK), 15 (XARENA), 30,
80 and 100 (ROOF), 1 to 11 on the ROOF boss model. Animations off screen do not advance.

**Variants API** (`games/twisted-metal/dmd.py`, mirrored in `engine/scripts/disc/dmd.gd`): `objects()` returns per
object `meshes` (the default state, unchanged), `switches` (`Switch`: offset, id, slot, count,
default, parent, `states` = one mesh list per child), `animations` (`Animation`: offset, id, delay,
first, last, mode, count, default, parent, `frames`) and `splits` (`Split`: offset, origin, regions,
`outside`, `inside`, `contains(camera)`). `states[default]` holds the same mesh objects as `meshes`;
the other states are walked after the default walk, and switches nested in them are added to the
list (`parent` = (index in `switches`, state)). A mesh is listed in its innermost switch's state, and
in an outer switch's state only while the inner switch is at its default. Each mesh has
`switch_node`, `switch_id`, `state`, `anim_node`, `frame`, `split_node`, `split_side` (innermost
node of each kind above it; -1 when none) and `tag`, `tag_node` (the nearest tagged node above it,
such as a pickup or a destructible). To show damage, hide `states[default]` and show `states[1]`; to
follow the game's split, show `inside` while `contains(camera)` is true and `outside` otherwise.

**Vehicle object ids** (select-screen order, read from RAM at match start for each choice):
ICE 0x0A, CAB 0x14, SEMI 0x1E, COP 0x32, LOWRIDER 0x64, LAMBO 0x3C, DUNEB 0x5A, HUMVEE 0x46,
HARLEY 0x50, VETTE 0x6E, MONSTERT 0x28, MADMAX 0x78 (`manifest.json` `vehicles.<ID>.object_id`).
The in-game vehicle models are the ones inside the arena files (about 100 units long);
`CARS.DMD` holds the same vehicles about 30 times larger, for the menus.

**Arena part 1 and part 2:** both parts of an arena hold the same level geometry (WH1/WH2 differ
in a few vertices; XARENA2 is laid out differently but has the same objects). They differ in which
vehicles they carry, because the PS1 cannot hold all twelve models next to a level. The game
(routine at 0x80154D84) picks the part from the player's vehicle; the enemies of that stage are
drawn from the same part:

| arena | part 1 when the player drives | part 2 otherwise |
|---|---|---|
| XARENA | always `XARENA1` (no choice) | - |
| WH, ROOF | 0x0A 0x14 0x1E 0x32 0x3C 0x64 | the other six |
| XFWY | 0x0A 0x14 0x1E 0x28 0x6E 0x78 | the other six |
| PARK | 0x0A 0x28 0x3C 0x64 0x6E 0x78 | the other six |
| SUBURB | all except 0x14 0x1E 0x64 0x78 | 0x14 0x1E 0x64 0x78 |

One-player stage order (level index at 0x8018ED04): 0 ARENA DUEL (XARENA), 1 WAREHOUSE DISTRICT
(WH), 2 FREEWAY (XFWY), 3 RIVER PARK (PARK), 4 CYBURBIA (SUBURB), 5 ROOFTOP COMBAT (ROOF; the
Minion final is also there), 6 = XARENA again. `UA2PLAY/2P*.DMD` are separate two-player levels.

**Polygon record:** byte0 = number of UV words (3 or 4; 0 when untextured), bit 7 = a `0xE2`
texture-window word follows the UVs; byte1 = colour-word count (1, 3 or 4); byte2 = record size
in words; byte3 = GPU packet size. Then 2 words of u16 vertex indices, the lighting word, the
colour words (top byte = PS1 GPU command, 0x20-0x3F; bit 0 = raw texture, bit 1 =
semi-transparent, bit 2 = textured, bit 3 = quad, bit 4 = Gouraud), the UV words (word 0 high
half = palette, word 1 high half = texture page), the optional `0xE2` word and the u16 normal
indices. Size in words = 4 + colours + UVs + E2 + ceil(normals / 2) for all 104,018 records on
the disc. Indices are relative to the mesh's vertex pointer, normal indices to its normal pointer.

Lighting word: bits 0-15 = the face normal's z (up) component, signed, 4096 = 1.0 (likely used for
ground tests; not for colour); bits 16-18 = kind (3 triangle, 4 quad, 0 or 1 sprite); bits 19-21 =
number of normal indices (0, 1, 3 or 4); bits 22-23 = primitive class, redundant with the GPU code
(bit 22 alone: flat untextured; bit 23 alone: flat textured or Gouraud untextured; both: Gouraud
textured);
bits 24-27 = colour + UV + E2 words; bits 28-29 = colour words; bits 30-31 = unknown flags
(bit 30 is set on most pre-lit Gouraud quads in levels).

**Lighting** (checked against an emulator frame of the Arena, vehicle and floor match):
a polygon with no normal indices is pre-lit and uses its colour words as stored (one flat colour or
one per vertex; the Arena floor's coloured spotlights are pre-lit vertex colours). With one normal
index the base colour (colour word 0) is lit once (flat); with 3 or 4 each vertex is lit with its
own normal (and its own colour word when there are 3 or 4, else colour word 0). Lighting is the
GTE's: colour = min(255, base * (ambient + sum over 3 lights of colour_k * max(0, dir_k . n))),
with ambient 0.125 and, in world space (z up):

| light | direction (x 4096) | colour (x 1/256) |
|---|---|---|
| 1 | (617, -3494, 2046) | (200, 200, 200) |
| 2 | (-3425, 1982, 1056) | (128, 75, 75) |
| 3 | (3332, 1928, 1398) | (60, 128, 60) |

These come from the game's light set-up routine (0x80104624, angles 170/30, -60/15, 60/20 degrees)
and are the same in every arena. Normals are int16 x, y, z + pad (8 bytes), unit 4096, and point
the same way as cross(v2 - v0, v1 - v0) for a polygon's vertices v0, v1, v2 in file order.
A textured polygon's final colour is texel * colour / 128 (bit 0 of the GPU code: texel only).
`dmd.vertex_colors(mesh, poly)` implements this; `dmd.LIGHTS` / `dmd.AMBIENT` hold the values.

**Textures:** texture page word bits 0-3 x base (x64), bit 4 y base (x256), bits 5-6 blend mode
(0 = back/2 + front/2, 1 = back + front, 2 = back - front, 3 = back + front/4), bits 7-8 colour mode
(0 = 4-bit, 1 = 8-bit, 2 = 15-bit direct; SUBURB uses all three). Colour 0x0000 is transparent;
on a semi-transparent polygon only texels with bit 15 set blend, the rest are opaque. The `0xE2`
word is a GPU texture window: mask = bits 0-4 / 5-9, offset = bits 10-14 / 15-19 (all x 8 texels),
sampled as u' = (u & ~mask_u) | (offset_u & mask_u). About 30,000 polygons use one to repeat a
tile; their UVs run outside the tile, which was the noise on signs and walls in older previews.

**Sprites** (kind 0 or 1): the four u16 "indices" are (centre vertex, half width, half height,
corner vertex). Sizes are world units; the centre usually sits half a height above the ground.
The corner vertex is the bottom-right corner in a rest pose (centre + right * w, z - h), which
lets the game get the on-screen size by projecting two points. Kind 0 sprites stay upright and turn
about z (trees, lamps, the clown head on Sweet Tooth); kind 1 sprites face the camera (explosions,
pickup labels, glows). Colours, UVs (top-left, top-right, bottom-left, bottom-right) and lighting
work as for quads. (Kind 0/1 behaviour is inferred from what uses them, not traced in code.)

**Pickups** are drawn as level meshes: a pink dome, a 48 x 18 additive glow sprite and a 34 x 13
(or 34 x 8) label sprite showing the weapon (FIRE, HOMING, FREEZE, POWER, REAR, REAR FLAME, OIL,
and two unlabelled icons). Their positions are in `games/twisted-metal/data/arenas/<ID>.json` (from the part 1 files;
part 2 has the same positions). Each glow + label pair sits under a translate node whose tag is the
pickup type: 0x191 FIRE, 0x192 FREEZE, 0x193 HOMING, 0x194 POWER, 0x195 REAR, 0x19A an unlabelled
machine icon, 0x19B REAR FLAME, 0x19C a silver disc, 0x19D OIL, 0x19E a spike icon, 0x1AE a single
red squiggle sprite. The game hides a taken pickup by setting the node's count byte to 0. ROOF has
only one pickup in its default state; 17 more sit in the wreck states of props 0x3EA, 0x3F1, 0x3F2
and 0x3F9 and appear when those are destroyed (XARENA hides 6 that way, WH 3, PARK 7, SUBURB 5).

**Start positions** come from game code (0x80123E64), not from the DMD: one spot for the
player and one for the opponent per arena, plus a heading (4096 = one turn; forward is
(sin h, cos h), so 0 faces +y). An alternative pair for XFWY, PARK and SUBURB is used when the
flag at 0x8018E828 is set (0 in every one-player match state; probably the two-player duel).
All are in `games/twisted-metal/data/arenas/<ID>.json`.

**Runtime (emulator RAM, for later measurements):** the DMD is loaded at 0x800188B8 and the
executable at 0x800F78B8. Placed-object records start at 0x8019171C, 0x10C bytes each, in this
order: level, then the 12 vehicles in object-id table order, then the floor. Record +0x08 = active,
+0x10 = parent, +0x14 = 3x3 int16 rotation, +0x58 = heading (low 12 bits), +0x5C/+0x60/+0x64 =
world x, y, z, +0x104 = pointer to the object in the loaded DMD. The words at 0x80191768/6C are the
camera's view-space translation, not the player's world position (they change with the player's
movement but in a rotated frame). Lights are kept at 0x801989C8-0x80198A5A.

## Audio formats

**VAB (`SND/UACORE.VAB`, sound effects and instruments):** standard PS1 VAB in one file. 32-byte
header (`"pBAV"`, version 6), 128 program records, 16 x 32-byte tone slots per used program
(59 programs, 172 tones), a table of 256 u16 sample sizes (units of 8 bytes), then 25 SPU ADPCM
samples (16-byte blocks of 28 samples; flag bit0 = end, bit1 = loop, bit2 = loop start). Tone
`vag` numbers are 1-based. A sample plays at 44100 Hz when its tone's centre note is played; other
notes scale by `2**((note - center - fine/128) / 12)`. `tools/vab.py` writes `cache/sfx/vag_NN.wav`
(with a `smpl` loop chunk) and `index.json`; `tools/sfxlabel.py` adds best-guess labels
(spectrum and envelope only, low confidence).

**`.44D` files (`TMTRK2..9.44D`):** not data. Each is a directory entry pointing at one CD audio
track (TMTRK2 starts at LBA 39578 = end of the data track + 150; the next starts 13354 sectors
later, which equals the length of `music/track02.wav`). The size field in the entry is wrong, so
`cache/files/*.44D` are empty. The music is in `cache/music/track02..09.wav`; no XA in them.

**STR movies (`MOVIES/SLOGO15S`, `UAMOVIES/TMDMO15S, TMTTL15S, WHDMO15S`):** raw 2352-byte
sectors, 10 per frame (15 fps at 2x speed), 320x240. Video sectors (submode 0x42) carry a 32-byte
header plus a slice of the MDEC bitstream; audio sectors (submode 0x64, coding 0x01) are CD-XA
ADPCM, 4-bit stereo 37800 Hz, 1 audio sector per 7 video sectors. `tools/xa.py` decodes XA
ADPCM; `tools/str.py` writes `cache/movies/<name>.wav` and `<name>.json` and can reassemble each
frame's bitstream (`str.frames`). Video is not decoded to pixels (needs an MDEC emulation).

## Open questions

- Sprite kinds 0/1 (upright vs camera-facing) are inferred, not traced in the renderer code.
- Lighting-word bits 30-31, and the mesh-body matrix when bit 31 of +0x18 is set (it is -I or a
  mirror on some meshes and would put them in the wrong place if applied), and the 4 words after it.
- The 0xFF07/0xFF08 box leaves (likely collision): not decoded. The z = 0 floor under SUBURB's
  lot is assumed from the car resting there, not traced in the collision code.
- What the game does with a region block's int32 x,y,z (+0x14; the inside test ignores it) and with
  group flag bit 0 and translate/transform flag bit 0.
- Tags not checked in detail: switch 0x2BC (XFWY), the ROOF props 0x3E8-0x3FB, the four
  7-polygon translate nodes 0x25B in SUBURB (8 hit points in the damage code), and 0x263, 0x265,
  0x2BE (in the damage code, but no node in the one-player files uses them).
- How the game picks the wheel frame from speed, and the body damage thresholds (vehicle switch
  id + 1 states 1 and 2).
- Where enemies after the first enter (all non-player vehicles use the single "enemy" start).
- Pickup respawn rules (the count byte is restored somewhere in the pickup code at 0x80136C48).
- The unlabelled pickup icons (0x19A, 0x19C, 0x19E, 0x1AE) are not named yet.
- The clear colours of the two-player levels in `UA2PLAY/` were not measured.
- MDEC video decoding for the `.STR` movies (audio is done, see Audio formats).
- Game rules (handling, weapons, AI) live in `SCUS_943.04`. They were later measured in the emulator rather than re-created by feel: see `data/TUNING.md`.
