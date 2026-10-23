@tool
@icon("res://addons/lit/icons/lit_directional_light_2d.svg")
extends LitLight2D
class_name LitDirectionalLight2D

## A directional light for the Lit system.
##
## Like LitPointLight2D but with no positional attenuation: the node's rotation defines
## the direction the light travels (its local +X: at rotation 0 the light comes from the
## left), so every receiver is lit from the same angle. `height` still tilts the shading
## vector out of the plane; lower is more grazing, higher more head-on. There is no
## `range`, `falloff` or cookie, and directional lights are never positionally culled.[br][br]
##
## Shares the receiver and shadow code path with point lights via the type flag in the
## light-data texture. The shared surface (color, energy, height, the shadow gates,
## blend mode, z/layer ranges and the Light2D-style methods) lives on LitLight2D.

@export_group("Shadow")
## Length of cast shadows as a fraction of `shadow_reach`: every occluder's shadow
## closes exactly at that distance through a natural penumbral tip, so a low sun reads
## as long evening shadows and a high sun as short noon ones (0 = none at all). Animate
## it alongside the node's rotation for day/night cycles.
@export_range(0.0, 1.0, 0.001) var shadow_length: float = 1.0
## Maximum distance shadows can extend, in world pixels; `shadow_length` scales within
## it. A world length, so shadows stay identical at any camera zoom. The world-SDF
## window grows to cover it, so very large values coarsen shadow-casting resolution.
@export_range(256.0, 16384.0, 1.0, "or_greater") var shadow_reach: float = 4096.0
## Angular size (full diameter) of the source in degrees (CONE_TRACED / STOCHASTIC):
## how wide the light appears in the sky, the same convention as Unreal's Source Angle
## (0.5357), Unity HDRP's Angular Diameter (0.5) and Blender's Sun Angle (0.526) - the
## sun is about 0.53. Larger reads as a big soft sky light with penumbras that grow
## with distance from the occluder; the default is deliberately sun x ~11 so the
## softness is visible at game scale.
@export_range(0.0, 60.0, 0.05) var source_angle: float = 6.0


func _validate_property(property: Dictionary) -> void:
	LitShaderLibrary.validate_light_property(property, shadow_algorithm, "source_angle")


# DirectionalLight2D's method names over `shadow_reach`.
func set_max_distance(value: float) -> void:
	shadow_reach = value


func get_max_distance() -> float:
	return shadow_reach
