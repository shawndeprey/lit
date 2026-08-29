extends RefCounted

## Runtime receiver-material pool. Nodes whose receiver materials are identical in
## content share one runtime material, keyed by the authored variant tier plus the
## full uniform tuple (the values ARE the identity: keys are compared, never just
## hashed). Entries are created as duplicates, so authored resources are never
## mutated. Nodes needing per-node uniforms (self rects, rx bounds, y-sort) leave
## the pool through to_unique, as does a user's make_material_unique(). Runtime
## only; the editor keeps authored materials and its RS-clone live path.

# The uniform tuple defining content identity, in key order: user-content params
# only. Driven params (self rects, rx_mask, y-sort) are deliberately excluded - a
# pooled material holds them empty by construction (nodes needing per-node values
# detach first), so writes of them on a shared entry only ever converge members to
# the same healed state and must not drift the key.
const KEY_PARAMS: Array[String] = [
	"emissive_strength", "receiver_mask", "self_shadow", "specular_strength",
	"specular_k", "has_specular_map", "metallic_value", "roughness_value",
	"shadow_steps", "shadow_min_step", "footprint_shadow",
	"directional_horizontal_scale",
]

static var _entries := {}   # key String -> [ShaderMaterial, refcount]
static var _by_mat := {}    # ShaderMaterial -> key String


## Content key: tier of the authored variant plus every KEY_PARAMS value, serialized
## so lookup equality is a full value comparison. Unset uniforms read as null but
## render as the shader default (and duplicate() materializes them), so normalize
## null to the default - otherwise an original and its pool duplicate key apart.
static func _key_of(mat: ShaderMaterial, override_param := "", override_value = null) -> String:
	var vals := [LitShaderLibrary.flags_of(mat.shader) & LitShaderLibrary.TIER_MASK]
	for p in KEY_PARAMS:
		var v = override_value if p == override_param else mat.get_shader_parameter(p)
		if v == null:
			v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), p)
		vals.append(v)
	return var_to_str(vals)


## Pooled material for `mat`'s content, creating the entry (as a duplicate) on first
## acquire. Adds one reference.
static func acquire(mat: ShaderMaterial) -> ShaderMaterial:
	var key := _key_of(mat)
	var entry: Array = _entries.get(key, [])
	if entry.is_empty():
		entry = [mat.duplicate(), 0]
		_entries[key] = entry
		_by_mat[entry[0]] = key
	entry[1] += 1
	return entry[0]


## Move one reference of pooled `mat` to the entry matching its content with `param`
## set to `value` (a per-node tweak through the proxies re-keys instead of bleeding
## to poolmates). Returns the material to assign; same-key re-keys return `mat`.
static func rekey(mat: ShaderMaterial, param: String, value) -> ShaderMaterial:
	# Non-key (driven) params write straight to the shared entry: convergent by
	# construction, never identity-changing.
	if not KEY_PARAMS.has(param):
		mat.set_shader_parameter(param, value)
		return mat
	var key := _key_of(mat, param, value)
	if _by_mat.get(mat, "") == key:
		return mat
	var entry: Array = _entries.get(key, [])
	if entry.is_empty():
		var dup: ShaderMaterial = mat.duplicate()
		dup.set_shader_parameter(param, value)
		entry = [dup, 0]
		_entries[key] = entry
		_by_mat[dup] = key
	entry[1] += 1
	release(mat)
	return entry[0]


## Detach: a private duplicate of `mat`, releasing the pooled reference. Unpooled
## materials come back unchanged.
static func to_unique(mat: ShaderMaterial) -> ShaderMaterial:
	if not _by_mat.has(mat):
		return mat
	var dup: ShaderMaterial = mat.duplicate()
	release(mat)
	return dup


## Drop one reference; the entry is freed when the last holder releases.
static func release(mat: ShaderMaterial) -> void:
	var key = _by_mat.get(mat)
	if key == null:
		return
	var entry: Array = _entries[key]
	entry[1] -= 1
	if entry[1] <= 0:
		_entries.erase(key)
		_by_mat.erase(mat)


static func is_pooled(mat) -> bool:
	return mat != null and _by_mat.has(mat)


static func stats() -> Dictionary:
	var refs := 0
	for e in _entries.values():
		refs += e[1]
	return {"entries": _entries.size(), "refs": refs}
