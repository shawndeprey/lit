extends RefCounted

## Cached [node, kind] list for the lit_lights group: tree watching, rebuild on
## change, and per-frame visibility culling.
##
## At runtime a packed mirror (ranges, per-light state flags) rides along with the
## node list, so the per-frame cull and shadow scan are tight typed loops instead
## of O(all lights) node property walks. Positions are still read live during the
## cull (transform notifications are deferred in Godot, so a mirrored position
## would cull moving lights one frame late); the flags gate that read to enabled,
## visible lights. The mirror is kept truthful by the lights themselves: the
## cull/scan-relevant setters and visibility notifications (synchronous, unlike
## transforms) call LitLightRegistry.light_state_changed, which lands the node in
## the static pending set consumed here before each cull. The editor never uses
## the mirror - it full-walks the nodes every refresh, so editor state stays
## derived, never event-registered (script reloads wipe statics).

const F_ENABLED := 1
const F_VISIBLE := 2
const F_SHADOW := 4
const F_EXCLUDE := 8
const ALGO_SHIFT := 4

# Cached list of [node, kind] for the lit_lights group, rebuilt only when the tree
# changes (see _get_cached_lights), so refresh() skips a group scan + type dispatch
# every frame.
var _light_cache: Array = []
var _cache_dirty: bool = true
var _cache_tree: SceneTree = null
# Facade fan-out invoked per tree event, after the cache is dirtied.
var _on_changed := Callable()

# Packed mirror, parallel to _light_cache. _nodes/_kinds keep the hot cull loop off
# the [node, kind] entry arrays; _index maps node -> mirror row for the pending-set
# writes.
var _nodes: Array = []
var _kinds := PackedByteArray()
var _ranges := PackedFloat32Array()
var _flags := PackedInt32Array()
var _smasks := PackedInt32Array()
var _index := {}

# Lights whose mirrored state changed since the last consume (static: the lights
# reach it without a path to the registry instance; runtime-only by the gate in
# LitLightRegistry.light_state_changed).
static var _pending := {}

static func note_changed(node: Node) -> void:
	_pending[node] = true


func set_fan_out(cb: Callable) -> void:
	_on_changed = cb


func all() -> Array:
	return _light_cache


func cull_visible(tree: SceneTree, world_rect: Rect2) -> Array:
	var lights := _get_cached_lights(tree)
	if Engine.is_editor_hint():
		return _cull_visible_walk(lights, world_rect)
	var visible: Array = []
	var min_x := world_rect.position.x
	var min_y := world_rect.position.y
	var max_x := world_rect.position.x + world_rect.size.x
	var max_y := world_rect.position.y + world_rect.size.y
	for i in _flags.size():
		var f := _flags[i]
		if f & (F_ENABLED | F_VISIBLE) != F_ENABLED | F_VISIBLE:
			continue
		var node: Node2D = _nodes[i]
		if _kinds[i] == 1:
			visible.append(node)
			continue
		var p := node.global_position
		var r := _ranges[i]
		if p.x + r < min_x or p.x - r > max_x or p.y + r < min_y or p.y - r > max_y:
			continue
		visible.append(node)
	return visible


## Tree-wide shadow state for the algo/mask gates in refresh(): [active algo bits,
## shadow_mask union, mask potential seen]. Only enabled, shadow-casting lights
## count; visibility is deliberately ignored so camera motion never thrashes
## receiver shaders. Mask fields are only read when read_masks is set.
func shadow_scan(tree: SceneTree, read_masks: bool) -> Array:
	var lights := _get_cached_lights(tree)
	if Engine.is_editor_hint():
		return _shadow_scan_walk(lights, read_masks)
	var algos := 0
	var smask_union := 0
	var potential := false
	for i in _flags.size():
		var f := _flags[i]
		if f & (F_ENABLED | F_SHADOW) != F_ENABLED | F_SHADOW:
			continue
		var algo := f >> ALGO_SHIFT
		if algo != 0:
			algos |= 1 << (algo - 1)
		if read_masks:
			var smask := _smasks[i]
			smask_union |= smask
			if smask != 1 or f & F_EXCLUDE != 0:
				potential = true
	return [algos, smask_union, potential]


## Editor cull: full node walk every refresh (never the mirror). A freed node marks
## the cache dirty so it rebuilds next frame.
func _cull_visible_walk(lights: Array, world_rect: Rect2) -> Array:
	var visible: Array = []
	for entry in lights:
		var node: Node = entry[0]
		if not is_instance_valid(node):
			_cache_dirty = true
			continue
		var kind: int = entry[1]
		if kind == 1:
			var directional := node as LitDirectionalLight2D
			if directional.enabled and directional.is_visible_in_tree():
				visible.append(directional)
		elif kind == 0:
			var point := node as LitPointLight2D
			if point.enabled and point.is_visible_in_tree() and _aabb_visible(point.global_position, point.range, world_rect):
				visible.append(point)
		else:
			var spot := node as LitSpotLight2D
			if spot.enabled and spot.is_visible_in_tree() and _aabb_visible(spot.global_position, spot.range, world_rect):
				visible.append(spot)
	return visible


