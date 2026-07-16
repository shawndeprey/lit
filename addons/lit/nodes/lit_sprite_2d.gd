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
#
# Two receiver variants, same feature contract: the fast one has the self-shadow
# exclusion march compiled out (measurably cheaper for every light's shadow march), the
# full one carries it. _update_self_rect swaps to the full shader exactly while the
# exclusion is active (owned occluders present and self_shadow off) and back to the fast
# one otherwise; shader parameters are stored on the material by name, so they survive
# the swap. Materials whose shader isn't one of these two are never touched.
const RECEIVER_SHADER_PATH := "res://addons/lit/shaders/lit_receiver.gdshader"
const RECEIVER_SHADER_FAST_PATH := "res://addons/lit/shaders/lit_receiver_fast.gdshader"

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

## Self-shadowing: when off (the default), this sprite's own occluders can't cast onto
## it — their shadows render behind it. "Own" means LightOccluder2D nodes that are
## descendants of this sprite or its direct siblings. All other occluders still shadow
## this sprite normally. Proxies to `self_shadow`.
@export var self_shadow: bool = false:
	set(value):
		self_shadow = value
		_set_param("self_shadow", value)


# The CanvasTexture currently watched for specular-slot changes, so we can re-evaluate
# has_specular_map live when the user assigns or clears a specular map in the inspector.
var _watched_texture: CanvasTexture = null

# Owned occluders (descendants and direct siblings); rebuilt when children of this
# sprite or of its parent change.
var _self_occluders: Array = []


func _init() -> void:
	# Pre-wire on creation without clobbering anything a saved scene or a user already
	# assigned. The scene deserializer sets these after _init, overriding the defaults
	# below, which is what we want.
	if material == null:
		var mat := ShaderMaterial.new()
		# Fast variant by default: a fresh LitSprite2D has no owned occluders, so the
		# self-exclusion march can't be active; _update_self_rect swaps in the full
		# shader if that changes.
		mat.shader = load(RECEIVER_SHADER_FAST_PATH)
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

	# Rebuild the occluder cache when children of this sprite or its parent change.
	if not child_entered_tree.is_connected(_on_children_changed):
		child_entered_tree.connect(_on_children_changed)
	if not child_exiting_tree.is_connected(_on_children_changed):
		child_exiting_tree.connect(_on_children_changed)
	var parent := get_parent()
	if parent != null:
		if not parent.child_entered_tree.is_connected(_on_children_changed):
			parent.child_entered_tree.connect(_on_children_changed)
		if not parent.child_exiting_tree.is_connected(_on_children_changed):
			parent.child_exiting_tree.connect(_on_children_changed)
	_refresh_occluder_cache()
	_update_self_rect()

	# Refresh the bounds every frame so moving occluders stay claimed.
	set_process(true)


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


func _process(_delta: float) -> void:
	_update_self_rect()


func _on_children_changed(_child: Node) -> void:
	# Deferred: an exiting child is still in the tree during this signal.
	_refresh_occluder_cache.call_deferred()


func _refresh_occluder_cache() -> void:
	_self_occluders.clear()
	for child in find_children("*", "LightOccluder2D", true, false):
		_self_occluders.append(child)
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling is LightOccluder2D:
				_self_occluders.append(sibling)


# Push one local-space box (min.xy | max.xy) per owned occluder. The shader takes up
# to 4 boxes; extras are unioned into the last. Count 0 turns the exclusion off.
func _update_self_rect() -> void:
	if not is_inside_tree():
		return
	var to_local := global_transform.affine_inverse()
	var rects: Array[Rect2] = []
	for node in _self_occluders:
		if not is_instance_valid(node):
			continue
		var occ := node as LightOccluder2D
		if occ == null or not occ.is_inside_tree() \
				or occ.occluder == null or occ.occluder.polygon.is_empty():
			continue
		var xf := to_local * occ.global_transform
		var r := Rect2(xf * occ.occluder.polygon[0], Vector2.ZERO)
		for p in occ.occluder.polygon:
			r = r.expand(xf * p)
		rects.append(r)
	while rects.size() > 4:
		rects[3] = rects[3].merge(rects.pop_back())
	var packed := PackedVector4Array()
	packed.resize(4)
	for i in rects.size():
		packed[i] = Vector4(rects[i].position.x, rects[i].position.y, rects[i].end.x, rects[i].end.y)
	_set_param("self_rects", packed)
	_set_param("self_rect_count", rects.size())

	# Keep the material on the cheapest receiver variant that provides the features in
	# use: the full shader only while the self-exclusion march can actually run.
	_apply_shader_variant(rects.size() > 0 and not self_shadow)


# Swap between the fast and full receiver shaders. Only materials already using one of
# the two Lit variants are touched, so a user-assigned custom shader is left alone.
func _apply_shader_variant(wants_full: bool) -> void:
	var mat := material as ShaderMaterial
	if mat == null or mat.shader == null:
		return
	var current: String = mat.shader.resource_path
	if current != RECEIVER_SHADER_PATH and current != RECEIVER_SHADER_FAST_PATH:
		return
	var wanted := RECEIVER_SHADER_PATH if wants_full else RECEIVER_SHADER_FAST_PATH
	if current != wanted:
		mat.shader = load(wanted)


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)
