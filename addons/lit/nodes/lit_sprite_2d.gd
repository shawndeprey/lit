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
## Exposes the receiver shader's per-instance parameters as @exports that proxy to
## this node's material, so every LitSprite2D can be tuned and masked independently.
## At runtime, receivers with identical material content share one pooled material
## (batching + one uniform set per distinct configuration); proxy edits re-key the
## node to the matching pool entry, and make_material_unique() detaches it for raw
## set_shader_parameter writes.

# load, not preload: class_name parse at editor startup precedes the plugin registering
# the lit_* globals, and a preload would compile the shader before they exist.

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

## Ignore shadows from these occluder layers: a shadow is skipped on this sprite when
## its caster's occluder_light_mask shares a bit with this mask. Empty (the default)
## receives every shadow. Proxies to `rx_mask`.
@export_flags_2d_render var shadow_ignore_mask: int = 0:
	set(value):
		shadow_ignore_mask = value
		# Rx bounds are per-node uniforms: leave the pool before the mask lands.
		if value != 0:
			_ensure_unique_material()
		_set_live_param("rx_mask", value)
		LitLightRegistry.rx_set(self, value)
		# Re-tier once now (a cleared mask must leave the rx variant before this
		# node stops per-frame driving), then re-gate processing.
		_drive_state.dirty = true
		_update_self_rect()
		_update_process_state()

## Self-shadowing: when off (the default), this sprite's own occluders can't cast onto
## it — their shadows render behind it. "Own" means LightOccluder2D nodes that are
## descendants of this sprite or its direct siblings. All other occluders still shadow
## this sprite normally. Proxies to `self_shadow`.
@export var self_shadow: bool = false:
	set(value):
		self_shadow = value
		_set_param("self_shadow", value)
		_drive_state.dirty = true

@export_group("Surface", "")
## Specular highlight intensity. Proxies to `specular_strength`.
@export var specular_strength: float = 0.5:
	set(value):
		specular_strength = value
		_set_param("specular_strength", value)

## Specular exponent (highlight tightness). Proxies to `specular_k`.
@export var specular_k: float = 32.0:
	set(value):
		specular_k = value
		_set_param("specular_k", value)

## Metallic response when no metallic map is set. Proxies to `metallic_value`.
@export_range(0.0, 1.0) var metallic_value: float = 0.0:
	set(value):
		metallic_value = value
		_set_param("metallic_value", value)

## Roughness when no roughness map is set. Proxies to `roughness_value`.
@export_range(0.0, 1.0) var roughness_value: float = 1.0:
	set(value):
		roughness_value = value
		_set_param("roughness_value", value)

@export_group("Shadow March", "")
## Maximum shadow march steps for this receiver. Proxies to `shadow_steps`.
@export var shadow_steps: int = 64:
	set(value):
		shadow_steps = value
		_set_param("shadow_steps", value)

## Minimum shadow march step, in pixels. Proxies to `shadow_min_step`.
@export var shadow_min_step: float = 0.2:
	set(value):
		shadow_min_step = value
		_set_param("shadow_min_step", value)

## Contact-shadow footprint size, in pixels. Proxies to `footprint_shadow`.
@export var footprint_shadow: float = 16.0:
	set(value):
		footprint_shadow = value
		_set_param("footprint_shadow", value)

## Horizontal stretch of directional-light shadows. Proxies to
## `directional_horizontal_scale`.
@export var directional_horizontal_scale: float = 32.0:
	set(value):
		directional_horizontal_scale = value
		_set_param("directional_horizontal_scale", value)
@export_group("")


## How much Lit light reaches this sprite's origin right now: 0.0 = pitch black,
## 1.0 = fully lit (see LitManager.sample_luminance for the full contract). Uses this
## sprite's receiver_mask and shadow_ignore_mask, so it sees exactly the lights and
## shadows the sprite renders with. Runtime only; returns 0.0 in the editor.
func get_luminance() -> float:
	var manager = get_node_or_null(^"/root/LitManager")
	if manager == null:
		return 0.0
	return manager.sample_luminance(global_position, receiver_mask, shadow_ignore_mask,
			null if self_shadow else self)


# The CanvasTexture currently watched for specular-slot changes, so we can re-evaluate
# has_specular_map live when the user assigns or clears a specular map in the inspector.
var _watched_texture: CanvasTexture = null

# Owned occluders (descendants and direct siblings); rebuilt when children of this
# sprite or of its parent change.
var _self_occluders: Array = []

# Dedup memo for the shared driving in LitReceiverHelper.
var _drive_state := LitReceiverHelper.DriveState.new()


func _init() -> void:
	# Pre-wire on creation without clobbering anything a saved scene or a user already
	# assigned. The scene deserializer sets these after _init, overriding the defaults
	# below, which is what we want.
	if material == null:
		var mat := ShaderMaterial.new()
		# Fast by default: a fresh LitSprite2D has no owned occluders.
		mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
		material = mat
		# Seed the proxy values only on a freshly-made material: an existing one may
		# carry hand-set values that the export defaults must not stomp.
		_set_param("emissive_strength", emissive_strength)
		_set_param("receiver_mask", receiver_mask)
		_set_param("self_shadow", self_shadow)
		_set_param("specular_strength", specular_strength)
		_set_param("specular_k", specular_k)
		_set_param("metallic_value", metallic_value)
		_set_param("roughness_value", roughness_value)
		_set_param("shadow_steps", shadow_steps)
		_set_param("shadow_min_step", shadow_min_step)
		_set_param("footprint_shadow", footprint_shadow)
		_set_param("directional_horizontal_scale", directional_horizontal_scale)
	if texture == null:
		texture = CanvasTexture.new()
	# Signal, not _ready: a subclass overriding _ready without super() must not
	# silently disable the node.
	ready.connect(_lit_ready)


