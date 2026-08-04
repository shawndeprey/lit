@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostVhs

## Worn-tape look: per-line wobble, chroma shift and smear, a rolling tracking-noise
## band, grain, and a slow brightness roll. Animated. Runs before CRT in the chain
## (tape signal, then glass), so enable both for "old tape on an old tube".

const SHADER := preload("res://addons/lit/shaders/post/lit_post_vhs.gdshader")

## Per-line horizontal jitter, in pixels.
@export_range(0.0, 16.0, 0.1, "or_greater") var wobble_strength: float = 2.0:
	set(value):
		wobble_strength = value
		apply_params()
## How fast the jitter reshuffles.
@export_range(0.0, 20.0, 0.1, "or_greater") var wobble_speed: float = 4.0:
	set(value):
		wobble_speed = value
		apply_params()
## R/B horizontal split, in pixels.
@export_range(0.0, 16.0, 0.1, "or_greater") var chroma_shift: float = 2.0:
	set(value):
		chroma_shift = value
		apply_params()
## Horizontal chroma smear (0 = crisp, 1 = full trailing bleed).
@export_range(0.0, 1.0, 0.01) var bleed: float = 0.5:
	set(value):
		bleed = value
		apply_params()
## Animated static-noise overlay.
@export_range(0.0, 1.0, 0.01) var grain: float = 0.12:
	set(value):
		grain = value
		apply_params()
## Severity of the rolling damaged band (0 = none).
@export_range(0.0, 1.0, 0.01) var tracking_strength: float = 0.6:
	set(value):
		tracking_strength = value
		apply_params()
## How fast the tracking band rolls up the screen (0 = parked).
@export_range(0.0, 2.0, 0.01, "or_greater") var tracking_speed: float = 0.2:
	set(value):
		tracking_speed = value
		apply_params()
## Strength of the slow vertical brightness roll.
@export_range(0.0, 1.0, 0.01) var roll_strength: float = 0.1:
	set(value):
		roll_strength = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 140


func _param_map() -> Dictionary:
	return {"wobble_strength": "wobble_strength", "wobble_speed": "wobble_speed",
		"chroma_shift": "chroma_shift", "bleed": "bleed", "grain": "grain",
		"tracking_strength": "tracking_strength", "tracking_speed": "tracking_speed",
		"roll_strength": "roll_strength"}
