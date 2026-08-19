extends RefCounted

## Occluder identity cache and tile grid: per-occluder canvas rects (depth line +
## mask|owner) gathered from loose occluders and tilemap cells, binned into the
## light tile grid; owns the gx publish and the runtime sdf-cull state.

# Must match the shader's tile math and LIT_INDEX_TEX_WIDTH (see screen_tiles.gd).
const TILE_SIZE := 64
const INDEX_TEX_WIDTH := 2048

const FrameContext := preload("res://addons/lit/runtime/registry/frame_context.gd")

var _occ_nodes: Array = []       # [LightOccluder2D, owner id]
var _occ_layers: Array = []      # [TileMapLayer, cell rects, xform, world rects, masks, distinct, ts snapshot]
var _occ_dirty := true
var _occ_pack_buf := PackedFloat32Array()
var _occ_mask_set := {}          # distinct SDF-casting occluder masks, exact at cache rebuild
var _occ_masks_seen := false     # any non-default SDF-casting occluder mask observed (sticky)
var _scope_ids := {}             # scope root Node -> owner id
var _scope_occ_masks := {}       # owner id -> {mask: true} of SDF casters under that scope
var _gx_rects: Array[Rect2] = []
var _gx_packed := PackedVector4Array()
var _sdf_culled := {}            # occluders whose sdf_collision this registry disabled
var _ts_culled := {}             # TileSet -> {occlusion layer idx} this registry disabled
var _occ_spans := PackedInt32Array()
var _occ_tile_counts := PackedInt32Array()
var _occ_tile_min := PackedFloat32Array()
var _occ_tile_mask := PackedInt32Array()
var _occ_header_buf := PackedFloat32Array()
var _occ_index_buf := PackedFloat32Array()
var _occ_prev_pack := PackedFloat32Array()
var _occ_prev_xform := Transform2D()
var _occ_prev_grid := Vector2i.ZERO
var _occ_img: Image
var _occ_header_img: Image
var _occ_index_img: Image
var _occ_tex: ImageTexture
var _occ_header_tex: ImageTexture
var _occ_index_tex: ImageTexture
var _gx_frame := false

# Frame state re-bound at build() entry: aliases of the FrameContext outputs (occ_*)
# and of the exclusions module's dictionaries, so the moved bodies read/write the
# shared instances (packed arrays and dicts are pass-by-reference).
var _occ_rects: Array[Rect2] = []
var _occ_masks := PackedInt32Array()
var _occ_owners := PackedInt32Array()
var _gx_masks := {}
var _excl_smasks := {}
var _excl_owners := {}
var _rx_union_frame := 0
var ysort_enabled := false
var sdf_cull := false
# Facade fan-out for tilemap changed signals (also dirties the bare-receiver cache).
var _on_changed := Callable()


func set_fan_out(cb: Callable) -> void:
	_on_changed = cb


# --- Facade seam ----------------------------------------------------------------
# The named surface the facade drives this module through; dictionary accessors
# return the live references (shared-mutation by design, like the ctx spine).

func mark_dirty() -> void:
	_occ_dirty = true


func note_mask_seen() -> void:
	_occ_masks_seen = true


func masks_seen() -> bool:
	return _occ_masks_seen


func mask_set() -> Dictionary:
	return _occ_mask_set


func scope_ids() -> Dictionary:
	return _scope_ids


func scope_occ_masks() -> Dictionary:
	return _scope_occ_masks


func occ_nodes() -> Array:
	return _occ_nodes


func occ_layers() -> Array:
	return _occ_layers


## Whether the last build published any globally exempt rects.
func gx_this_frame() -> bool:
	return _gx_frame


## Force the next build to re-pack and re-bin (framing semantics changed, e.g. the
## y-sort toggle flipping which casters the pack includes).
func reset_pack_memo() -> void:
	_occ_prev_pack = PackedFloat32Array()


