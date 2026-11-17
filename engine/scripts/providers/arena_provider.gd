class_name ArenaProvider
extends RefCounted
## Interface for anything that can supply an arena. A later disc loader can subclass this
## and be assigned to Game.arena_provider.
##
## build_arena() must return a Node3D that:
##  - has static collision on physics layer 1 (StaticBody3D etc.),
##  - has meta "spawn_points": Array of Transform3D (forward = -Z), at least 8,
##  - has meta "pickup_points": Array of Vector3.

func get_arena_name() -> String:
	return "Arena"

func build_arena() -> Node3D:
	return Node3D.new()
