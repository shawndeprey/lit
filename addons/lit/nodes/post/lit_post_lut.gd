@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostLut

## Apply a color grade through a lookup table (256x16 LUT strip).

const SHADER := preload("res://addons/lit/shaders/post/lit_post_lut.gdshader")

## Baked-in LUT presets. The PRESET_LUTS entries are parallel to this enum order.
enum LutPreset { NEUTRAL, WARM, COOL, SEPIA, NOIR, TEAL_ORANGE, VINTAGE, VIBRANT }
const PRESET_LUTS := [
	preload("res://addons/lit/luts/lit_lut_neutral.png"),
	preload("res://addons/lit/luts/lit_lut_warm.png"),
	preload("res://addons/lit/luts/lit_lut_cool.png"),
	preload("res://addons/lit/luts/lit_lut_sepia.png"),
	preload("res://addons/lit/luts/lit_lut_noir.png"),
	preload("res://addons/lit/luts/lit_lut_teal_orange.png"),
	preload("res://addons/lit/luts/lit_lut_vintage.png"),
	preload("res://addons/lit/luts/lit_lut_vibrant.png"),
]

## Which baked-in LUT to use. Ignored when a Custom Texture is assigned.
@export var preset: LutPreset = LutPreset.NEUTRAL:
	set(value):
		preset = value
		apply_params()
## Optional custom LUT (256x16 strip). When set, it overrides `preset`. Import with
## Filter on, Mipmaps off, Repeat disabled, Lossless.
@export var custom_texture: Texture2D:
	set(value):
		custom_texture = value
		apply_params()
## Blend between the original and the LUT-graded color (0 = off, 1 = full LUT).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(value):
		amount = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 60


func _param_map() -> Dictionary:
	return {"amount": "amount"}


func _apply_extra_params(mat_out: ShaderMaterial) -> void:
	# The LUT in effect: the custom override if assigned, else the selected preset.
	var lut: Texture2D = custom_texture if custom_texture != null else PRESET_LUTS[preset]
	mat_out.set_shader_parameter("lut", lut)
