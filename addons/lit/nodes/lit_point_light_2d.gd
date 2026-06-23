@tool
@icon("res://addons/lit/icons/lit_point_light_2d.svg")
extends Node2D
class_name LitPointLight2D

## A point light for the Lit system.
##
## Draws nothing itself: the manager gathers every node in the `lit_lights` group each
## frame and packs it into the light-data texture. Properties are read live at pack
## time, so plain @exports are enough and stay fully animatable.
##
## `light_mask` reuses the inherited CanvasItem property (int, default 1, shown under
## "Visibility" in the inspector) rather than redeclaring it, which would collide with
## the base class. A receiver is lit by this light only if its `receiver_mask` shares a
## bit with this mask.

enum BlendMode { ADD, SUBTRACT }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Falloff")
## Radius of influence in pixels; drives attenuation and AABB culling.
@export var range: float = 256.0
## Attenuation curve exponent.
@export var falloff: float = 1.0
## Optional cookie/shape mask. Reserved, not wired into the transport yet.
@export var texture: Texture2D
@export var texture_scale: float = 1.0

@export_group("Shading")
## Z-height above the surface; drives normal-mapped shading direction.
@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false
@export var shadow_color: Color = Color.BLACK
## 0 = very soft, 1 = hard.
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD


func _enter_tree() -> void:
	add_to_group("lit_lights")


func _exit_tree() -> void:
	remove_from_group("lit_lights")