## Pack every SDF-casting occluder's canvas rect (max.y doubles as its depth line) and
## bin the rects into the light tile grid; mirrors _build_tiles. Header texel z carries
## the tile's min depth so the shader can dismiss whole tiles with one fetch. Frames
## where nothing moved skip the binning and uploads entirely.
## Returns true when the occluder pack bytes are unchanged from the previous build.
func build(ctx: FrameContext, root: Node, lights: Array, gx_masks: Dictionary,
		excl_smasks: Dictionary, excl_owners: Dictionary, p_ysort: bool,
		p_sdf_cull: bool) -> bool:
	var canvas_xform: Transform2D = ctx.canvas_xform
	var vp_size: Vector2 = ctx.vp_size
	var world_rect: Rect2 = ctx.world_rect
	_occ_rects = ctx.occ_rects
	_occ_masks = ctx.occ_masks
	_occ_owners = ctx.occ_owners
	_gx_masks = gx_masks
	_excl_smasks = excl_smasks
	_excl_owners = excl_owners
	_rx_union_frame = ctx.rx_union
	ysort_enabled = p_ysort
	sdf_cull = p_sdf_cull
	if _occ_dirty:
		_rebuild_occ_cache(root, lights)

	# Generous pad: off-view casters still shadow into the oversized SDF.
	var cull_rect := world_rect.grow(maxf(world_rect.size.x, world_rect.size.y) * 0.25)

	# Y-sort needs every caster's identity; masks alone only need the excludable ones
	# (the weight test is only consulted near exempt rects), so non-excluded occluders
	# and whole non-excluded tilemap layers are skipped without per-cell work.
	var full_set := ysort_enabled

	_occ_rects.clear()
	_occ_masks.clear()
	_occ_owners.clear()
	_gx_rects.clear()

	for entry in _occ_nodes:
		var node = entry[0]
		if not is_instance_valid(node):
			_occ_dirty = true
			continue
		var occ := node as LightOccluder2D
		if not occ.is_inside_tree() or not occ.is_visible_in_tree() \
				or occ.occluder == null or occ.occluder.polygon.is_empty():
			continue
		if sdf_cull and occ.sdf_collision and _gx_masks.has(occ.occluder_light_mask):
			# Out of the SDF entirely; _restore_unculled brings it back when wanted.
			occ.sdf_collision = false
			_sdf_culled[occ] = true
		if not occ.sdf_collision:
			continue
		var m: int = occ.occluder_light_mask
		if not _occ_mask_set.has(m):
			# Live mask edits classify correctly from the next frame on.
			_occ_mask_set[m] = true
			if m != 1:
				_occ_masks_seen = true
		var is_gx: bool = _gx_masks.has(m)
		if not full_set and not is_gx and not _exempt_for_any(m, entry[1]) \
				and (m & _rx_union_frame) == 0:
			continue
		var xf := occ.global_transform
		var r := Rect2(xf * occ.occluder.polygon[0], Vector2.ZERO)
		for p in occ.occluder.polygon:
			r = r.expand(xf * p)
		if not cull_rect.intersects(r):
			continue
		if is_gx:
			_gx_rects.append(r)
			continue
		_occ_rects.append(r)
		_occ_masks.append(m)
		_occ_owners.append(entry[1])

	for entry in _occ_layers:
		var layer: TileMapLayer = entry[0]
		if not is_instance_valid(layer):
			_occ_dirty = true
			continue
		if not layer.is_inside_tree() or not layer.is_visible_in_tree():
			continue
		var culled := {}
		var ts := layer.tile_set
		if ts != null and not _gx_masks.is_empty():
			if sdf_cull:
				for l in ts.get_occlusion_layers_count():
					if ts.get_occlusion_layer_sdf_collision(l) \
							and _gx_masks.has(ts.get_occlusion_layer_light_mask(l)):
						# Out of the SDF like loose occluders; _restore_unculled reverts.
						ts.set_occlusion_layer_sdf_collision(l, false)
						if not _ts_culled.has(ts):
							_ts_culled[ts] = {}
						_ts_culled[ts][l] = true
			for l in _ts_culled.get(ts, {}):
				culled[ts.get_occlusion_layer_light_mask(l)] = true
		if not culled.is_empty():
			var all_culled := true
			for m in entry[5]:
				if not culled.has(m):
					all_culled = false
					break
			if all_culled:
				continue
		var include := {}
		var any_gx := false
		if not full_set:
			for m in entry[5]:
				if culled.has(m):
					continue
				if _gx_masks.has(m):
					any_gx = true
				elif _exempt_for_any(m, 0) or (m & _rx_union_frame) != 0:
					include[m] = true
			if include.is_empty() and not any_gx:
				continue
		var xf: Transform2D = layer.global_transform
		if entry[2] != xf:
			entry[2] = xf
			var world: Array[Rect2] = []
			world.resize(entry[1].size())
			for i in entry[1].size():
				world[i] = xf * entry[1][i]
			entry[3] = world
		var layer_masks: PackedInt32Array = entry[4]
		for i in entry[3].size():
			var m := layer_masks[i]
			if culled.has(m):
				continue
			var r: Rect2 = entry[3][i]
			if _gx_masks.has(m):
				if cull_rect.intersects(r):
					_gx_rects.append(r)
				continue
			if not full_set and not include.has(m):
				continue
			if cull_rect.intersects(r):
				_occ_rects.append(r)
				_occ_masks.append(m)
				_occ_owners.append(0)

	# Global tier: 4 slots, extras unioned into the last; published as globals so every
	# receiver type sees them with no material walk.
	while _gx_rects.size() > 4:
		_gx_rects[3] = _gx_rects[3].merge(_gx_rects.pop_back())
	_gx_frame = not _gx_rects.is_empty()
	var gx_packed := PackedVector4Array()
	gx_packed.resize(_gx_rects.size())
	for i in _gx_rects.size():
		gx_packed[i] = Vector4(_gx_rects[i].position.x, _gx_rects[i].position.y,
				_gx_rects[i].end.x, _gx_rects[i].end.y)
	_publish_gx(gx_packed)

	var count := _occ_rects.size()
	var tiles_x := maxi(int(ceil(vp_size.x / float(TILE_SIZE))), 1)
	var tiles_y := maxi(int(ceil(vp_size.y / float(TILE_SIZE))), 1)
	var tile_count := tiles_x * tiles_y
	var grid := Vector2i(tiles_x, tiles_y)

	# Two texels per occluder: t0 rect, t1.x light mask (the rx tile test reads it).
	var floats_needed := maxi(count, 1) * 8
	if _occ_pack_buf.size() != floats_needed:
		_occ_pack_buf.resize(floats_needed)
	_occ_pack_buf.fill(0.0)
	for i in count:
		var o := i * 8
		var r := _occ_rects[i]
		_occ_pack_buf[o + 0] = r.position.x
		_occ_pack_buf[o + 1] = r.position.y
		_occ_pack_buf[o + 2] = r.end.x
		_occ_pack_buf[o + 3] = r.end.y
		_occ_pack_buf[o + 4] = float(_occ_masks[i])

	var pack_same := _occ_pack_buf == _occ_prev_pack
	# Masks alone need no tile binning; the exempt rects travel in the light rows.
	# Y-sort and rx both consume the occluder tiles, so either builds them.
	if not ysort_enabled and _rx_union_frame == 0:
		if not pack_same:
			_occ_prev_pack = _occ_pack_buf.duplicate()
		return pack_same
	if pack_same and canvas_xform == _occ_prev_xform and grid == _occ_prev_grid:
		return pack_same
	if not pack_same:
		_occ_prev_pack = _occ_pack_buf.duplicate()
	_occ_prev_xform = canvas_xform
	_occ_prev_grid = grid

	if _occ_tile_counts.size() != tile_count:
		_occ_tile_counts.resize(tile_count)
		_occ_tile_min.resize(tile_count)
		_occ_tile_mask.resize(tile_count)
	_occ_tile_counts.fill(0)
	_occ_tile_min.fill(3.4e38)
	_occ_tile_mask.fill(0)
	if _occ_spans.size() != count * 4:
		_occ_spans.resize(count * 4)

	# Candidacy tests reach past a rect, so bin each one tile edge wider.
	var bin_pad := float(TILE_SIZE)
	var total := 0

	for i in count:
		var r := _occ_rects[i]
		var sr: Rect2 = canvas_xform * r
		var tx0 := clampi(int(floor((sr.position.x - bin_pad) / float(TILE_SIZE))), 0, tiles_x - 1)
		var tx1 := clampi(int(floor((sr.end.x + bin_pad) / float(TILE_SIZE))), 0, tiles_x - 1)
		var ty0 := clampi(int(floor((sr.position.y - bin_pad) / float(TILE_SIZE))), 0, tiles_y - 1)
		var ty1 := clampi(int(floor((sr.end.y + bin_pad) / float(TILE_SIZE))), 0, tiles_y - 1)
		var s4 := i * 4
		_occ_spans[s4 + 0] = tx0
		_occ_spans[s4 + 1] = tx1
		_occ_spans[s4 + 2] = ty0
		_occ_spans[s4 + 3] = ty1
		total += (tx1 - tx0 + 1) * (ty1 - ty0 + 1)
		var depth := r.end.y
		var rmask := _occ_masks[i]
		for ty in range(ty0, ty1 + 1):
			var row_base := ty * tiles_x
			for tx in range(tx0, tx1 + 1):
				var t := row_base + tx
				_occ_tile_counts[t] += 1
				_occ_tile_mask[t] |= rmask
				if depth < _occ_tile_min[t]:
					_occ_tile_min[t] = depth

	var idx_rows := int(ceil(float(maxi(total, 1)) / float(INDEX_TEX_WIDTH)))
	var header_floats := tile_count * 4
	if _occ_header_buf.size() != header_floats:
		_occ_header_buf.resize(header_floats)
	var index_floats := INDEX_TEX_WIDTH * idx_rows * 4
	if _occ_index_buf.size() != index_floats:
		_occ_index_buf.resize(index_floats)

	var offset := 0
	for t in tile_count:
		var cnt := _occ_tile_counts[t]
		var h := t * 4
		_occ_header_buf[h] = float(offset)
		_occ_header_buf[h + 1] = float(cnt)
		_occ_header_buf[h + 2] = _occ_tile_min[t]
		# Tile mask union: one fetch answers "no candidate here can match this receiver"
		# in the rx test (masks stay well under float32's exact-int range).
		_occ_header_buf[h + 3] = float(_occ_tile_mask[t])
		_occ_tile_counts[t] = offset
		offset += cnt
	for i in count:
		var s4 := i * 4
		for ty in range(_occ_spans[s4 + 2], _occ_spans[s4 + 3] + 1):
			var row_base := ty * tiles_x
			for tx in range(_occ_spans[s4 + 0], _occ_spans[s4 + 1] + 1):
				var slot := _occ_tile_counts[row_base + tx]
				_occ_tile_counts[row_base + tx] = slot + 1
				_occ_index_buf[slot * 4] = float(i)

	if not pack_same or _occ_tex == null:
		var rows := maxi(count, 1)
		var data_bytes := _occ_pack_buf.to_byte_array()
		if _occ_img == null or _occ_img.get_height() != rows or _occ_img.get_width() != 2:
			_occ_img = Image.create_from_data(2, rows, false, Image.FORMAT_RGBAF, data_bytes)
		else:
			_occ_img.set_data(2, rows, false, Image.FORMAT_RGBAF, data_bytes)
		var prev_data := _occ_tex
		_occ_tex = _make_or_update(_occ_tex, _occ_img)
		if _occ_tex != prev_data:
			RenderingServer.global_shader_parameter_set("lit_occ_data", _occ_tex)

	var header_bytes := _occ_header_buf.to_byte_array()
	if _occ_header_img == null or _occ_header_img.get_width() != tiles_x \
			or _occ_header_img.get_height() != tiles_y:
		_occ_header_img = Image.create_from_data(tiles_x, tiles_y, false, Image.FORMAT_RGBAF, header_bytes)
	else:
		_occ_header_img.set_data(tiles_x, tiles_y, false, Image.FORMAT_RGBAF, header_bytes)
	var prev_header := _occ_header_tex
	_occ_header_tex = _make_or_update(_occ_header_tex, _occ_header_img)
	if _occ_header_tex != prev_header:
		RenderingServer.global_shader_parameter_set("lit_occ_headers", _occ_header_tex)

	var index_bytes := _occ_index_buf.to_byte_array()
	if _occ_index_img == null or _occ_index_img.get_height() != idx_rows:
		_occ_index_img = Image.create_from_data(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF, index_bytes)
	else:
		_occ_index_img.set_data(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF, index_bytes)
	var prev_index := _occ_index_tex
	_occ_index_tex = _make_or_update(_occ_index_tex, _occ_index_img)
	if _occ_index_tex != prev_index:
		RenderingServer.global_shader_parameter_set("lit_occ_indices", _occ_index_tex)
	return pack_same

