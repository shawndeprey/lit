@tool
@icon("res://addons/lit/icons/lit_line_light_2d.svg")
extends LitPositionalLight2D
class_name LitLineLight2D

## A line light for the Lit system: a segment of light for lasers, tube lights and
## light sabers.
##
## The segment is centered on the node along its local +X and follows the node's
## transform (rotation, scale and skew). Every distance a point light measures from its
## position this light measures from the nearest point of the segment, so it lights a
## capsule around the segment and past an end cap it behaves as a point light at that
## end; `width` gives the tube a body, lit from overhead across it. Shadows follow:
## Raymarched casts one hard march from that nearest point, while Cone Traced and
## Stochastic march `shadow_samples` narrow cones spread along the part of the segment
## within `range` of the receiver (Stochastic dithers them), so shadows are soft along
## the tube and sharp across it. The cookie stays centered on the node; FIT_RANGE spans
## the capsule's bounding box. The shared surface lives on LitPositionalLight2D (falloff,
## texture, shadow length and source) and LitLight2D (color, energy, height, the shadow
## gates, blend mode, z/layer ranges and the Light2D-style methods).

@export_group("Line")
## Length of the emitting segment in local pixels, centered on the node along its local
## +X; it stretches with the node's x scale. `range` and `source_radius` follow the
## node's larger scale axis as on a point light, so this is the way to lengthen a tube.
## 0 is a point light. For a laser, raycast to the wall the beam hits and set the length
## to that distance.
@export_range(0.0, 4096.0, 1.0, "or_greater") var length: float = 128.0:
	set(value):
		length = maxf(value, 0.0)
		LitLightRegistry.light_state_changed(self)
## Thickness of the tube in local pixels, scaled like `range`. Under the tube the light
## comes from overhead across this width (a flat, fully lit core) and the falloff runs
## from the tube's surface out to `range`. 0 is an ideal line: a laser; a few pixels
## reads as a light saber, tens as a tube light. Shadows across the tube follow
## `source_radius`.
@export_range(0.0, 1024.0, 0.5, "or_greater") var width: float = 0.0:
	set(value):
		width = maxf(value, 0.0)
		LitLightRegistry.light_state_changed(self)

func _validate_property(property: Dictionary) -> void:
	if property.name == "shadow_samples" and shadow_algorithm == ShadowAlgorithm.CONE_TRACED:
		return
	super(property)
