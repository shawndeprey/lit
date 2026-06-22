@tool
extends Node2D
class_name LitPointLight2D

## A point light source for the Lit system (plan §7.1).
##
## It draws nothing itself; the manager gathers every node in the `lit_lights`
## group each frame and packs it into the light-data texture (plan §8, §9.4).
## Properties are read live at pack time, so plain `@export`s suffice — they are
## fully animatable, and runtime refresh picks up changes every frame.
##
## Note on `light_mask`: CanvasItem already provides an inherited `light_mask`
## (int, default 1). We deliberately reuse that inherited property as this
## light's mask rather than redeclaring it (a redeclaration would collide with
## the base class). The dedicated mask UI/behavior lands in Phase 4 (plan §9.5);
## the pack already writes it.

enum BlendMode { ADD, SUBTRACT }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Falloff")
## Radius of influence in pixels; drives attenuation and AABB culling.
@export var range: float = 256.0
## Attenuation curve exponent (plan §9.2).
@export var falloff: float = 1.0
## Optional cookie/shape mask. Reserved — not wired into the v1 transport yet.
@export var texture: Texture2D
@export var texture_scale: float = 1.0

@export_group("Shading")
## Z-height above the surface; drives normal-mapped shading direction.
@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false
@export var shadow_color: Color = Color.BLACK
## 0 = very soft, 1 = hard (plan §9.3). Packed now, consumed in Phase 2.
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD


func _enter_tree() -> void:
	add_to_group("lit_lights")


func _exit_tree() -> void:
	remove_from_group("lit_lights")
