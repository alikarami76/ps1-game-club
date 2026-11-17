class_name VehicleModelProvider
extends RefCounted
## Interface for vehicle visuals. build_model() returns a Node3D whose origin is at ground level,
## front pointing to -Z, roughly 2 m wide and 4 m long. Physics uses a fixed box regardless.

func get_model_count() -> int:
	return 0

func get_model_name(_index: int) -> String:
	return "Vehicle"

func build_model(_index: int, _color: Color) -> Node3D:
	return Node3D.new()

## Neutral disc ID of this model, or "" for built-in stand-ins. A disc loader returns the ID
## used as the key in tuning.json so Game.profiles can hand back the measured profile.
func get_disc_id(_index: int) -> String:
	return ""
