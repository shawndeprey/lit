@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostAberration

## Radial RGB lens fringe that grows toward the screen edges; center stays sharp.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_aberration.gdshader")

## Max R/B split at the corners, in pixels.
@export_range(0.0, 16.0, 0.1, "or_greater") var amount: float = 3.0:
	set(value):
		amount = value
		apply_params()
## Edge concentration. Higher keeps the center sharper and pushes the fringe outward.
@export_range(0.0, 6.0, 0.1, "or_greater") var edge_falloff: float = 2.0:
	set(value):
		edge_falloff = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 160


func _param_map() -> Dictionary:
	return {"amount": "amount", "edge_falloff": "edge_falloff"}
