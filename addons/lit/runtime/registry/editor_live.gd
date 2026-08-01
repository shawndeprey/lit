extends RefCounted

## Editor live materials: per-node clones bound at the RenderingServer level carry
## all live-driven state, so the authored material (what scene saves persist) never
## mutates. Statics: one clone map serves both editor registry instances.

# In the editor, node.material is the authored layer: the base receiver shader plus the
# user's params, which is exactly what scene saves should persist. All live-driven state
# (variant swaps, self rects, y-sort, rx params) goes to a per-node clone bound at the
# RenderingServer level, where the scene serializer never sees it. These statics are
# derived caches, so the save-time script reload that wipes them self-heals next refresh.
static var _live_mats := {}          # CanvasItem -> [clone, base]
static var _live_uniforms := {}      # variant flags -> PackedStringArray of authored uniforms
const LIVE_PARAMS := {"self_rects": true, "self_rect_count": true, "ysort_on": true,
		"ysort_y": true, "rx_mask": true, "rx_bounds": true, "rx_bound_count": true,
		"has_specular_map": true}


static func live_material(ci: CanvasItem, base: ShaderMaterial) -> ShaderMaterial:
	if base == null or base.shader == null:
		return base
	var entry: Array = _live_mats.get(ci, [])
	if entry.is_empty() or entry[1] != base:
		entry = [base.duplicate(), base]
		_live_mats[ci] = entry
	RenderingServer.canvas_item_set_material(ci.get_canvas_item(), entry[0].get_rid())
	return entry[0]

static func _authored_uniforms(sh: Shader) -> PackedStringArray:
	var key := LitShaderLibrary.flags_of(sh)
	if not _live_uniforms.has(key):
		var names := PackedStringArray()
		for u in sh.get_shader_uniform_list():
			if not LIVE_PARAMS.has(u.name):
				names.append(u.name)
		_live_uniforms[key] = names
	return _live_uniforms[key]

## Mirror authored params (inspector edits land on the base) into each clone and
## re-assert the RenderingServer binding, which the engine re-points at the property
## material on scene ops. Clones of freed nodes or swapped-out materials are dropped.
static func sync() -> void:
	var stale: Array = []
	for ci in _live_mats:
		var base: ShaderMaterial = _live_mats[ci][1]
		if not is_instance_valid(ci) or (ci.material as ShaderMaterial) != base \
				or base.shader == null or LitShaderLibrary.flags_of(base.shader) < 0:
			stale.append(ci)
			continue
		var clone: ShaderMaterial = _live_mats[ci][0]
		for uname in _authored_uniforms(clone.shader):
			clone.set_shader_parameter(uname, base.get_shader_parameter(uname))
		RenderingServer.canvas_item_set_material(ci.get_canvas_item(), clone.get_rid())
	for ci in stale:
		if is_instance_valid(ci):
			var mat := ci.material as Material
			RenderingServer.canvas_item_set_material(ci.get_canvas_item(),
					mat.get_rid() if mat != null else RID())
		_live_mats.erase(ci)

## Rebind every clone's node to its property material and forget the clones; the
## plugin calls this on teardown so a disabled plugin leaves no RS overrides behind.
static func release_all() -> void:
	for ci in _live_mats:
		if is_instance_valid(ci):
			var mat := ci.material as Material
			RenderingServer.canvas_item_set_material(ci.get_canvas_item(),
					mat.get_rid() if mat != null else RID())
	_live_mats.clear()
