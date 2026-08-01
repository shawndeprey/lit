extends RefCounted

## Rx receiver registry (shadow_ignore_mask): node set, editor rescan, per-frame
## mask union, and rx_bound driving. The node set is static: node setters register
## through the facade's rx_set shim, shared by both editor registry instances.

# --- Per-receiver shadow exclusion (shadow_ignore_mask) ------------------------------
# Receiver node -> non-zero shadow_ignore_mask, maintained by the node setters (scene
# loads included) so mask-free scenes never pay a walk or a poll. A receiver ignores
# shadows from occluders whose occluder_light_mask shares a bit with its mask; the
# shader tests each march sample against the occluder identity tiles, so exemption is
# per-occluder precise at any caster count and costs only the rx receiver's fragments.
static var _rx_nodes := {}

var _rx_bound_last := {}         # rx node -> last rx_bound Vector4 pushed to its material


static func rx_set(node: CanvasItem, mask: int) -> void:
	if mask == 0:
		_rx_nodes.erase(node)
	else:
		_rx_nodes[node] = mask


## Facade seam: the live registered-node map (node -> mask).
static func nodes() -> Dictionary:
	return _rx_nodes

## The editor reloads @tool scripts in place on every scene save, reinitializing all
## statics while the tree lives on; setter-driven registration therefore cannot be
## trusted there. Rebuilt from the tree each editor refresh instead (the setters stay
static func rescan_editor(root: Node) -> void:
	_rx_nodes.clear()
	if root != null:
		_collect_rx_nodes(root)

static func _collect_rx_nodes(node: Node) -> void:
	if node is CanvasItem:
		var m = node.get("shadow_ignore_mask")
		if m != null and int(m) != 0:
			_rx_nodes[node] = int(m)
	for child in node.get_children():
		_collect_rx_nodes(child)

## Prune freed or exited rx nodes and return the OR of live masks this frame.
func compute_union() -> int:
	var union := 0
	if not _rx_nodes.is_empty():
		var rx_stale: Array = []
		for node in _rx_nodes:
			if not is_instance_valid(node):
				rx_stale.append(node)
			elif node.is_inside_tree():
				union |= _rx_nodes[node]
		for n in rx_stale:
			_rx_nodes.erase(n)
			_rx_bound_last.erase(n)
	return union

## Push each rx receiver's ignored-caster union bounds (rx_bound) to its material, so
## marches run their slow phase only while crossing it. One vec4 per distinct mask,
## set on change; params land only on rx-class shaders (they declare the uniform), and
## the nodes swap themselves there, so a just-registered receiver syncs next frame.
func drive_bounds(rects: Array[Rect2], masks: PackedInt32Array, live_binder: Callable) -> void:
	var bounds := {}
	for node in _rx_nodes:
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		var mat := node.material as ShaderMaterial
		if Engine.is_editor_hint():
			mat = live_binder.call(node, mat)
		var mflags: int = LitShaderLibrary.flags_of(mat.shader) if mat != null else -1
		if mflags < 0 or mflags & LitShaderLibrary.F_RX == 0:
			continue
		var rmask: int = _rx_nodes[node]
		if not bounds.has(rmask):
			var matching: Array[Rect2] = []
			for i in rects.size():
				if (masks[i] & rmask) != 0:
					matching.append(rects[i])
			var packed := PackedVector4Array()
			packed.resize(4)
			var cnt := 0
			if not matching.is_empty():
				var cl := _cluster_bounds(matching)
				cnt = cl.size()
				for i in cnt:
					packed[i] = Vector4(cl[i].position.x, cl[i].position.y,
							cl[i].end.x, cl[i].end.y)
			bounds[rmask] = [packed, cnt]
		var v: Array = bounds[rmask]
		if Engine.is_editor_hint():
			# Clones can be recreated under us (save-time script reload); dedup
			# against the clone itself instead of the wipeable cache.
			if mat.get_shader_parameter("rx_bounds") != v[0]:
				mat.set_shader_parameter("rx_bounds", v[0])
				mat.set_shader_parameter("rx_bound_count", v[1])
		elif _rx_bound_last.get(node) != v[0]:
			_rx_bound_last[node] = v[0]
			mat.set_shader_parameter("rx_bounds", v[0])
			mat.set_shader_parameter("rx_bound_count", v[1])

## Greedy least-area-growth clustering of the ignored casters into at most 4 bound
## rects. Scattered sets stay tight clusters instead of one screen-sized union; large
## sets fall back to the single union (dense fields degenerate either way).
static func _cluster_bounds(rects: Array[Rect2]) -> Array[Rect2]:
	if rects.size() > 24:
		var u := rects[0]
		for r in rects:
			u = u.merge(r)
		var one: Array[Rect2] = [u]
		return one
	var cl: Array[Rect2] = rects.duplicate()
	while cl.size() > 4:
		var bi := 0
		var bj := 1
		var best := INF
		for i in cl.size():
			for j in range(i + 1, cl.size()):
				var growth: float = cl[i].merge(cl[j]).get_area() \
						- cl[i].get_area() - cl[j].get_area()
				if growth < best:
					best = growth
					bi = i
					bj = j
		cl[bi] = cl[bi].merge(cl[bj])
		cl.remove_at(bj)
	return cl