func _shadow_scan_walk(lights: Array, read_masks: bool) -> Array:
	var algos := 0
	var smask_union := 0
	var potential := false
	for entry in lights:
		# Untyped: enabled/shadow_enabled/shadow_algorithm live on each light class,
		# not on a shared base.
		var node = entry[0]
		if not is_instance_valid(node) or not node.enabled or not node.shadow_enabled:
			continue
		if node.shadow_algorithm != 0:
			algos |= 1 << (node.shadow_algorithm - 1)
		if read_masks:
			var smask: int = node.shadow_mask
			smask_union |= smask
			if smask != 1 or node.exclude_scene_occluders:
				potential = true
	return [algos, smask_union, potential]


## Return the cached [node, kind] light list, rebinding tree-change signals and
## rebuilding the cache only when the tree changed or a node entered/left it. At
## runtime, changed lights from the pending set are re-mirrored here too.
func _get_cached_lights(tree: SceneTree) -> Array:
	if tree != _cache_tree:
		_bind_cache_tree(tree)
		_cache_dirty = true
	if _cache_dirty:
		_rebuild_light_cache(tree)
	elif not _pending.is_empty() and not Engine.is_editor_hint():
		for node in _pending:
			var i: int = _index.get(node, -1)
			if i >= 0 and is_instance_valid(node):
				_write_mirror(i, node, _light_cache[i][1])
		_pending.clear()
	return _light_cache

## Move the node_added/node_removed subscriptions to `tree`, so any node entering or
## leaving (lights included) marks the cache dirty for the next refresh.
func _bind_cache_tree(tree: SceneTree) -> void:
	if _cache_tree != null and is_instance_valid(_cache_tree):
		if _cache_tree.node_added.is_connected(_on_tree_changed):
			_cache_tree.node_added.disconnect(_on_tree_changed)
		if _cache_tree.node_removed.is_connected(_on_tree_changed):
			_cache_tree.node_removed.disconnect(_on_tree_changed)
	_cache_tree = tree
	if tree != null:
		if not tree.node_added.is_connected(_on_tree_changed):
			tree.node_added.connect(_on_tree_changed)
		if not tree.node_removed.is_connected(_on_tree_changed):
			tree.node_removed.connect(_on_tree_changed)

func _on_tree_changed(node: Node) -> void:
	_cache_dirty = true
	_on_changed.call(node)


## Rescan the lit_lights group and store [node, kind] (kind: 0 point, 1 directional,
## 2 spot) so refresh() avoids the group scan and per-node type dispatch each frame.
## The packed mirror is rebuilt from the same pass.
func _rebuild_light_cache(tree: SceneTree) -> void:
	_light_cache.clear()
	_index.clear()
	for node in tree.get_nodes_in_group("lit_lights"):
		var kind := -1
		if node is LitDirectionalLight2D:
			kind = 1
		elif node is LitPointLight2D:
			kind = 0
		elif node is LitSpotLight2D:
			kind = 2
		if kind >= 0:
			_light_cache.append([node, kind])
	var n := _light_cache.size()
	_nodes.resize(n)
	_kinds.resize(n)
	_ranges.resize(n)
	_flags.resize(n)
	_smasks.resize(n)
	for i in n:
		var entry: Array = _light_cache[i]
		_nodes[i] = entry[0]
		_kinds[i] = entry[1]
		_index[entry[0]] = i
		_write_mirror(i, entry[0], entry[1])
	_pending.clear()
	_cache_dirty = false

## Re-read one light's cull/scan-relevant state into its mirror row.
func _write_mirror(i: int, node: Node, kind: int) -> void:
	var f := 0
	if kind == 1:
		var directional := node as LitDirectionalLight2D
		if directional.enabled: f |= F_ENABLED
		if directional.is_visible_in_tree(): f |= F_VISIBLE
		if directional.shadow_enabled: f |= F_SHADOW
		if directional.exclude_scene_occluders: f |= F_EXCLUDE
		f |= directional.shadow_algorithm << ALGO_SHIFT
		_smasks[i] = directional.shadow_mask
	elif kind == 0:
		var point := node as LitPointLight2D
		if point.enabled: f |= F_ENABLED
		if point.is_visible_in_tree(): f |= F_VISIBLE
		if point.shadow_enabled: f |= F_SHADOW
		if point.exclude_scene_occluders: f |= F_EXCLUDE
		f |= point.shadow_algorithm << ALGO_SHIFT
		_ranges[i] = point.range
		_smasks[i] = point.shadow_mask
	else:
		var spot := node as LitSpotLight2D
		if spot.enabled: f |= F_ENABLED
		if spot.is_visible_in_tree(): f |= F_VISIBLE
		if spot.shadow_enabled: f |= F_SHADOW
		if spot.exclude_scene_occluders: f |= F_EXCLUDE
		f |= spot.shadow_algorithm << ALGO_SHIFT
		_ranges[i] = spot.range
		_smasks[i] = spot.shadow_mask
	_flags[i] = f

## True if a light's `range`-expanded AABB intersects the visible world rect.
func _aabb_visible(pos: Vector2, light_range: float, world_rect: Rect2) -> bool:
	var aabb := Rect2(pos - Vector2(light_range, light_range), Vector2(light_range * 2.0, light_range * 2.0))
	return world_rect.intersects(aabb)
