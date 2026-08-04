@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostVignette

## Darkened screen edges.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_vignette.gdshader")

## How dark the edges get (0 = none, 1 = corners crushed to black).
@export_range(0.0, 1.0, 0.01) var strength: float = 0.4:
	set(value):
		strength = value
		apply_params()
## Feather width of the vignette ramp (0 = tight to the corners, 1 = from center).
@export_range(0.0, 1.0, 0.01) var softness: float = 0.5:
	set(value):
		softness = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 190


func _param_map() -> Dictionary:
	return {"strength": "strength", "softness": "softness"}