## Rescan the subtree for casters; tilemap cell rects cache until the layer changes.
## Also assigns scene owner ids (one per light scope root) and snapshots the distinct
## occluder-mask set.
func _rebuild_occ_cache(root: Node, lights: Array) -> void:
	_occ_nodes.clear()
	_occ_layers.clear()
	_scope_ids.clear()
	_scope_occ_masks.clear()
	_occ_mask_set.clear()
	_occ_masks_seen = false
	_occ_dirty = false
	if root == null:
		return
	for entry in lights:
		var light = entry[0]
		if not is_instance_valid(light) or not light.is_inside_tree():
			continue
		var scope: Node = light.owner if light.owner != null else light.get_parent()
		if scope != null and not _scope_ids.has(scope):
			_scope_ids[scope] = _scope_ids.size() + 1
	for occ in root.find_children("*", "LightOccluder2D", true, false):
		var owner_id := _occ_owner_id(occ)
		_occ_nodes.append([occ, owner_id])
		# Only SDF casters matter to exclusion; others cast no Lit shadows at all.
		# Culled occluders still count so their mask stays classified (no oscillation).
		if not occ.sdf_collision and not _sdf_culled.has(occ):
			continue
		if owner_id != 0:
			if not _scope_occ_masks.has(owner_id):
				_scope_occ_masks[owner_id] = {}
			_scope_occ_masks[owner_id][occ.occluder_light_mask] = true
		_occ_mask_set[occ.occluder_light_mask] = true
	for layer in root.find_children("*", "TileMapLayer", true, false):
		var pair := tile_caster_rects(layer)
		if pair[0].is_empty():
			continue
		if not layer.changed.is_connected(_on_changed):
			layer.changed.connect(_on_changed)
		var distinct := {}
		for m in pair[1]:
			distinct[m] = true
			_occ_mask_set[m] = true
		_occ_layers.append([layer, pair[0], null, [], pair[1], distinct.keys(),
				_ts_layer_masks(layer.tile_set)])
	for m in _occ_mask_set:
		if int(m) != 1:
			_occ_masks_seen = true
			break

