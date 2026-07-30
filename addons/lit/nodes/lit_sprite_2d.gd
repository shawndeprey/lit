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
		_set_live_param("rx_mask", value)
		LitLightRegistry.rx_set(self, value)

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

# Last-pushed y-sort params, so the sync only touches the material on change.
var _ysort_on_last := false
var _ysort_y_last := 0.0


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
	if texture == null:
		texture = CanvasTexture.new()
	# Signal, not _ready: a subclass overriding _ready without super() must not
	# silently disable the node.
	ready.connect(_lit_ready)


func _lit_ready() -> void:
	# Instanced scenes share subresource materials, but per-node params (self rects,
	# rx_mask) need one material per node; de-share at runtime.
	if not Engine.is_editor_hint():
		var mat := material as ShaderMaterial
		if mat != null and mat.shader != null and not mat.resource_local_to_scene \
				and LitShaderLibrary.flags_of(mat.shader) >= 0:
			material = mat.duplicate()
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
	_set_live_param("has_specular_map", present)


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


# Push one canvas-space box (min.xy | max.xy) per owned occluder. The shader takes up
# to 4 boxes; extras are unioned into the last. Count 0 turns the exclusion off.
func _update_self_rect() -> void:
	if not is_inside_tree():
		return
	var rects: Array[Rect2] = []
	for node in _self_occluders:
		if not is_instance_valid(node):
			continue
		var occ := node as LightOccluder2D
		if occ == null or not occ.is_inside_tree() \
				or occ.occluder == null or occ.occluder.polygon.is_empty():
			continue
		var xf := occ.global_transform
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
	_set_live_param("self_rects", packed)
	_set_live_param("self_rect_count", rects.size())

	# Y-sort participation: occluder-owning sprites only, depth = footprint bottom.
	var ys_on := false
	var ys_y := 0.0
	if LitLightRegistry.ysort_enabled and not rects.is_empty():
		ys_on = true
		ys_y = rects[0].end.y
		for r in rects:
			ys_y = maxf(ys_y, r.end.y)

	# Full shader only while the self-exclusion march can actually run, the y-sort
	# variant only while participating. The material param decides, so the flag also
	# works when set directly on the material.
	var flag: Variant = null
	if material is ShaderMaterial:
		flag = (material as ShaderMaterial).get_shader_parameter("self_shadow")
	_apply_shader_variant(rects.size() > 0 and flag != true, ys_on)

	# After the swap, so the params land on a shader declaring them.
	if ys_on != _ysort_on_last or (ys_on and ys_y != _ysort_y_last):
		_ysort_on_last = ys_on
		_ysort_y_last = ys_y
		_set_live_param("ysort_on", ys_on)
		_set_live_param("ysort_y", ys_y)
	if shadow_ignore_mask != 0:
		_set_live_param("rx_mask", shadow_ignore_mask)


# Only materials already on a Lit variant are touched; a custom shader is left alone.
func _apply_shader_variant(wants_full: bool, wants_ysort: bool) -> void:
	var mat := _live_mat()
	if mat == null or mat.shader == null:
		return
	var flags: int = LitShaderLibrary.flags_of(mat.shader)
	if flags < 0:
		return
	assert(LitLightRegistry.activity_flags == LitLightRegistry._activity_mirror())
	var tier := (LitShaderLibrary.F_SELF_EXCL | LitShaderLibrary.F_YSORT) if wants_ysort \
			else (LitShaderLibrary.F_SELF_EXCL if wants_full else 0)
	var wanted := LitShaderLibrary.resolve(tier, _lit_node_flags(), LitLightRegistry.activity_flags)
	if flags != wanted:
		mat.shader = LitShaderLibrary.get_receiver(wanted)


func _lit_node_flags() -> int:
	return LitShaderLibrary.F_RX if shadow_ignore_mask != 0 else 0


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)


# The material carrying live-driven state: in the editor a per-node RenderingServer
# clone (the property material stays authored-only, so saves never bake volatile
# state); at runtime the node's own (de-shared) material.
var _live_last: ShaderMaterial = null

func _live_mat() -> ShaderMaterial:
	var mat := material as ShaderMaterial
	if Engine.is_editor_hint() and mat != null and mat.shader != null \
			and LitShaderLibrary.flags_of(mat.shader) >= 0:
		mat = LitLightRegistry.editor_live_material(self, mat)
		if mat != _live_last:
			# Fresh clone (first frame, or recreated after the editor's save-time
			# script reload): drop the dedup caches so live params re-land on it.
			_live_last = mat
			_ysort_on_last = false
			_ysort_y_last = 0.0
			mat.set_shader_parameter("rx_mask", shadow_ignore_mask)
			_update_specular_flag()
	return mat


func _set_live_param(param: String, value: Variant) -> void:
	var mat := _live_mat()
	if mat != null:
		mat.set_shader_parameter(param, value)
