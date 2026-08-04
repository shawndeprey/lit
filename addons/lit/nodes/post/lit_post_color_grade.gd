@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostColorGrade

## Exposure, contrast, saturation, and tint color grade.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_grade.gdshader")

@export_range(0.0, 4.0, 0.01, "or_greater") var exposure: float = 1.0:
	set(value):
		exposure = value
		apply_params()
@export_range(0.0, 4.0, 0.01, "or_greater") var contrast: float = 1.0:
	set(value):
		contrast = value
		apply_params()
@export_range(0.0, 2.0, 0.01, "or_greater") var saturation: float = 1.0:
	set(value):
		saturation = value
		apply_params()
@export var tint: Color = Color.WHITE:
	set(value):
		tint = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 50


func _param_map() -> Dictionary:
	return {"exposure": "exposure", "contrast": "contrast",
		"saturation": "saturation", "tint": "tint"}
