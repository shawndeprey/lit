@tool
@icon("res://addons/lit/icons/lit_directional_light_2d.svg")
extends Node2D
class_name LitDirectionalLight2D

enum BlendMode { ADD, SUBTRACT }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Shading")

@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false
@export var shadow_color: Color = Color.BLACK

@export_range(0.0, 1.0) var shadow_hardness: float = 0.5

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD

func _enter_tree() -> void:
	add_to_group("lit_lights")

func _exit_tree() -> void:
	remove_from_group("lit_lights")