## Nearest ancestor that is a light scope root; 0 when none.
func _occ_owner_id(occ: Node) -> int:
	var n: Node = occ
	while n != null:
		if _scope_ids.has(n):
			return _scope_ids[n]
		n = n.get_parent()
	return 0

## [rects, masks]: one layer-local rect per painted cell and occlusion mask group among
## the SDF-collision layers (culled layers included so their mask stays classified), with
## the group's light mask parallel in the second array.
func tile_caster_rects(layer: TileMapLayer) -> Array:
	var rects: Array[Rect2] = []
	var masks := PackedInt32Array()
	var ts := layer.tile_set
	if ts == null:
		return [rects, masks]
	var sdf_layers: Array[int] = []
	var layer_masks: Array[int] = []
	for l in ts.get_occlusion_layers_count():
		if ts.get_occlusion_layer_sdf_collision(l) or _ts_culled.get(ts, {}).has(l):
			sdf_layers.append(l)
			layer_masks.append(ts.get_occlusion_layer_light_mask(l))
	if sdf_layers.is_empty():
		return [rects, masks]
	var poly_rects := {}
	for cell in layer.get_used_cells():
		var td := layer.get_cell_tile_data(cell)
		if td == null:
			continue
		var by_mask := {}
		for li in sdf_layers.size():
			var l := sdf_layers[li]
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
				var m := layer_masks[li]
				by_mask[m] = pr if not by_mask.has(m) else by_mask[m].merge(pr)
		if by_mask.is_empty():
			continue
		var base := layer.map_to_local(cell)
		for m in by_mask:
			var r: Rect2 = by_mask[m]
			r.position += base
			rects.append(r)
			masks.append(m)
	return _merge_cell_strips(rects, masks)

