@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostDither

## Ordered Bayer dithering into a few levels (PICO-8 / 1-bit / Game-Boy look). Runs
## after the edge/print passes since it adds high-frequency detail.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_dither.gdshader")

## Quantization steps per channel. 2 = 1-bit per channel; higher = subtler.
@export_range(2.0, 16.0, 1.0, "or_greater") var levels: float = 4.0:
	set(value):
		levels = value
		apply_params()
## Bayer cell size in screen pixels. Larger = chunkier dither.
@export_range(1.0, 8.0, 1.0, "or_greater") var pattern_scale: float = 1.0:
	set(value):
		pattern_scale = value
		apply_params()
## Collapse to luma first: true 1-bit black and white when levels = 2.
@export var monochrome: bool = false:
	set(value):
		monochrome = value
		apply_params()
## Blend between the original and the dithered result.
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(value):
		strength = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 110


func _param_map() -> Dictionary:
	return {"levels": "levels", "scale": "pattern_scale",
		"monochrome": "monochrome", "strength": "strength"}
