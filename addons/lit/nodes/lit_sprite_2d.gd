@tool
@icon("res://addons/lit/icons/lit_sprite_2d.svg")
extends Sprite2D
class_name LitSprite2D

const RECEIVER_SHADER := preload("res://addons/lit/shaders/lit_receiver.gdshader")

@export var emissive_strength: float = 0.0:
	set(value):
		emissive_strength = value
		_set_param("emissive_strength", value)

@export_flags_2d_render var receiver_mask: int = 1:
	set(value):
		receiver_mask = value
		_set_param("receiver_mask", value)

func _init() -> void:

	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = RECEIVER_SHADER
		material = mat
	if texture == null:
		texture = CanvasTexture.new()

	_set_param("emissive_strength", emissive_strength)
	_set_param("receiver_mask", receiver_mask)

func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)
