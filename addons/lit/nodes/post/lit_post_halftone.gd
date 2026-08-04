@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostHalftone

## Dot-screen the image (comic / newsprint): a rotated grid of ink dots sized by local
## brightness. Runs after Edge Outline, so ink lines survive as solid dots while fills
## break into dots.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_halftone.gdshader")

## Grid cell / max dot footprint, in screen pixels. Larger = coarser dots.
@export_range(2.0, 32.0, 0.5, "or_greater") var dot_size: float = 6.0:
	set(value):
		dot_size = value
		apply_params()
## Screen rotation, in degrees (classic single-screen halftone is often 15 to 45).
@export_range(0.0, 360.0, 1.0) var angle: float = 0.0:
	set(value):
		angle = value
		apply_params()
## Blend between the original and the dot screen (1 = full halftone).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(value):
		amount = value
		apply_params()
## Dot (ink) color.
@export var ink_color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		ink_color = value
		apply_params()
## Background (paper) color.
@export var paper_color: Color = Color(1.0, 1.0, 1.0, 1.0):
	set(value):
		paper_color = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 100


func _param_map() -> Dictionary:
	return {"dot_size": "dot_size", "angle": "angle", "amount": "amount",
		"ink_color": "ink_color", "paper_color": "paper_color"}
