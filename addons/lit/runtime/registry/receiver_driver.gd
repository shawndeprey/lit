extends RefCounted

## Receiver variant application and bare-receiver driving: re-points receiver
## materials at the active variant set, and drives self rects, y-sort depth, and
## variant tier for occluder-owning bare receivers (editor: on RS clones via the
## injected live binder).

# Algorithm mask last applied to receiver materials, and whether the tree changed since
# the last application. Starting at 0 (the base mask) means a scene that never uses the
# physical algorithms never pays for a receiver walk.
var _published_algos: int = 0
var _receiver_dirty: bool = true

var _bare_cache: Array = []      # [node, mat, occluders, last rects, last count, tile rects]
var _bare_driven := {}
var _bare_dirty := true
var _bare_shared_warned := false

# Facade-owned frame state, re-bound at apply()/drive_bare() entry.
var activity_flags := 0
var ysort_enabled := false
var _rx_nodes := {}
var _live_binder := Callable()
# Facade fan-out for tilemap changed signals (also dirties the occluder cache).
var _on_changed := Callable()


func set_fan_out(cb: Callable) -> void:
	_on_changed = cb


## Re-point every Lit receiver material under `root` at the variant compiled for the
## currently active shadow algorithms, preserving each material's fast/full axis
## (LitSprite2D owns that axis and converges to the same target). Work happens only
## when the mask changed, or when the tree changed while a non-base mask is active
## (newly added receivers arrive on the base variant and need the swap); a scene that
## never uses the physical algorithms never walks the tree here.
func apply(root: Node, key_flags: int, rx_nodes: Dictionary, live_binder: Callable) -> void:
	activity_flags = key_flags
	_rx_nodes = rx_nodes
	_live_binder = live_binder
	var key := activity_flags
	if Engine.is_editor_hint():
		# No key==0 fast path: this walk also heals legacy variant paths on scene open.
		if root == null or (key == _published_algos and not _receiver_dirty):
			return
		_editor_apply_variants(root)
		_published_algos = key
		_receiver_dirty = false
		return
	if key == _published_algos and (key == 0 or not _receiver_dirty):
		return
	if root == null:
		return
	# Rx variants are chosen node-locally (each Lit node heals its own material from
	# its shadow_ignore_mask); leave those materials alone. Rx-path materials no live
	# node claims fall through and get re-tiered like any other stray.
	var rx_mats := {}
	if not _rx_nodes.is_empty():
		for node in _rx_nodes:
			if is_instance_valid(node) and node.material != null:
				rx_mats[node.material] = true
	var mats := {}
	_collect_receiver_mats(root, mats)
	for mat in mats:
		if rx_mats.has(mat):
			continue
		var flags: int = LitShaderLibrary.flags_of(mat.shader)
		var wanted := LitShaderLibrary.resolve(flags & LitShaderLibrary.TIER_MASK, 0, key)
		if flags != wanted:
			mat.shader = LitShaderLibrary.get_receiver(wanted)
	_published_algos = key
	_receiver_dirty = false

## Editor walk: heal legacy variant paths in authored materials to their tier's entry
## file, and preview activity variants for undriven bare receivers on their RS clones.
func _editor_apply_variants(node: Node) -> void:
	var ci := node as CanvasItem
	if ci != null:
		var mat := ci.material as ShaderMaterial
		if mat != null and mat.shader != null:
			var flags: int = LitShaderLibrary.flags_of(mat.shader)
			if flags >= 0:
				var tier := flags & LitShaderLibrary.TIER_MASK
				var entry: String = LitShaderLibrary.ENTRY_PATHS[tier]
				if mat.shader.resource_path != entry:
					mat.shader = load(entry)
				# Occluder-owning bare receivers are variant-driven by _push_self_rects;
				# Lit nodes drive themselves.
				if not node.has_method("_update_self_rect") and not _bare_driven.has(mat):
					var live := _live_binder.call(ci, mat)
					var wanted := LitShaderLibrary.resolve(tier, 0, activity_flags)
					if LitShaderLibrary.flags_of(live.shader) != wanted:
						live.shader = LitShaderLibrary.get_receiver(wanted)
	for child in node.get_children():
		_editor_apply_variants(child)


