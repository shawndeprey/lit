@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostPixelate

## Snap the image to a coarse grid for a chunky low-res / mosaic look. Runs before the
## other stylize and display passes, so they all read the blocky image.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_pixelate.gdshader")

## Block edge in screen pixels. 1 = off, larger = chunkier blocks.
@export_range(1.0, 64.0, 1.0, "or_greater") var pixel_size: float = 4.0:
	set(value):
		pixel_size = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 70


func _param_map() -> Dictionary:
	return {"pixel_size": "pixel_size"}
