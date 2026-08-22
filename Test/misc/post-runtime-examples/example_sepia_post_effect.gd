@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name ExampleSepiaPostEffect

## Screen-wide sepia: the custom-effect route for shaders that apply to the whole lit frame.

const SHADER := preload("res://Test/misc/post-runtime-examples/example_sepia.gdshader")

@export_range(0.0, 1.0, 0.01) var strength: float = 0.7:
	set(value):
		strength = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _param_map() -> Dictionary:
	return {"strength": "strength"}
