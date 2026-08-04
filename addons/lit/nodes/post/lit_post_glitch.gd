@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostGlitch

## Intermittent digital corruption: horizontal tearing, RGB split, datamosh-lite block
## jumps, flicker. Animated. Runs before color grade (corrupt the signal, then grade).

const SHADER := preload("res://addons/lit/shaders/post/lit_post_glitch.gdshader")

## How many slices glitch and how far they tear (0 = clean).
@export_range(0.0, 1.0, 0.01) var intensity: float = 0.5:
	set(value):
		intensity = value
		apply_params()
## Glitch slice height, in pixels. Smaller = finer tearing.
@export_range(1.0, 64.0, 1.0, "or_greater") var block_size: float = 12.0:
	set(value):
		block_size = value
		apply_params()
## RGB channel split, in pixels.
@export_range(0.0, 32.0, 0.5, "or_greater") var rgb_shift: float = 4.0:
	set(value):
		rgb_shift = value
		apply_params()
## Reshuffle rate: how many discrete glitch frames per second.
@export_range(0.0, 30.0, 1.0, "or_greater") var speed: float = 8.0:
	set(value):
		speed = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 40


func _param_map() -> Dictionary:
	return {"intensity": "intensity", "block_size": "block_size",
		"rgb_shift": "rgb_shift", "speed": "speed"}
