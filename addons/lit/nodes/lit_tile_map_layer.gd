@tool
@icon("res://addons/lit/icons/lit_tile_map_layer.svg")
extends TileMapLayer
class_name LitTileMapLayer

## A TileMapLayer pre-wired with the lit_receiver ShaderMaterial; the LitSprite2D
## counterpart for tilemaps. Own occluders are the tileset occlusion polygons of the
## painted cells plus any LightOccluder2D descendants.

# Plugin version this node's saved data was authored under; see LitVersionStamp.
@export_storage var lit_version := ""

@export var emissive_strength: float = 0.0:
	set(value):
		emissive_strength = value
		_set_param("emissive_strength", value)

@export_flags_2d_render var receiver_mask: int = 1:
	set(value):
		receiver_mask = value
		_set_param("receiver_mask", value)

## Ignore shadows from these occluder layers: a shadow is skipped on this layer when
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

## Self-shadowing: when off (the default), this layer's own occluders can't cast onto
## it - their shadows render behind it.
@export var self_shadow: bool = false:
	set(value):
		self_shadow = value
		_set_param("self_shadow", value)
		_drive_state.dirty = true

@export_group("Surface", "")
## Specular highlight intensity (Blinn-Phong lighting model only; ignored under PBR,
## where the inspector greys it out). Proxies to `specular_strength`.
@export var specular_strength: float = 0.5:
	set(value):
		specular_strength = value
		_set_param("specular_strength", value)

## Specular exponent: scales the CanvasTexture's shininess into how tight the
## highlight is (Blinn-Phong only). Proxies to `specular_k`.
@export var specular_k: float = 32.0:
	set(value):
		specular_k = value
		_set_param("specular_k", value)

## Metallic response (PBR lighting model only; ignored under Blinn-Phong). Multiplies
## the material's metallic map when one is set, and stands alone when not. Proxies to
## `metallic_value`.
@export_range(0.0, 1.0) var metallic_value: float = 0.0:
	set(value):
		metallic_value = value
		_set_param("metallic_value", value)

## Roughness (PBR lighting model only; ignored under Blinn-Phong). Multiplies the
## material's roughness map when one is set, and stands alone when not; 1 is fully
## matte. Proxies to `roughness_value`.
@export_range(0.0, 1.0) var roughness_value: float = 1.0:
	set(value):
		roughness_value = value
		_set_param("roughness_value", value)

@export_group("Shadow March", "")
## Cap on shadow march steps per light on this receiver. A march stops as soon as it
## hits an occluder or reaches its end, usually well under this cap, so raising it
## rarely changes anything; lowering it trades reach on long marches (directional
## lights, large ranges) for speed. Ignored while Project Settings > Lit > Quality >
## Shadow Step Scaling is on, which scales the budget per light instead. Proxies to
## `shadow_steps`.
@export var shadow_steps: int = 64:
	set(value):
		shadow_steps = value
		_set_param("shadow_steps", value)

## Minimum advance per shadow march step, in SDF units (the world SDF's texel space,
## not canvas pixels). Larger is faster and coarser. Proxies to `shadow_min_step`.
@export var shadow_min_step: float = 0.2:
	set(value):
		shadow_min_step = value
		_set_param("shadow_min_step", value)

## How strongly an occluder's own shadow darkens the receiver pixels inside that
## occluder's shape (the contact shadow at its footprint): block = footprint_shadow x
## depth crossed / light distance, clamped to 1. Dimensionless, so zoom doesn't change
## the look; higher darkens footprints sooner. Proxies to `footprint_shadow`.
@export var footprint_shadow: float = 16.0:
	set(value):
		footprint_shadow = value
		_set_param("footprint_shadow", value)

## Directional lights only: horizontal reach of the shading vector relative to the
## light's `height`, so its elevation is atan(height / scale); larger is more grazing.
## Shading only - shadow direction is unaffected. Proxies to
## `directional_horizontal_scale`.
@export var directional_horizontal_scale: float = 32.0:
	set(value):
		directional_horizontal_scale = value
		_set_param("directional_horizontal_scale", value)
@export_group("")

var _self_occluders: Array = []
var _tile_rects: Array[Rect2] = []
var _tile_rect_dirty := true

# Dedup memo for the shared driving in LitReceiverHelper.
var _drive_state := LitReceiverHelper.DriveState.new()


func _init() -> void:
	# Seed params only on a freshly created material: an existing one may carry
	# hand-set values that the export defaults must not stomp.
	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
		material = mat
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
	# Signal, not _ready: a subclass overriding _ready without super() must not
	# silently disable the node.
	ready.connect(_lit_ready)


func _enter_tree() -> void:
	LitVersionStamp.stamp(self)


