@tool
@icon("res://addons/lit/icons/lit_sprite_2d.svg")
extends Sprite2D
class_name LitSprite2D

## A Sprite2D that ships pre-wired with the lit_receiver ShaderMaterial and a
## CanvasTexture, so its diffuse/normal/specular slots show up in the inspector right
## away and it's lit by Lit with no manual setup. This is the from-scratch path; the
## "Make Selected Nodes Lit" editor tool is the batch path for existing art. It is just
## a shortcut, equivalent to assigning the receiver material to a plain Sprite2D by hand.
##
## Exposes the receiver shader's per-instance parameters (emissive_strength,
## receiver_mask) as @exports that proxy to this node's own ShaderMaterial, so every
## LitSprite2D can be tuned and masked independently.

const RECEIVER_SHADER := preload("res://addons/lit/shaders/lit_receiver.gdshader")

## Emissive strength: these pixels ignore the dark. Proxies to the material's
## `emissive_strength` uniform.
@export var emissive_strength: float = 0.0:
	set(value):
		emissive_strength = value
		_set_param("emissive_strength", value)

## Which lights affect this receiver: a light contributes only if its light_mask shares
## a bit with this mask. Proxies to `receiver_mask`.
@export_flags_2d_render var receiver_mask: int = 1:
	set(value):
		receiver_mask = value
		_set_param("receiver_mask", value)


func _init() -> void:
	# Pre-wire on creation without clobbering anything a saved scene or a user already
	# assigned. The scene deserializer sets these after _init, overriding the defaults
	# below, which is what we want.
	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = RECEIVER_SHADER
		material = mat
	if texture == null:
		texture = CanvasTexture.new()
	# Push the initial proxy values onto the freshly-made material.
	_set_param("emissive_strength", emissive_strength)
	_set_param("receiver_mask", receiver_mask)


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)
