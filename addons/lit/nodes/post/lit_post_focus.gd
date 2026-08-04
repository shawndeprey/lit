@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostFocus

## The final focus dial: negative = soft / dream blur, positive = sharpen. Runs last,
## on the completed image.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_focus.gdshader")

## < 0 = soft / dream blur, > 0 = sharpen, 0 = off.
@export_range(-1.0, 1.0, 0.01, "or_greater", "or_less") var amount: float = -0.5:
	set(value):
		amount = value
		apply_params()
## Blur reach (mip level). About 1 for sharpen, 2 to 4 for a wide dream blur.
@export_range(0.0, 6.0, 0.1, "or_greater") var radius: float = 2.0:
	set(value):
		radius = value
		apply_params()
## Soft side only: hazy highlight glow blended back in for the dreamy look.
@export_range(0.0, 1.0, 0.01) var dream: float = 0.2:
	set(value):
		dream = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 200


func _param_map() -> Dictionary:
	return {"amount": "amount", "radius": "radius", "dream": "dream"}
