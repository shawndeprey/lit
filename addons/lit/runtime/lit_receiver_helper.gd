extends RefCounted
class_name LitReceiverHelper

## The one implementation of receiver driving, shared by LitSprite2D,
## LitTileMapLayer, and the registry's bare-receiver driver: pack the node's exempt
## boxes (owned occluders + tilemap cell rects), pick the variant tier, and land the
## live params, deduped through a per-node DriveState.
##
## `mat` is the live target (an RS clone in the editor, the node's own de-shared
## material at runtime); callers resolve it first, and a material change resets the
## memo here so every param re-lands on the new material.

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


static func drive(node: Node2D, mat: ShaderMaterial, occluders: Array,
		tile_rects: Array, allow_ysort: bool, node_flags: int, state: DriveState) -> void:
	if mat == null or mat.shader == null:
		return
	if mat != state.live_mat:
		# Fresh material (first frame, runtime de-share, or a recreated editor clone
		# after the save-time script reload): drop the memos so every param re-lands.
		state.live_mat = mat
		state.packed = PackedVector4Array()
		state.count = -1
		state.ys_on = false
		state.ys_y = 0.0

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
