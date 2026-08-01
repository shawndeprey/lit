extends RefCounted

## Exclusion classification and mask tiers: which lights carry per-light exempt
## rects, which occluder masks are globally excluded (gx), and the per-combo
## exempt rect lists the packer reads.

var _gx_masks := {}              # occluder masks excluded from every shadow-casting light
var _excl_info := {}             # light -> owner id, for lights with exclusions this frame
var _excl_smasks := {}           # shadow_masks of those lights
var _excl_owners := {}           # owner ids of those lights
var _excl_combos := {}           # "smask_owner" -> [smask, owner id], distinct this frame
var _excl_lists := {}            # combo key -> [count, union Rect2, 4 packed rects]
var _prev_combo_sig := ""
var _prev_excl_masks := PackedInt32Array()
var _prev_excl_owners := PackedInt32Array()


# --- Facade seam ----------------------------------------------------------------
# Dictionary accessors return the live references; the facade passes them onward as
# explicit module arguments (the data spine), never mutates them itself.

func gx_masks() -> Dictionary:
	return _gx_masks


func smasks() -> Dictionary:
	return _excl_smasks


func owners() -> Dictionary:
	return _excl_owners


func has_exclusions() -> bool:
	return not _excl_info.is_empty()


func info() -> Dictionary:
	return _excl_info


func lists() -> Dictionary:
	return _excl_lists


func clear_frame() -> void:
	_excl_info.clear()
	_excl_smasks.clear()
	_excl_owners.clear()
	_excl_combos.clear()
	_gx_masks.clear()


## Split exclusions into tiers and set masks_active. Occluder masks no shadow-casting
## light matches land in _gx_masks (global tier, no per-light state); only occluders
## that cast for SOME lights make a light carry per-light exclusions. Skipped outright
## (beyond the light loop in refresh) until a light or SDF-casting occluder shows a
## non-default mask or an exclusion toggle, so mask-free scenes pay nothing here.
## Returns whether any light carries per-light exclusions this frame.
func classify(lights: Array, smask_union: int, occ_mask_set: Dictionary,
		scope_ids: Dictionary, scope_occ_masks: Dictionary) -> bool:
	var masks_frame := false
	for m in occ_mask_set:
		if (int(m) & smask_union) == 0:
			_gx_masks[m] = true
	for entry in lights:
		var node = entry[0]
		if not is_instance_valid(node) or not node.enabled or not node.shadow_enabled:
			continue
		var owner_id := 0
		if node.exclude_scene_occluders:
			var scope: Node = node.owner if node.owner != null else node.get_parent()
			owner_id = scope_ids.get(scope, 0)
			if owner_id != 0 and not _scope_has_caster(owner_id, scope_occ_masks):
				owner_id = 0
		var has_excl := owner_id != 0
		if not has_excl:
			var smask: int = node.shadow_mask
			for m in occ_mask_set:
				if (int(m) & smask) == 0 and (int(m) & smask_union) != 0:
					has_excl = true
					break
		if has_excl:
			var smask: int = node.shadow_mask
			_excl_info[node] = owner_id
			_excl_smasks[smask] = true
			if owner_id != 0:
				_excl_owners[owner_id] = true
			_excl_combos["%d_%d" % [smask, owner_id]] = [smask, owner_id]
			masks_frame = true
	return masks_frame

## True if the scope owns an SDF caster that isn't already globally excluded.
func _scope_has_caster(owner_id: int, scope_occ_masks: Dictionary) -> bool:
	var sm: Dictionary = scope_occ_masks.get(owner_id, {})
	for m in sm:
		if not _gx_masks.has(m):
			return true
	return false

## Rebuild the exempt lists only when the pack bytes, per-rect masks/owners, or the
## combo set changed since the last rebuild.
func maybe_rebuild_lists(pack_same: bool, occ_rects: Array[Rect2], occ_masks: PackedInt32Array,
		occ_owners: PackedInt32Array) -> void:
	# The lists depend on per-rect masks/owners too, not just the rect bytes: a mask
	# edit can move a rect between lists while the pack stays identical.
	var combo_sig := str(_excl_combos.keys())
	if not pack_same or combo_sig != _prev_combo_sig \
			or occ_masks != _prev_excl_masks or occ_owners != _prev_excl_owners:
		_prev_combo_sig = combo_sig
		_prev_excl_masks = occ_masks.duplicate()
		_prev_excl_owners = occ_owners.duplicate()
		_rebuild_excl_lists(occ_rects, occ_masks, occ_owners)

## Per-combo exempt rect lists (4 slots, extras unioned into the last) over the gathered
## occluder rects; valid until the pack, per-rect masks/owners, or the combo set change.
func _rebuild_excl_lists(occ_rects: Array[Rect2], occ_masks: PackedInt32Array, occ_owners: PackedInt32Array) -> void:
	_excl_lists.clear()
	for key in _excl_combos:
		var smask: int = _excl_combos[key][0]
		var owner_id: int = _excl_combos[key][1]
		var rects: Array[Rect2] = []
		for i in occ_rects.size():
			if (occ_masks[i] & smask) == 0 or (owner_id != 0 and occ_owners[i] == owner_id):
				rects.append(occ_rects[i])
		if rects.is_empty():
			continue
		while rects.size() > 4:
			rects[3] = rects[3].merge(rects.pop_back())
		var union := rects[0]
		var packed := PackedVector4Array()
		packed.resize(4)
		for i in rects.size():
			union = union.merge(rects[i])
			packed[i] = Vector4(rects[i].position.x, rects[i].position.y, rects[i].end.x, rects[i].end.y)
		_excl_lists[key] = [rects.size(), union, packed]
