extends RefCounted
class_name LitReceiverHelper

## The one implementation of receiver driving, shared by LitSprite2D,
## LitTileMapLayer, and the registry's bare-receiver driver: pack the node's exempt
## boxes (owned occluders + tilemap cell rects), pick the variant tier, and land the
## live params, deduped through a per-node DriveState.
##
## `mat` is the live target (an RS clone in the editor, the node's own de-shared
## material at runtime); callers resolve it first, and a material change resets the
## memo here so every param re-lands on the new material. Returns whether a full
## drive ran (false from the unchanged-inputs fast path), so callers can skip their
## own per-drive param re-lands.

# Callers without tilemap cell rects pass this instead of allocating an empty array
# per frame.
const NO_TILE_RECTS: Array = []


## Per-node dedup memo, created once per driven node and mutated in place.
class DriveState:
	var packed := PackedVector4Array()
	var count := -1
	var ys_on := false
	var ys_y := 0.0
	var live_mat: ShaderMaterial = null
	var stale := false  # an owned occluder was freed; the caller's cache should rebuild
	# Fast-path memo: the drive inputs as of the last full drive. Callers set `dirty`
	# when an input the snapshot can't see changes (self_shadow proxy writes).
	var dirty := true
	var version := -1
	var node_flags := -1
	var node_xf := Transform2D()
	var occluders_ref = null
	var tile_rects_ref = null
	var occ_inside: Array = []
	var occ_xfs: Array = []
	var occ_polys: Array = []


static func drive(node: Node2D, mat: ShaderMaterial, occluders: Array,
		tile_rects: Array, allow_ysort: bool, node_flags: int, state: DriveState) -> bool:
	if mat == null or mat.shader == null:
		return false
	if mat != state.live_mat:
		# Fresh material (first frame, runtime de-share, or a recreated editor clone
		# after the save-time script reload): drop the memos so every param re-lands.
		state.live_mat = mat
		state.packed = PackedVector4Array()
		state.count = -1
		state.ys_on = false
		state.ys_y = 0.0
		state.dirty = true

	# Runtime fast path: same activity version, same flags, and every input transform
	# unchanged means the packed rects, tier, and params are already landed. Occluder
	# lists and tile rects are compared by identity; callers build a fresh array on
	# every cache rebuild. The editor always drives, keeping live previews exact.
	if not state.dirty and not Engine.is_editor_hint() \
			and state.version == LitLightRegistry.activity_version \
			and state.node_flags == node_flags \
			and _inputs_unchanged(node, occluders, tile_rects, state):
		return false

	# One canvas-space box (min.xy | max.xy) per owned occluder / tile cell rect. The
	# shader takes up to 4 boxes; extras are unioned into the last. Count 0 turns the
	# exclusion off.
	var rects: Array[Rect2] = []
	var node_xf := node.global_transform
	for tile_rect in tile_rects:
		rects.append(node_xf * tile_rect)
	for n in occluders:
		if not is_instance_valid(n):
			state.stale = true
			continue
		var occ := n as LightOccluder2D
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
		packed[i] = Vector4(rects[i].position.x, rects[i].position.y,
				rects[i].end.x, rects[i].end.y)
	if packed != state.packed or rects.size() != state.count:
		state.packed = packed
		state.count = rects.size()
		mat.set_shader_parameter("self_rects", packed)
		mat.set_shader_parameter("self_rect_count", rects.size())

	# Y-sort participation: occluder-owning receivers only (never tilemaps), depth =
	# footprint bottom.
	var ys_on := false
	var ys_y := 0.0
	if allow_ysort and LitLightRegistry.ysort_enabled and not rects.is_empty():
		ys_on = true
		ys_y = rects[0].end.y
		for r in rects:
			ys_y = maxf(ys_y, r.end.y)

	# Full shader only while the self-exclusion march can actually run, the y-sort
	# variant only while participating. The material param decides, so the flag also
	# works when set directly on a hand-assigned receiver material. Materials not on a
	# Lit variant (custom shaders) keep their params but are never re-tiered.
	var wants_full: bool = rects.size() > 0 and mat.get_shader_parameter("self_shadow") != true
	var flags: int = LitShaderLibrary.flags_of(mat.shader)
	if flags >= 0:
		var tier := (LitShaderLibrary.F_SELF_EXCL | LitShaderLibrary.F_YSORT) if ys_on \
				else (LitShaderLibrary.F_SELF_EXCL if wants_full else 0)
		var wanted := LitShaderLibrary.resolve(tier, node_flags,
				LitLightRegistry.activity_flags)
		if flags != wanted:
			mat.shader = LitShaderLibrary.get_receiver(wanted)

	# After the swap, so the params land on a shader declaring them.
	if ys_on != state.ys_on or ys_y != state.ys_y:
		state.ys_on = ys_on
		state.ys_y = ys_y
		mat.set_shader_parameter("ysort_on", ys_on)
		mat.set_shader_parameter("ysort_y", ys_y)

	_snapshot(node, occluders, tile_rects, node_flags, state)
	return true


static func _inputs_unchanged(node: Node2D, occluders: Array, tile_rects: Array,
		state: DriveState) -> bool:
	if not is_same(occluders, state.occluders_ref) or not is_same(tile_rects, state.tile_rects_ref):
		return false
	if node.global_transform != state.node_xf:
		return false
	for i in occluders.size():
		var o = occluders[i]
		if not is_instance_valid(o):
			return false
		var inside: bool = o.is_inside_tree()
		if inside != state.occ_inside[i]:
			return false
		if inside and (o.global_transform != state.occ_xfs[i] or o.occluder != state.occ_polys[i]):
			return false
	return true


static func _snapshot(node: Node2D, occluders: Array, tile_rects: Array,
		node_flags: int, state: DriveState) -> void:
	state.dirty = false
	state.version = LitLightRegistry.activity_version
	state.node_flags = node_flags
	state.node_xf = node.global_transform
	state.occluders_ref = occluders
	state.tile_rects_ref = tile_rects
	state.occ_inside.resize(occluders.size())
	state.occ_xfs.resize(occluders.size())
	state.occ_polys.resize(occluders.size())
	for i in occluders.size():
		var o = occluders[i]
		var inside: bool = is_instance_valid(o) and o.is_inside_tree()
		state.occ_inside[i] = inside
		state.occ_xfs[i] = o.global_transform if inside else Transform2D()
		state.occ_polys[i] = o.occluder if inside else null
