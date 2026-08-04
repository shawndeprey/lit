@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostOutline

## Sobel edge detection on luma, inked as a cel/comic outline. Computed before the
## tube/tape passes so edges stay crisp.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_outline.gdshader")

## Outline ink color (alpha scales opacity alongside Strength).
@export var color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		color = value
		apply_params()
## Sobel tap spacing in pixels. Larger = thicker, coarser outlines.
@export_range(0.5, 8.0, 0.1, "or_greater") var thickness: float = 1.0:
	set(value):
		thickness = value
		apply_params()
## Edge magnitude needed before any ink shows. Higher = only strong edges.
@export_range(0.0, 1.0, 0.01) var threshold: float = 0.1:
	set(value):
		threshold = value
		apply_params()
## Anti-alias knee above the threshold (0 = hard line, higher = softer).
@export_range(0.0, 1.0, 0.01) var softness: float = 0.1:
	set(value):
		softness = value
		apply_params()
## Outline opacity.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(value):
		strength = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 90


func _param_map() -> Dictionary:
	return {"outline_color": "color", "thickness": "thickness",
		"threshold": "threshold", "softness": "softness", "strength": "strength"}
