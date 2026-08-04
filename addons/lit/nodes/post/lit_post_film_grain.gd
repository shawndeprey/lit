@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostFilmGrain

## Animated film-grain noise over the final image. Cheap, pairs with everything.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_grain.gdshader")

## Grain amount.
@export_range(0.0, 0.5, 0.001, "or_greater") var intensity: float = 0.05:
	set(value):
		intensity = value
		apply_params()
## Grain cell size in pixels. 1 = per-pixel; larger = chunkier, coarser grain.
@export_range(1.0, 8.0, 0.1, "or_greater") var size: float = 1.0:
	set(value):
		size = value
		apply_params()
## How much grain fades toward black/white (0 = uniform, 1 = midtones only).
@export_range(0.0, 1.0, 0.01) var luminance_response: float = 0.5:
	set(value):
		luminance_response = value
		apply_params()
## Monochrome film grain (off) vs. per-channel RGB sparkle (on).
@export var colored: bool = false:
	set(value):
		colored = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 180


func _param_map() -> Dictionary:
	return {"intensity": "intensity", "grain_size": "size",
		"luminance_response": "luminance_response", "colored": "colored"}
