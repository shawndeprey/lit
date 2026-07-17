@tool
@icon("res://addons/lit/icons/lit_directional_light_2d.svg")
extends Node2D
class_name LitDirectionalLight2D

## A directional light for the Lit system.
##
## Like LitPointLight2D but with no positional attenuation: the node's rotation defines
## the light direction (its local +X aims toward the source), so every receiver is lit
## from the same angle. `height` still tilts the shading vector out of the plane; lower
## is more grazing, higher more head-on. There is no `range`, `falloff` or cookie, and
## directional lights are never positionally culled.
##
## Shares the receiver and shadow code path with point lights via the type flag in the
## light-data texture. As with point lights, `light_mask` reuses the inherited CanvasItem
## property ("Visibility" in the inspector) and is matched against each receiver's
## `receiver_mask`.

enum BlendMode { ADD, SUBTRACT }

## Per-light shadow algorithm; order must match the flags bits packed by the registry.
enum ShadowAlgorithm { RAYMARCHED, CONE_TRACED, STOCHASTIC }

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Shading")
## Tilts the light out of the plane; drives normal-mapped shading. Lower values
## graze the surface (direction reads strongly), higher values face it head-on.
@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false
## RAYMARCHED: single SDF march with an estimated penumbra - the fast base option.
## CONE_TRACED: same single march, but the penumbra width comes physically from
## `source_angle`. STOCHASTIC: averages `shadow_samples` marches across the source's
## angular extent for true umbra/penumbra/antumbra - the realistic (and most
## expensive) option. Every Lit receiver in the scene is swapped to a shader variant
## compiled for the algorithms in use automatically (by the registry each frame).
@export var shadow_algorithm: ShadowAlgorithm = ShadowAlgorithm.RAYMARCHED:
	set(value):
		shadow_algorithm = value
		notify_property_list_changed()
@export var shadow_color: Color = Color.BLACK
## RAYMARCHED: 0 = very soft, 1 = hard. CONE_TRACED / STOCHASTIC: penumbra contrast -
## 0.5 is physically neutral, lower flattens the gradient, higher sharpens it.
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5
## Angular half-size of the source in degrees (CONE_TRACED / STOCHASTIC): how wide the
## light appears in the sky. The sun is about 0.25; larger reads as a big soft sky
## light with penumbras that grow with distance from the occluder.
@export_range(0.0, 30.0, 0.05) var source_angle: float = 3.0
## Shadow marches per fragment across the source (STOCHASTIC): more is smoother and
## slower. Clamped by lit/quality/shadow_samples_max.
@export_range(1, 32) var shadow_samples: int = 8
## STOCHASTIC sample placement: 0 = fixed stratified pattern (can band at low sample
## counts), 1 = per-pixel randomized (banding becomes fine grain).
@export_range(0.0, 1.0) var shadow_jitter: float = 1.0

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD


func _validate_property(property: Dictionary) -> void:
	# Show only the dials the selected algorithm reads.
	if property.name == "source_angle":
		if shadow_algorithm == ShadowAlgorithm.RAYMARCHED:
			property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == "shadow_samples" or property.name == "shadow_jitter":
		if shadow_algorithm != ShadowAlgorithm.STOCHASTIC:
			property.usage &= ~PROPERTY_USAGE_EDITOR


func _enter_tree() -> void:
	add_to_group("lit_lights")


func _exit_tree() -> void:
	remove_from_group("lit_lights")
