@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostLetterbox

## Cinematic bars top and bottom, the matte on the finished content. Animate `size`
## from 0 to ease them in and out for cutscenes. Sits at the content/display boundary,
## so the display passes after it (VHS, CRT, etc.) render over the bars: the tube
## curves them, scanlines and grain cross them.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_letterbox.gdshader")

## Fraction of screen height covered by EACH bar (0 = none, 0.5 = bars meet center).
@export_range(0.0, 0.5, 0.001) var size: float = 0.12:
	set(value):
		size = value
		apply_params()
## Feathered inner edge of the bars (0 = hard edge).
@export_range(0.0, 0.2, 0.001) var softness: float = 0.0:
	set(value):
		softness = value
		apply_params()
## Bar color. Black by default; alpha makes the bars translucent.
@export var color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		color = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 120


func _param_map() -> Dictionary:
	return {"bar_size": "size", "softness": "softness", "bar_color": "color"}
