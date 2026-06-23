@tool
@icon("res://addons/lit/icons/lit_spot_light_2d.svg")
extends Node2D
class_name LitSpotLight2D

## A spot light for the Lit system: a point light masked to a cone.
##
## Has a position like a point light plus an aim: the node's local +X (the way it
## points, set by rotation) is the direction the cone shines. `range` and `falloff`
## give the same radial attenuation as a point light, and `spot_angle` / `spot_softness`
## shape the cone. It reuses the point light's radial shadow march, so shadows come for
## free.
##
## As with the other lights, `light_mask` reuses the inherited CanvasItem property
## ("Visibility" in the inspector) and is matched against each receiver's `receiver_mask`.

enum BlendMode { ADD, SUBTRACT }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Falloff")
## Radius of influence in pixels; drives attenuation and AABB culling.
@export var range: float = 256.0
## Attenuation curve exponent.
@export var falloff: float = 1.0

@export_group("Cone")
## Half-angle from the aim direction to the cone edge, in degrees.
@export_range(0.0, 90.0) var spot_angle: float = 30.0
## Edge feather: 0 = hard cone edge, 1 = fades all the way from the center.
@export_range(0.0, 1.0) var spot_softness: float = 0.5

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