## Merge touching same-mask, same-height cell rects into row strips. Coverage and each
## strip's depth line (end.y) are exactly the union of the parts, so the rx and y-sort
## tile tests see identical geometry from ~10x fewer candidates on uniform floors.
static func _merge_cell_strips(rects: Array[Rect2], masks: PackedInt32Array) -> Array:
	if rects.size() < 2:
		return [rects, masks]
	var rows := {}
	for i in rects.size():
		var key := "%d|%.3f|%.3f" % [masks[i], rects[i].position.y, rects[i].end.y]
		if not rows.has(key):
			rows[key] = []
		rows[key].append(i)
	var out_rects: Array[Rect2] = []
	var out_masks := PackedInt32Array()
	for key in rows:
		var idxs: Array = rows[key]
		idxs.sort_custom(func(a, b): return rects[a].position.x < rects[b].position.x)
		var cur: Rect2 = rects[idxs[0]]
		var m := masks[idxs[0]]
		for j in range(1, idxs.size()):
			var r: Rect2 = rects[idxs[j]]
			if r.position.x <= cur.end.x + 0.001:
				cur = cur.merge(r)
			else:
				out_rects.append(cur)
				out_masks.append(m)
				cur = r
		out_rects.append(cur)
		out_masks.append(m)
	return [out_rects, out_masks]