## Collect (deduped, as Dictionary keys) every ShaderMaterial in the subtree whose
## shader is one of the Lit receiver variants. Materials shared across nodes are
## visited once.
func _collect_receiver_mats(node: Node, acc: Dictionary) -> void:
	var ci := node as CanvasItem
	if ci != null:
		var mat := ci.material as ShaderMaterial
		if mat != null and mat.shader != null and LitShaderLibrary.flags_of(mat.shader) >= 0:
			acc[mat] = true
	for child in node.get_children():
		_collect_receiver_mats(child, acc)


func drive_bare(root: Node, key_flags: int, p_ysort: bool, live_binder: Callable) -> void:
	activity_flags = key_flags
	ysort_enabled = p_ysort
	_live_binder = live_binder
	if root == null:
		return
	if _bare_dirty:
		_rebuild_bare_cache(root)
	for entry in _bare_cache:
		var spr: Node2D = entry[0]
		var mat: ShaderMaterial = entry[1]
		if not is_instance_valid(spr) or not spr.is_inside_tree() \
				or spr.material != mat or mat.shader == null:
			_bare_dirty = true
			continue
		_push_self_rects(entry)

func _rebuild_bare_cache(root: Node) -> void:
	_bare_cache.clear()
	var by_mat := {}
	_collect_bare_receivers(root, by_mat)
	var driven := {}
	for mat in by_mat:
		var nodes: Array = by_mat[mat]
		if nodes.size() > 1:
			if not _bare_shared_warned and _any_owns_occluders(nodes):
				_bare_shared_warned = true
				push_warning("Lit: a receiver material is shared by %d nodes; self-shadow exclusion needs one material per node." % nodes.size())
			continue
		var node = nodes[0]
		var tile_rects: Array[Rect2] = []
		var tml := node as TileMapLayer
		if tml != null:
			tile_rects = tile_occluder_rects(tml)
			if not tml.changed.is_connected(_on_changed):
				tml.changed.connect(_on_changed)
		var occluders := _owned_occluders(node)
		if occluders.is_empty() and tile_rects.is_empty():
			# Heal stale rects a scene save may have baked into the material.
			var stale = mat.get_shader_parameter("self_rect_count")
			if stale != null and int(stale) != 0:
				mat.set_shader_parameter("self_rect_count", 0)
			continue
		_bare_cache.append([node, mat, occluders, PackedVector4Array(), -1, tile_rects, false, 0.0, null])
		driven[mat] = true
	for mat in _bare_driven:
		if not driven.has(mat) and is_instance_valid(mat):
			mat.set_shader_parameter("self_rect_count", 0)
	_bare_driven = driven
	_bare_dirty = false

func _collect_bare_receivers(node: Node, acc: Dictionary) -> void:
	if (node is Sprite2D or node is AnimatedSprite2D or node is TileMapLayer) \
			and not node.has_method("_update_self_rect"):
		var mat := (node as CanvasItem).material as ShaderMaterial
		if mat != null and mat.shader != null and LitShaderLibrary.flags_of(mat.shader) >= 0:
			if not acc.has(mat):
				acc[mat] = []
			acc[mat].append(node)
	for child in node.get_children():
		_collect_bare_receivers(child, acc)

func _owned_occluders(spr: Node) -> Array:
	var occluders: Array = []
	for child in spr.find_children("*", "LightOccluder2D", true, false):
		occluders.append(child)
	# A tilemap's siblings are unrelated level content, not its own occluders.
	if spr is TileMapLayer:
		return occluders
	var parent := spr.get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling is LightOccluder2D:
				occluders.append(sibling)
	return occluders

func _any_owns_occluders(nodes: Array) -> bool:
	for n in nodes:
		if not _owned_occluders(n).is_empty():
			return true
		if n is TileMapLayer and not tile_occluder_rects(n).is_empty():
			return true
	return false

