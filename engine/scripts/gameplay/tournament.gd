extends RefCounted
## The original's one-player structure (measured on the player's disc, games/twisted-metal/data/TUNING.md "Rules"),
## as an optional mode for one player plus bots, next to LAN deathmatch.
##
## Six levels in a fixed order. Each level is won when every opponent is destroyed; opponents
## have no spare lives. The player has 4 lives (3 spare) for the whole tournament, respawns
## after 91 game ticks at full health, and the 4th death ends the run. The last level adds a
## boss with 250 health. No time limit.
##
## Match settings used: mode = "tournament", level (1..6), lives_left (player lives at the start
## of this level; 4 on level 1). The lobby starts level + 1 with the lives that were left when a
## level is won (Tournament.next_settings), and stops when it is lost or level 6 is won.

const LEVELS := [
	{"arena": "XARENA/part1", "opponents": 1, "boss": false, "difficulty": "normal"},
	{"arena": "WH/part1", "opponents": 3, "boss": false, "difficulty": "normal"},
	{"arena": "XFWY/part1", "opponents": 5, "boss": false, "difficulty": "normal"},
	{"arena": "PARK/part1", "opponents": 6, "boss": false, "difficulty": "normal"},
	{"arena": "SUBURB/part1", "opponents": 8, "boss": false, "difficulty": "normal"},
	{"arena": "ROOF/part1", "opponents": 3, "boss": true, "difficulty": "hard"},
]
const LIVES := 4
const BOSS_HEALTH := 250.0
const RESPAWN_TICKS := 91

static func is_on(settings: Dictionary) -> bool:
	return str(settings.get("mode", "deathmatch")) == "tournament"

static func level_of(settings: Dictionary) -> int:
	return clampi(int(settings.get("level", 1)), 1, LEVELS.size())

static func level_info(level: int) -> Dictionary:
	return LEVELS[clampi(level, 1, LEVELS.size()) - 1]

## Bots for a level (one player plus these): the boss counts as one more opponent.
static func bot_count(level: int) -> int:
	var l := level_info(level)
	return int(l.opponents) + (1 if l.boss else 0)

## Settings for the first level.
static func start_settings() -> Dictionary:
	var l := level_info(1)
	return {"mode": "tournament", "level": 1, "lives_left": LIVES, "arena": l.arena,
		"bots": bot_count(1) + 1, "difficulty": l.difficulty, "time_limit": 0, "score_limit": 999}

## Settings for the level after a won one, or {} when the tournament is over.
static func next_settings(settings: Dictionary, won: bool, lives_left: int) -> Dictionary:
	var lv := level_of(settings)
	if not won or lv >= LEVELS.size() or lives_left <= 0:
		return {}
	var l := level_info(lv + 1)
	var s := settings.duplicate()
	s.level = lv + 1
	s.lives_left = lives_left
	s.arena = l.arena
	s.bots = bot_count(lv + 1) + 1
	s.difficulty = l.difficulty
	return s