## Re-enable SDF collision on culled occluders/tileset layers a light's mask matches again.
func restore_unculled(gx_masks: Dictionary) -> void:
	_gx_masks = gx_masks
	if _sdf_culled.is_empty() and _ts_culled.is_empty():
		return
	var restore: Array = []
	for occ in _sdf_culled:
		if not is_instance_valid(occ):
			restore.append(occ)
		elif not _gx_masks.has(occ.occluder_light_mask):
			occ.sdf_collision = true
			restore.append(occ)
	for occ in restore:
		_sdf_culled.erase(occ)
	var ts_done: Array = []
	for ts in _ts_culled:
		var layers: Dictionary = _ts_culled[ts]
		var back: Array = []
		for l in layers:
			if l >= ts.get_occlusion_layers_count():
				back.append(l)
			elif not _gx_masks.has(ts.get_occlusion_layer_light_mask(l)):
				ts.set_occlusion_layer_sdf_collision(l, true)
				back.append(l)
		for l in back:
			layers.erase(l)
		if layers.is_empty():
			ts_done.append(ts)
	for ts in ts_done:
		_ts_culled.erase(ts)

## Rebuild the caster cache if dirty; with pregate, first live-compare the mask set
## (editor) so a drifted tileset marks the cache dirty first.
func ensure_fresh(root: Node, lights: Array, pregate: bool) -> void:
	if pregate and not _occ_dirty:
		refresh_mask_set()
	if _occ_dirty:
		_rebuild_occ_cache(root, lights)

## Publish the global exempt rects only when they changed.
func _publish_gx(packed: PackedVector4Array) -> void:
	if packed == _gx_packed:
		return
	_gx_packed = packed
	RenderingServer.global_shader_parameter_set("lit_gx_count", packed.size())
	RenderingServer.global_shader_parameter_set("lit_gx_rect0",
			packed[0] if packed.size() > 0 else Vector4())
	RenderingServer.global_shader_parameter_set("lit_gx_rect1",
			packed[1] if packed.size() > 1 else Vector4())
	RenderingServer.global_shader_parameter_set("lit_gx_rect2",
			packed[2] if packed.size() > 2 else Vector4())
	RenderingServer.global_shader_parameter_set("lit_gx_rect3",
			packed[3] if packed.size() > 3 else Vector4())

func publish_gx_empty() -> void:
	_publish_gx(PackedVector4Array())

## Recompute the distinct-mask set from the cached nodes (editor live edits only).
## Tileset masks are cache-derived, so they are compared against a live snapshot here;
## any drift (mask edit, missed changed signal) marks the cache dirty to self-heal.
func refresh_mask_set() -> void:
	_occ_mask_set.clear()
	_occ_masks_seen = false
	for entry in _occ_nodes:
		if is_instance_valid(entry[0]) \
				and (entry[0].sdf_collision or _sdf_culled.has(entry[0])):
			_occ_mask_set[entry[0].occluder_light_mask] = true
	for entry in _occ_layers:
		if not is_instance_valid(entry[0]) or entry[0].tile_set == null \
				or entry[6] != _ts_layer_masks(entry[0].tile_set):
			_occ_dirty = true
		for m in entry[5]:
			_occ_mask_set[m] = true
	for m in _occ_mask_set:
		if int(m) != 1:
			_occ_masks_seen = true
			break

## Per-occlusion-layer light masks of a tileset (-1 for non-SDF layers): the snapshot
## cached per layer entry and compared live for editor edits.
func _ts_layer_masks(ts: TileSet) -> PackedInt32Array:
	var masks := PackedInt32Array()
	for l in ts.get_occlusion_layers_count():
		if ts.get_occlusion_layer_sdf_collision(l) or _ts_culled.get(ts, {}).has(l):
			masks.append(ts.get_occlusion_layer_light_mask(l))
		else:
			masks.append(-1)
	return masks

## True if some excluding light exempts an occluder with this mask/owner.
func _exempt_for_any(m: int, owner_id: int) -> bool:
	if owner_id != 0 and _excl_owners.has(owner_id):
		return true
	for s in _excl_smasks:
		if (m & int(s)) == 0:
			return true
	return false

## Reuse an ImageTexture when the image size is unchanged; reallocate on resize.
## ImageTexture.get_size() is Vector2 while Image.get_size() is Vector2i, so compare
## in a single type.
func _make_or_update(tex: ImageTexture, img: Image) -> ImageTexture:
	if tex == null or tex.get_size() != Vector2(img.get_size()):
		return ImageTexture.create_from_image(img)
	tex.update(img)
	return tex
