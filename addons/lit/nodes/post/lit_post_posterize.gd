@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostPosterize

## Quantize colors into a few flat levels (screen-print / comic look). Runs before
## Edge Outline, so the outline inks the flattened color.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_posterize.gdshader")

## Discrete steps per channel. 2 = harsh, higher = subtler banding.
@export_range(2.0, 16.0, 1.0, "or_greater") var levels: float = 4.0:
	set(value):
		levels = value
		apply_params()
## Blend between the original and the posterized color.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(value):
		strength = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 80


func _param_map() -> Dictionary:
	return {"levels": "levels", "strength": "strength"}
