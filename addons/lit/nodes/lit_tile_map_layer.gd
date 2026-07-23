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

@export var emissive_strength: float = 0.0:
	set(value):
		emissive_strength = value
		_set_param("emissive_strength", value)

@export_flags_2d_render var receiver_mask: int = 1:
	set(value):
		receiver_mask = value
		_set_param("receiver_mask", value)

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
				and (mat.shader.resource_path in RECEIVER_FAST_VARIANTS \
				or mat.shader.resource_path in RECEIVER_FULL_VARIANTS):
			material = mat.duplicate()
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


func _apply_shader_variant(wants_full: bool) -> void:
	var mat := material as ShaderMaterial
	if mat == null or mat.shader == null:
		return
	var current: String = mat.shader.resource_path
	if not (current in RECEIVER_FAST_VARIANTS or current in RECEIVER_FULL_VARIANTS):
		return
	var mask := LitLightRegistry.active_algos & 3
	var wanted: String = (RECEIVER_FULL_VARIANTS if wants_full else RECEIVER_FAST_VARIANTS)[mask]
	if current != wanted:
		mat.shader = load(wanted)


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)
