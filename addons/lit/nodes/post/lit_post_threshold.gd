@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostThreshold

## Luma threshold: darkness below a cutoff fades to black.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_threshold.gdshader")

## Luma below this fades to black (with a short soft knee); brighter pixels pass.
@export_range(0.0, 1.0, 0.01) var cutoff: float = 0.5:
	set(value):
		cutoff = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 10


func _param_map() -> Dictionary:
	return {"cutoff": "cutoff"}