func _lit_ready() -> void:
	# Pool by content at runtime: identical receiver configurations share one material
	# (authored resources are never mutated - entries are duplicates). Rx layers need
	# per-node bounds, so they detach immediately; layers with occlusion tiles detach
	# in _update_self_rect once their tile rects are known. resource_local_to_scene
	# opts out.
	if not Engine.is_editor_hint():
		var mat := material as ShaderMaterial
		if mat != null and mat.shader != null and not mat.resource_local_to_scene \
				and LitShaderLibrary.flags_of(mat.shader) >= 0:
			# Already held only when a pre-ready proxy write (a duplicate() of a live
			# node copies properties through the setters) acquired it for us.
			if not is_same(mat, _pool_held):
				material = LitLightRegistry.pool_acquire(mat)
				_pool_held = material
			if shadow_ignore_mask != 0:
				_ensure_unique_material()
	# Heal a stale rx_mask a scene save may have baked into the material.
	if shadow_ignore_mask == 0 and material is ShaderMaterial:
		var stale = (material as ShaderMaterial).get_shader_parameter("rx_mask")
		if stale != null and int(stale) != 0:
			_set_param("rx_mask", 0)
	if not changed.is_connected(_on_map_changed):
		changed.connect(_on_map_changed)
	if not child_entered_tree.is_connected(_on_children_changed):
		child_entered_tree.connect(_on_children_changed)
	if not child_exiting_tree.is_connected(_on_children_changed):
		child_exiting_tree.connect(_on_children_changed)
	_refresh_occluder_cache()
	_update_self_rect()
	set_process(true)


func _process(_delta: float) -> void:
	_update_self_rect()


func _on_map_changed() -> void:
	_tile_rect_dirty = true


# The changed signal doesn't fire for cell edits (set_cell / editor painting); this
# virtual does.
func _update_cells(_coords: Array[Vector2i], _forced_cleanup: bool) -> void:
	_tile_rect_dirty = true


func _on_children_changed(_child: Node) -> void:
	_refresh_occluder_cache.call_deferred()


func _refresh_occluder_cache() -> void:
	# Fresh array: the drive fast path detects cache rebuilds by identity.
	var occluders: Array = []
	for child in find_children("*", "LightOccluder2D", true, false):
		occluders.append(child)
	_self_occluders = occluders


# Rects, variant tier, and live params all land through the shared helper; tilemaps
# never participate in y-sort.
func _update_self_rect() -> void:
	if not is_inside_tree():
		return
	if _tile_rect_dirty:
		_tile_rect_dirty = false
		_tile_rects = LitLightRegistry.tile_occluder_rects(self)
	# Occlusion tiles or owned occluders mean per-node self rects: leave the pool
	# before they land.
	if not _tile_rects.is_empty() or not _self_occluders.is_empty():
		_ensure_unique_material()
	if LitReceiverHelper.drive(self, _live_mat(), _self_occluders, _tile_rects, false,
			_lit_node_flags(), _drive_state) and shadow_ignore_mask != 0:
		_set_live_param("rx_mask", shadow_ignore_mask)


func _lit_node_flags() -> int:
	return LitShaderLibrary.F_RX if shadow_ignore_mask != 0 else 0


## Detach this layer's runtime material from the shared pool and return it, so raw
## set_shader_parameter writes affect only this layer. Already-unique materials come
## back unchanged. Runtime only; in the editor the authored material is returned.
func make_material_unique() -> ShaderMaterial:
	_ensure_unique_material()
	return material as ShaderMaterial


# The pool entry this node holds a reference to (null while private, authored, or in
# the editor). Tracked apart from `material` so a runtime material swap by the user
# releases the stale reference instead of stranding the entry.
var _pool_held: ShaderMaterial = null


func _sync_pool_hold() -> void:
	if _pool_held != null and not is_same(material, _pool_held):
		LitLightRegistry.pool_release(_pool_held)
		_pool_held = null


func _ensure_unique_material() -> void:
	_sync_pool_hold()
	var mat := material as ShaderMaterial
	if mat == null or not LitLightRegistry.pool_is_pooled(mat):
		return
	# Our own hold moves out through the pool; a pooled material assigned by hand
	# (another node's entry) is copied without touching that node's reference.
	material = LitLightRegistry.pool_to_unique(mat) if is_same(mat, _pool_held) else mat.duplicate()
	_pool_held = null


func _validate_property(property: Dictionary) -> void:
	LitReceiverHelper.validate_receiver_property(property)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _pool_held != null:
		# Release the reference this node took, whatever `material` holds by now (a
		# runtime material swap must not strand the entry).
		LitLightRegistry.pool_release(_pool_held)
		_pool_held = null


func _set_param(param: String, value: Variant) -> void:
	_sync_pool_hold()
	var mat := material as ShaderMaterial
	if mat == null:
		return
	# Pooled materials are shared: a per-node value re-keys this node to the pool
	# entry matching its new content instead of bleeding to poolmates.
	if not Engine.is_editor_hint() and LitLightRegistry.pool_is_pooled(mat):
		if mat.get_shader_parameter(param) == value:
			return
		if not LitLightRegistry.pool_is_key_param(param):
			# Driven params (rx_mask heals) converge on a shared entry, which holds
			# them empty by construction: no re-key, no reference change.
			mat.set_shader_parameter(param, value)
			return
		if not is_same(mat, _pool_held):
			# A pooled material assigned by hand (another node's entry): take a
			# reference of our own before moving off it, so its holders stay honest.
			mat = LitLightRegistry.pool_acquire(mat)
		material = LitLightRegistry.pool_rekey(mat, param, value)
		_pool_held = material
		return
	mat.set_shader_parameter(param, value)


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
			# script reload): re-land the node-owned params (the helper re-lands its
			# own through DriveState).
			_live_last = mat
			mat.set_shader_parameter("rx_mask", shadow_ignore_mask)
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
