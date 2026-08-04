@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostBloom

## Soft glow spreading from bright pixels.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_bloom.gdshader")

## Luma above this blooms. The screen is LDR, so the useful range is about 0.4 to 0.8.
@export_range(0.0, 1.0, 0.01) var threshold: float = 0.7:
	set(value):
		threshold = value
		apply_params()
## Glow strength added on top of the frame. Crank past 1 for heavy fantasy bloom.
@export_range(0.0, 4.0, 0.01, "or_greater") var intensity: float = 0.5:
	set(value):
		intensity = value
		apply_params()
## Glow width: spreads the sampled mip levels. Larger is wider and softer.
@export_range(0.0, 8.0, 0.01, "or_greater") var radius: float = 4.0:
	set(value):
		radius = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 20


func _param_map() -> Dictionary:
	return {"threshold": "threshold", "intensity": "intensity", "bloom_radius": "radius"}
