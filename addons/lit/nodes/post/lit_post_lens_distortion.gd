@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostLensDistortion

## Radial barrel / pincushion warp, the device lens. Positive bulges (fisheye),
## negative pinches. Distinct from CRT curvature; stack or use either.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_lens_distortion.gdshader")

## + = barrel/bulge (fisheye), - = pincushion/pinch. 0 = flat.
@export_range(-2.0, 2.0, 0.01, "or_greater", "or_less") var amount: float = 0.2:
	set(value):
		amount = value
		apply_params()
## Scale around center. >1 pushes the warped edges off screen to hide the bezel.
@export_range(0.5, 2.0, 0.01, "or_greater") var zoom: float = 1.0:
	set(value):
		zoom = value
		apply_params()
## Bezel color shown where the warp pulls the image off screen.
@export var edge_color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		edge_color = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 130


func _param_map() -> Dictionary:
	return {"amount": "amount", "zoom": "zoom", "edge_color": "edge_color"}