## Local-space bounds of the tileset occlusion polygons on this layer's painted cells:
## one tight rect per occluder cell up to the shader's 4 slots, a single union beyond.
static func tile_occluder_rects(layer: TileMapLayer) -> Array[Rect2]:
	var ts := layer.tile_set
	if ts == null:
		return []
	var occ_layers := ts.get_occlusion_layers_count()
	if occ_layers == 0:
		return []
	var poly_rects := {}
	var rects: Array[Rect2] = []
	var union := Rect2()
	var count := 0
	for cell in layer.get_used_cells():
		var td := layer.get_cell_tile_data(cell)
		if td == null:
			continue
		var cell_rect := Rect2()
		var has_cell := false
		for l in occ_layers:
			for p in td.get_occluder_polygons_count(l):
				var poly: OccluderPolygon2D = td.get_occluder_polygon(l, p)
				if poly == null or poly.polygon.is_empty():
					continue
				var pr: Rect2
				if poly_rects.has(poly):
					pr = poly_rects[poly]
				else:
					pr = Rect2(poly.polygon[0], Vector2.ZERO)
					for pt in poly.polygon:
						pr = pr.expand(pt)
					poly_rects[poly] = pr
				cell_rect = pr if not has_cell else cell_rect.merge(pr)
				has_cell = true
		if not has_cell:
			continue
		cell_rect.position += layer.map_to_local(cell)
		union = cell_rect if count == 0 else union.merge(cell_rect)
		count += 1
		if count <= 4:
			rects.append(cell_rect)
	if count > 4:
		var single: Array[Rect2] = [union]
		return single
	return rects

# Keep aligned with LitSprite2D._update_self_rect.
func _push_self_rects(entry: Array) -> void:
	var spr: Node2D = entry[0]
	var mat: ShaderMaterial = entry[1]
	if Engine.is_editor_hint():
		mat = _live_binder.call(spr, mat)
	if mat != entry[8]:
		# Fresh clone (first frame or post-save script reload): re-land every param.
		entry[8] = mat
		entry[3] = PackedVector4Array()
		entry[4] = -1
		entry[6] = null
		entry[7] = null
	var rects: Array[Rect2] = []
	for tile_rect in entry[5]:
		rects.append(spr.global_transform * tile_rect)
	for node in entry[2]:
		if not is_instance_valid(node):
			_bare_dirty = true
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
	if packed != entry[3] or rects.size() != entry[4]:
		entry[3] = packed
		entry[4] = rects.size()
		mat.set_shader_parameter("self_rects", packed)
		mat.set_shader_parameter("self_rect_count", rects.size())

	# Y-sort participation: occluder-owning sprites only, depth = footprint bottom.
	var ys_on := false
	var ys_y := 0.0
	if ysort_enabled and not (spr is TileMapLayer) and not rects.is_empty():
		ys_on = true
		ys_y = rects[0].end.y
		for r in rects:
			ys_y = maxf(ys_y, r.end.y)

	var wants_full: bool = rects.size() > 0 and mat.get_shader_parameter("self_shadow") != true
	var flags: int = LitShaderLibrary.flags_of(mat.shader)
	if flags >= 0:
		var tier := (LitShaderLibrary.F_SELF_EXCL | LitShaderLibrary.F_YSORT) if ys_on \
				else (LitShaderLibrary.F_SELF_EXCL if wants_full else 0)
		var wanted := LitShaderLibrary.resolve(tier, 0, activity_flags)
		if flags != wanted:
			mat.shader = LitShaderLibrary.get_receiver(wanted)

	# After the swap, so the params land on a shader declaring them.
	if entry[6] != ys_on or entry[7] != ys_y:
		entry[6] = ys_on
		entry[7] = ys_y
		mat.set_shader_parameter("ysort_on", ys_on)
		mat.set_shader_parameter("ysort_y", ys_y)