func _lit_ready() -> void:
	# Pool by content at runtime: identical receiver configurations share one material
	# (authored resources are never mutated - entries are duplicates). Rx nodes need
	# per-node bounds, so they detach immediately. resource_local_to_scene opts out.
	if not Engine.is_editor_hint():
		var mat := material as ShaderMaterial
		if mat != null and mat.shader != null and not mat.resource_local_to_scene \
				and LitShaderLibrary.flags_of(mat.shader) >= 0:
			material = LitLightRegistry.pool_acquire(mat)
			if shadow_ignore_mask != 0:
				_ensure_unique_material()
	# Heal a stale rx_mask a scene save may have baked into the material.
	if shadow_ignore_mask == 0 and material is ShaderMaterial:
		var stale = (material as ShaderMaterial).get_shader_parameter("rx_mask")
		if stale != null and int(stale) != 0:
			_set_param("rx_mask", 0)

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


# Per-frame driving only while something per-frame can change the drive inputs:
# owned occluders move (bounds must stay claimed) or an rx variant may re-tier.
# Sprites without either have empty rects whatever their transform, and the
# registry's variant walk re-points their material on activity changes.
func _update_process_state() -> void:
	set_process(Engine.is_editor_hint() or not _self_occluders.is_empty()
			or shadow_ignore_mask != 0)


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
	_set_live_param("has_specular_map", present)


func _process(_delta: float) -> void:
	_update_self_rect()


func _on_children_changed(_child: Node) -> void:
	# Deferred: an exiting child is still in the tree during this signal.
	_refresh_occluder_cache.call_deferred()


func _refresh_occluder_cache() -> void:
	# Fresh array: the drive fast path detects cache rebuilds by identity.
	var occluders: Array = []
	for child in find_children("*", "LightOccluder2D", true, false):
		occluders.append(child)
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling is LightOccluder2D:
				occluders.append(sibling)
	_self_occluders = occluders
	if is_inside_tree():
		_update_self_rect()
		_update_process_state()


# Rects, variant tier, and y-sort params all land through the shared helper.
func _update_self_rect() -> void:
	if not is_inside_tree():
		return
	# Owned occluders mean per-node self rects: leave the pool before they land.
	if not _self_occluders.is_empty():
		_ensure_unique_material()
	if LitReceiverHelper.drive(self, _live_mat(), _self_occluders,
			LitReceiverHelper.NO_TILE_RECTS, true, _lit_node_flags(), _drive_state) \
			and shadow_ignore_mask != 0:
		_set_live_param("rx_mask", shadow_ignore_mask)


func _lit_node_flags() -> int:
	return LitShaderLibrary.F_RX if shadow_ignore_mask != 0 else 0


## Detach this node's runtime material from the shared pool and return it, so raw
## set_shader_parameter writes affect only this node. Already-unique materials come
## back unchanged. Runtime only; in the editor the authored material is returned.
func make_material_unique() -> ShaderMaterial:
	_ensure_unique_material()
	return material as ShaderMaterial


func _ensure_unique_material() -> void:
	var mat := material as ShaderMaterial
	if mat != null and LitLightRegistry.pool_is_pooled(mat):
		material = LitLightRegistry.pool_to_unique(mat)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		var mat := material as ShaderMaterial
		if mat != null:
			LitLightRegistry.pool_release(mat)


func _set_param(param: String, value: Variant) -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	# Pooled materials are shared: a per-node value re-keys this node to the pool
	# entry matching its new content instead of bleeding to poolmates.
	if not Engine.is_editor_hint() and LitLightRegistry.pool_is_pooled(mat):
		if mat.get_shader_parameter(param) == value:
			return
		material = LitLightRegistry.pool_rekey(mat, param, value)
		return
	mat.set_shader_parameter(param, value)


# The material carrying live-driven state: in the editor a per-node RenderingServer
# clone (the property material stays authored-only, so saves never bake volatile
# state); at runtime the node's own (pooled or unique) material.
var _live_last: ShaderMaterial = null

func _live_mat() -> ShaderMaterial:
	var mat := material as ShaderMaterial
	if Engine.is_editor_hint() and mat != null and mat.shader != null \
			and LitShaderLibrary.flags_of(mat.shader) >= 0:
		mat = LitLightRegistry.editor_live_material(self, mat)
		if mat != _live_last:
			# Fresh clone (first frame, or recreated after the editor's save-time
			# script reload): re-land the node-owned params (the helper re-lands its
			# own through DriveState).
			_live_last = mat
			mat.set_shader_parameter("rx_mask", shadow_ignore_mask)
			_update_specular_flag()
	return mat


func _set_live_param(param: String, value: Variant) -> void:
	# At runtime the live material is the node's own; route through the pool-aware
	# setter so shared entries re-key instead of mutating.
	if not Engine.is_editor_hint():
		_set_param(param, value)
		return
	var mat := _live_mat()
	if mat != null:
		mat.set_shader_parameter(param, value)
