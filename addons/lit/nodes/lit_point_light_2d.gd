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

## Sizing mode for the cookie `texture`.
enum TextureSizeMode { NATIVE, FIT_RANGE }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Falloff")
## Radius of influence in pixels; drives attenuation and AABB culling.
@export var range: float = 256.0
## Attenuation curve exponent.
@export var falloff: float = 1.0

@export_group("Texture")
## Optional cookie: modulates the light, centered on the node and rotating with it.
## RGB tints, alpha shapes; outside the texture the light is dark. Clipped to `range`.
## With `falloff` 0 the texture alone defines the light's shape.
@export var texture: Texture2D
## Multiplier on the cookie's footprint.
@export var texture_scale: float = 1.0
## NATIVE: the cookie spans the texture's pixel size and follows node scale.
## FIT_RANGE: it spans the `range` footprint and ignores node scale.
@export var texture_size_mode: TextureSizeMode = TextureSizeMode.NATIVE
## Currently unused; not wired up yet.
@export var texture_offset: Vector2 = Vector2.ZERO

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
