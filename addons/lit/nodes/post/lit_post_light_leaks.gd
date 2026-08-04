@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostLightLeaks

## Soft animated colored glows bleeding from the edges (film light-leak look).
## Procedural by default; assign a Texture to drive it from your own scrolling
## gradient instead. Screen-blended over the image.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_light_leaks.gdshader")

## Overall leak strength.
@export_range(0.0, 2.0, 0.01, "or_greater") var intensity: float = 0.6:
	set(value):
		intensity = value
		apply_params()
## Animation drift / pulse speed (0 = frozen).
@export_range(0.0, 4.0, 0.01, "or_greater") var speed: float = 1.0:
	set(value):
		speed = value
		apply_params()
## First (warm) leak color. Ignored when a Texture is assigned.
@export var color1: Color = Color(1.0, 0.5, 0.2, 1.0):
	set(value):
		color1 = value
		apply_params()
## Second (red) leak color. Ignored when a Texture is assigned.
@export var color2: Color = Color(1.0, 0.2, 0.3, 1.0):
	set(value):
		color2 = value
		apply_params()
## Optional override: a scrolling gradient texture replaces the procedural leaks.
## Import with Filter on, Repeat enabled.
@export var texture: Texture2D:
	set(value):
		texture = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 170


func _param_map() -> Dictionary:
	return {"intensity": "intensity", "speed": "speed",
		"color1": "color1", "color2": "color2", "leak_texture": "texture"}


func _apply_extra_params(mat_out: ShaderMaterial) -> void:
	mat_out.set_shader_parameter("has_texture", texture != null)
