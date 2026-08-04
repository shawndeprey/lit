@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostHalation

## Warm red-leaning halo around highlights (film companion to bloom). Applied with
## bloom, before color grading.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_halation.gdshader")

## Luma above this halates. The screen is LDR, so the useful range is about 0.4 to 0.8.
@export_range(0.0, 1.0, 0.01) var threshold: float = 0.6:
	set(value):
		threshold = value
		apply_params()
## Halo strength added on top of the frame.
@export_range(0.0, 4.0, 0.01, "or_greater") var intensity: float = 0.6:
	set(value):
		intensity = value
		apply_params()
## Halo width: spreads the sampled mip levels. Larger is wider and softer.
@export_range(0.0, 8.0, 0.01, "or_greater") var radius: float = 5.0:
	set(value):
		radius = value
		apply_params()
## Halo color. Warm red-orange by default, the classic film halation hue.
@export var tint: Color = Color(1.0, 0.25, 0.1, 1.0):
	set(value):
		tint = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 30


func _param_map() -> Dictionary:
	return {"threshold": "threshold", "intensity": "intensity",
		"halation_radius": "radius", "tint": "tint"}
