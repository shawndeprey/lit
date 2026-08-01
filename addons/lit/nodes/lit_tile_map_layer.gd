@tool
@icon("res://addons/lit/icons/lit_tile_map_layer.svg")
extends TileMapLayer
class_name LitTileMapLayer

## A TileMapLayer pre-wired with the lit_receiver ShaderMaterial; the LitSprite2D
## counterpart for tilemaps. Own occluders are the tileset occlusion polygons of the
## painted cells plus any LightOccluder2D descendants.


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
		_set_live_param("rx_mask", value)
		LitLightRegistry.rx_set(self, value)

## Self-shadowing: when off (the default), this layer's own occluders can't cast onto
## it — their shadows render behind it.
@export var self_shadow: bool = false:
	set(value):
		self_shadow = value
		_set_param("self_shadow", value)

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
	# Signal, not _ready: a subclass overriding _ready without super() must not
	# silently disable the node.
	ready.connect(_lit_ready)


func _lit_ready() -> void:
	# Instanced scenes share subresource materials, but per-node self rects need one
	# material per node; de-share at runtime.
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
	_self_occluders.clear()
	for child in find_children("*", "LightOccluder2D", true, false):
		_self_occluders.append(child)


# Rects, variant tier, and live params all land through the shared helper; tilemaps
# never participate in y-sort.
func _update_self_rect() -> void:
	if not is_inside_tree():
		return
	if _tile_rect_dirty:
		_tile_rect_dirty = false
		_tile_rects = LitLightRegistry.tile_occluder_rects(self)
	LitReceiverHelper.drive(self, _live_mat(), _self_occluders, _tile_rects, false,
			_lit_node_flags(), _drive_state)
	if shadow_ignore_mask != 0:
		_set_live_param("rx_mask", shadow_ignore_mask)


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
			# script reload): re-land the node-owned params (the helper re-lands its
			# own through DriveState).
			_live_last = mat
			mat.set_shader_parameter("rx_mask", shadow_ignore_mask)
	return mat


func _set_live_param(param: String, value: Variant) -> void:
	var mat := _live_mat()
	if mat != null:
		mat.set_shader_parameter(param, value)
