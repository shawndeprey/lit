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

# Loaded lazily in _init rather than via a top-level `const preload`. Because this script
# has a `class_name`, the editor parses it at startup to build the global class list, and a
# `preload` const would compile the receiver shader right then, before the plugin's
# _enter_tree has registered the lit_* global uniforms. On a fresh install that produces a
# benign "Global uniform does not exist" error. Deferring to _init means the shader isn't
# compiled until a LitSprite2D is actually instantiated, by which point the globals exist.
const RECEIVER_SHADER_PATH := "res://addons/lit/shaders/lit_receiver.gdshader"

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

## Self-shadowing: when off (the default), occluders inside this sprite's own rect can't
## cast onto it — its shadow renders behind it. Occluders outside the rect still shadow
## it normally. Proxies to `self_shadow`.
@export var self_shadow: bool = false:
	set(value):
		self_shadow = value
		_set_param("self_shadow", value)


# The CanvasTexture currently watched for specular-slot changes, so we can re-evaluate
# has_specular_map live when the user assigns or clears a specular map in the inspector.
var _watched_texture: CanvasTexture = null


func _init() -> void:
	# Pre-wire on creation without clobbering anything a saved scene or a user already
	# assigned. The scene deserializer sets these after _init, overriding the defaults
	# below, which is what we want.
	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = load(RECEIVER_SHADER_PATH)
		material = mat
	if texture == null:
		texture = CanvasTexture.new()
	# Push the initial proxy values onto the freshly-made material.
	_set_param("emissive_strength", emissive_strength)
	_set_param("receiver_mask", receiver_mask)
	_set_param("self_shadow", self_shadow)


func _ready() -> void:
	# Keep has_specular_map in sync so the Blinn-Phong path picks the half-vector specular
	# only when a specular map is actually present (it blows out without one). texture_changed
	# fires on texture swaps; we also subscribe to the CanvasTexture itself so assigning the
	# specular map in the inspector updates live. Connect first, then evaluate once for the
	# texture the scene deserializer already set.
	if not texture_changed.is_connected(_on_texture_changed):
		texture_changed.connect(_on_texture_changed)
	_on_texture_changed()

	# Keep the shader's self-shadow rect synced (item_rect_changed covers texture,
	# centered, offset, region, and frames).
	if not item_rect_changed.is_connected(_update_self_rect):
		item_rect_changed.connect(_update_self_rect)
	_update_self_rect()


# Re-point the specular-slot subscription at the current CanvasTexture, then refresh the flag.
func _on_texture_changed() -> void:
	if _watched_texture != null and is_instance_valid(_watched_texture):
		if _watched_texture.changed.is_connected(_update_specular_flag):
			_watched_texture.changed.disconnect(_update_specular_flag)
	_watched_texture = texture as CanvasTexture
	if _watched_texture != null and not _watched_texture.changed.is_connected(_update_specular_flag):
		_watched_texture.changed.connect(_update_specular_flag)
	_update_specular_flag()


func _update_specular_flag() -> void:
	var present := _watched_texture != null and _watched_texture.specular_texture != null
	_set_param("has_specular_map", present)


# Push the local rect as min.xy | max.xy; the shader treats an empty rect as off.
func _update_self_rect() -> void:
	var r := get_rect()
	_set_param("self_rect", Vector4(r.position.x, r.position.y, r.end.x, r.end.y))


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)
