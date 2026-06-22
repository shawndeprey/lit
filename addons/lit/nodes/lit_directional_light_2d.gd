@tool
extends Node2D
class_name LitDirectionalLight2D

## A directional light for the Lit system (plan §7.2, D5).
##
## Like LitPointLight2D, but with no positional attenuation: the node's
## **rotation** defines the light direction (its local +X / the way it "points"
## aims toward the light source), so every receiver is lit from the same angle.
## `height` still tilts the shading vector out of the plane — lower = more
## grazing/dramatic, higher = more head-on. There is no `range`, `falloff`, or
## cookie; directional lights are never positionally culled.
##
## Shares the receiver and shadow code path with point lights via the type flag
## in the light-data texture. As with point lights, `light_mask` reuses the
## inherited CanvasItem property (Phase 4 wires the mask system, plan §9.5).

enum BlendMode { ADD, SUBTRACT }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Shading")
## Tilts the light out of the plane; drives normal-mapped shading. Lower values
## graze the surface (direction reads strongly), higher values face it head-on.
@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false
@export var shadow_color: Color = Color.BLACK
## 0 = very soft, 1 = hard (plan §9.3).
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD


func _enter_tree() -> void:
	add_to_group("lit_lights")


func _exit_tree() -> void:
	remove_from_group("lit_lights")
