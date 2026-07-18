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
## CONE_TRACED (the default): a single signed-coverage cone march - penumbras widen
## with distance, umbras taper closed, and an antumbra re-brightens, all driven
## physically by `source_angle`. RAYMARCHED: the classic estimated-penumbra march -
## fastest, stylized, hardness-driven. STOCHASTIC: splits the source's angular extent
## into `shadow_samples` sub-cones for ground-truth area shadows - the most expensive
## option. Every Lit receiver in the scene is swapped to a shader variant compiled for
## the algorithms in use automatically (by the registry each frame).
@export var shadow_algorithm: ShadowAlgorithm = ShadowAlgorithm.CONE_TRACED:
	set(value):
		shadow_algorithm = value
		notify_property_list_changed()
@export var shadow_color: Color = Color.BLACK
## RAYMARCHED: 0 = very soft, 1 = hard. CONE_TRACED / STOCHASTIC: penumbra contrast -
## 0.5 is physically neutral, lower flattens the gradient, higher sharpens it.
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5
## Angular size (full diameter) of the source in degrees (CONE_TRACED / STOCHASTIC):
## how wide the light appears in the sky, the same convention as Unreal's Source Angle
## (0.5357), Unity HDRP's Angular Diameter (0.5) and Blender's Sun Angle (0.526) - the
## sun is about 0.53. Larger reads as a big soft sky light with penumbras that grow
## with distance from the occluder; the default is deliberately sun x ~11 so the
## softness is visible at game scale.
@export_range(0.0, 60.0, 0.05) var source_angle: float = 6.0
## Shadow marches per fragment across the source (STOCHASTIC): more is smoother and
## slower. Clamped by lit/quality/shadow_samples_max.
@export_range(1, 32) var shadow_samples: int = 8
## STOCHASTIC dither inside each stratum. Samples are fractional sub-cone coverages,
## so any setting is smooth (no binary noise); the default is just enough dither to
## erase the faint per-stratum wedges a very wide/near source can show. 0 = fully
## deterministic, 1 = maximum per-pixel dither (fine grain).
@export_range(0.0, 1.0) var shadow_jitter: float = 0.35

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
