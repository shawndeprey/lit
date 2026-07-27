@tool
@icon("res://addons/lit/icons/lit_tile_map_layer.svg")
extends TileMapLayer
class_name LitTileMapLayer

## A TileMapLayer pre-wired with the lit_receiver ShaderMaterial; the LitSprite2D
## counterpart for tilemaps. Own occluders are the tileset occlusion polygons of the
## painted cells plus any LightOccluder2D descendants.

const RECEIVER_SHADER_FAST_PATH := "res://addons/lit/shaders/lit_receiver_fast.gdshader"
const RECEIVER_FAST_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast.gdshader",
]
const RECEIVER_FULL_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch.gdshader",
]
# Gx twins, used while globally excluded occluders exist (LitLightRegistry.gx_active).
const RECEIVER_FAST_GX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast_gx.gdshader",
]
const RECEIVER_FULL_GX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_gx.gdshader",
]
# Mask twins, used while any light carries per-light exclusions (LitLightRegistry.masks_active).
const RECEIVER_FAST_MASK_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast_mask.gdshader",
]
const RECEIVER_FULL_MASK_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_mask.gdshader",
]
# Rx twins, used while this layer's shadow_receiver_mask is non-default.
const RECEIVER_FAST_RX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast_rx.gdshader",
]
const RECEIVER_FULL_RX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_rx.gdshader",
]
const RECEIVER_FAST_MASK_RX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast_mask_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast_mask_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast_mask_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast_mask_rx.gdshader",
]
const RECEIVER_FULL_MASK_RX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_mask_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_mask_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_mask_rx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_mask_rx.gdshader",
]

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
		_set_param("rx_mask", value)
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
var _last_packed := PackedVector4Array()
var _last_count := -1


func _init() -> void:
	# Seed params only on a freshly created material: an existing one may carry
	# hand-set values that the export defaults must not stomp.
	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = load(RECEIVER_SHADER_FAST_PATH)
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
				and LitLightRegistry._is_lit_receiver_path(mat.shader.resource_path):
			material = mat.duplicate()
	# Heal a stale rx_mask a scene save may have baked into the material.
	if shadow_ignore_mask == 0 and material is ShaderMaterial:
		var stale = (material as ShaderMaterial).get_shader_parameter("rx_mask")
		if stale != null and int(stale) != 0 \
				and not (Engine.is_editor_hint() and LitLightRegistry.rx_claims_material(material)):
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


func _update_self_rect() -> void:
	if not is_inside_tree():
		return
	if _tile_rect_dirty:
		_tile_rect_dirty = false
		_tile_rects = LitLightRegistry.tile_occluder_rects(self)
	var rects: Array[Rect2] = []
	for tile_rect in _tile_rects:
		rects.append(global_transform * tile_rect)
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
	if packed != _last_packed or rects.size() != _last_count:
		_last_packed = packed
		_last_count = rects.size()
		_set_param("self_rects", packed)
		_set_param("self_rect_count", rects.size())

	# The material param decides, so the flag also works when set directly on a
	# hand-assigned receiver material; the export is a proxy that writes it.
	var flag: Variant = null
	if material is ShaderMaterial:
		flag = (material as ShaderMaterial).get_shader_parameter("self_shadow")
	_apply_shader_variant(rects.size() > 0 and flag != true)
	# After the swap, so the param lands on a shader declaring it.
	if shadow_ignore_mask != 0:
		_set_param("rx_mask", shadow_ignore_mask)


func _apply_shader_variant(wants_full: bool) -> void:
	var mat := material as ShaderMaterial
	if mat == null or mat.shader == null:
		return
	var current: String = mat.shader.resource_path
	if not LitLightRegistry._is_lit_receiver_path(current):
		return
	var mask := LitLightRegistry.active_algos & 3
	var masks := LitLightRegistry.masks_active
	var gx := LitLightRegistry.gx_active
	# Rx (per-receiver exclusion) has its own variant class carrying the tile test.
	var rx := shadow_ignore_mask != 0
	if not rx and Engine.is_editor_hint():
		rx = LitLightRegistry.rx_claims_material(mat)
	var table: Array[String]
	if wants_full:
		table = (RECEIVER_FULL_MASK_RX_VARIANTS if masks else RECEIVER_FULL_RX_VARIANTS) if rx \
				else (RECEIVER_FULL_MASK_VARIANTS if masks \
				else (RECEIVER_FULL_GX_VARIANTS if gx else RECEIVER_FULL_VARIANTS))
	else:
		table = (RECEIVER_FAST_MASK_RX_VARIANTS if masks else RECEIVER_FAST_RX_VARIANTS) if rx \
				else (RECEIVER_FAST_MASK_VARIANTS if masks \
				else (RECEIVER_FAST_GX_VARIANTS if gx else RECEIVER_FAST_VARIANTS))
	var wanted: String = table[mask]
	if current != wanted:
		mat.shader = load(wanted)


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)
