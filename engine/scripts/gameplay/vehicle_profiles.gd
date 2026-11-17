class_name VehicleProfiles
extends RefCounted
## Profile registry. Built-in stand-ins 0..7 (original numbers and original specials, spread
## across the measured ranges: top speed 16-24 m/s, turning radius 3.8-5.8 m, health 100-140)
## are always available. When the player's data holds a tuning.json (measured numbers keyed by
## disc IDs), those profiles are loaded too and used when a model provider reports a disc ID.

# SI units: m/s, seconds, metres, rad/s^2. Specials are original designs for this game.
const BUILTIN := [
	{"name": "Dart",    "top_speed": 20.6, "t90": 0.80, "brake_time": 0.65, "coast_time": 1.6, "turn_radius": 4.6, "steer_rampup": 3.6, "mass": 0.8, "health": 100,
		"special": {"kind": "bolt", "name": "Needle", "damage": 12, "speed": 95.0, "cost": 3}},
	{"name": "Sprint",  "top_speed": 19.4, "t90": 1.00, "brake_time": 0.85, "coast_time": 1.9, "turn_radius": 4.4, "steer_rampup": 3.4, "mass": 0.9, "health": 100,
		"special": {"kind": "bolt", "name": "Lance", "damage": 16, "speed": 62.0, "cost": 4}},
	{"name": "Ranger",  "top_speed": 17.5, "t90": 1.30, "brake_time": 1.10, "coast_time": 2.3, "turn_radius": 4.0, "steer_rampup": 3.0, "mass": 1.0, "health": 105,
		"special": {"kind": "salvo", "name": "Scatter", "damage": 4, "speed": 45.0, "cost": 6}},
	{"name": "Rally",   "top_speed": 18.1, "t90": 1.55, "brake_time": 1.25, "coast_time": 2.5, "turn_radius": 4.2, "steer_rampup": 3.2, "mass": 1.0, "health": 110,
		"special": {"kind": "flame", "name": "Blowtorch", "damage": 20, "cost": 5}},
	{"name": "Cruiser", "top_speed": 16.3, "t90": 1.40, "brake_time": 1.40, "coast_time": 2.7, "turn_radius": 5.0, "steer_rampup": 2.8, "mass": 1.15, "health": 110,
		"special": {"kind": "shockwave", "name": "Pulse", "damage": 9, "cost": 6}},
	{"name": "Bruiser", "top_speed": 15.3, "t90": 1.70, "brake_time": 1.50, "coast_time": 2.8, "turn_radius": 5.3, "steer_rampup": 2.6, "mass": 1.3, "health": 120,
		"special": {"kind": "heavy", "name": "Slug", "damage": 30, "speed": 50.0, "cost": 7}},
	{"name": "Hauler",  "top_speed": 14.4, "t90": 1.90, "brake_time": 1.70, "coast_time": 3.0, "turn_radius": 5.6, "steer_rampup": 2.4, "mass": 1.45, "health": 130, "handbrake_mult": 2.0,
		"special": {"kind": "heavy", "name": "Anvil", "damage": 36, "speed": 42.0, "cost": 8}},
	{"name": "Tank",    "top_speed": 14.3, "t90": 1.95, "brake_time": 1.75, "coast_time": 3.1, "turn_radius": 5.8, "steer_rampup": 2.2, "mass": 1.6, "health": 140, "handbrake_mult": 2.0,
		"special": {"kind": "shockwave", "name": "Quake", "damage": 13, "cost": 7}},
]

var builtin: Array[VehicleProfile] = []
var disc: Dictionary = {}     # disc id -> VehicleProfile

func _init() -> void:
	for i in BUILTIN.size():
		builtin.append(VehicleProfile.from_builtin("builtin_%d" % (i + 1), BUILTIN[i]))

## Load measured profiles from a tuning.json. Returns the count.
func load_disc_tuning(path: String) -> int:
	disc.clear()
	if path == "" or not FileAccess.file_exists(path):
		return 0
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY or not d.has("vehicles"):
		return 0
	for k in d.vehicles:
		var p := VehicleProfile.from_tuning_entry(str(k), d.vehicles[k])
		disc[str(k)] = p
	return disc.size()

## model_index picks the built-in stand-in; a non-empty disc_id picks the measured profile.
func get_profile(model_index: int, disc_id := "") -> VehicleProfile:
	if disc_id != "" and disc.has(disc_id):
		return disc[disc_id]
	return builtin[posmod(model_index, builtin.size())]
