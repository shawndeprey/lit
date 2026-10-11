extends RefCounted

## Runtime receiver-material pool. Nodes whose receiver materials are identical in
## content share one runtime material, keyed by the authored variant tier plus every
## content uniform the shader declares - scalars and texture slots alike (the values
## ARE the identity: keys are compared, never just hashed). Entries are created as
## duplicates, so authored resources are never mutated. Nodes needing per-node
## uniforms (self rects, rx bounds, y-sort) leave the pool through to_unique, as does
## a user's make_material_unique(). Runtime only; the editor keeps authored materials
## and its RS-clone live path.

# Uniforms the runtime drives per node (self rects, y-sort depth, rx mask and bounds).
# Never part of the content key: a pooled entry holds them empty by construction
# (nodes needing per-node values detach first), so writes of them on a shared entry
# only ever converge members to the same healed state and must not drift the key.
# Every other uniform the shader declares is content - including the texture slots
# (emissive / metallic / roughness / ao maps): two materials with equal scalars but
# different maps must never share an entry.
const DRIVEN_PARAMS: Array[String] = [
	"self_rect_count", "self_rects", "ysort_on", "ysort_y",
	"rx_mask", "rx_bounds", "rx_bound_count",
]

static var _entries := {}   # key String -> [ShaderMaterial, refcount]
static var _by_mat := {}    # ShaderMaterial -> key String
static var _content_names := PackedStringArray()   # parsed once from the receiver source
static var _defaults_by_shader := {}               # shader instance id -> {name: declared default}


## The content uniforms, in key order: every per-material `uniform` the receiver
## includes declare, minus DRIVEN_PARAMS. Parsed from the include source the shader
## library ships (not asked of the RenderingServer, which reports nothing under the
## headless dummy renderer), so a uniform added to the shader is keyed automatically.
static func content_params() -> PackedStringArray:
	if _content_names.is_empty():
		var re := RegEx.create_from_string("^\\s*(global\\s+)?uniform\\s+\\w+\\s+(\\w+)")
		var seen := {}
		var units: Array = LitShaderLibrary.INCLUDE_UNITS.duplicate()
		units.append(LitShaderLibrary.COMMON_INCLUDE)
		for inc in units:
			for line in (inc as ShaderInclude).code.split("\n"):
				var m := re.search(line)
				if m == null or not m.get_string(1).is_empty():
					continue
				var n := m.get_string(2)
				if not DRIVEN_PARAMS.has(n) and not seen.has(n):
					seen[n] = true
					_content_names.append(n)
		_content_names.sort()
	return _content_names


## Declared defaults of the content uniforms on `shader`, read once per shader.
static func _defaults_of(shader: Shader) -> Dictionary:
	var id := shader.get_instance_id()
	var defaults = _defaults_by_shader.get(id)
	if defaults == null:
		defaults = {}
		var rid := shader.get_rid()
		for n in content_params():
			defaults[n] = RenderingServer.shader_get_parameter_default(rid, n)
		_defaults_by_shader[id] = defaults
	return defaults


## Content key: tier of the authored variant plus every content uniform's value,
## serialized so lookup equality is a full value comparison. Unset uniforms read as
## null but render as the shader default (and duplicate() materializes them), so
## normalize null to the default - otherwise an original and its pool duplicate key
## apart.
static func _key_of(mat: ShaderMaterial, override_param := "", override_value = null) -> String:
	var shader := mat.shader
	var defaults := _defaults_of(shader)
	var vals := [LitShaderLibrary.flags_of(shader) & LitShaderLibrary.TIER_MASK]
	for p in content_params():
		var v = override_value if p == override_param else mat.get_shader_parameter(p)
		if v == null:
			v = defaults.get(p)
		vals.append(_key_value(v))
	return var_to_str(vals)


# Textures key by identity (the same resource, not equal pixels); ints as floats so a
# whole float and an int of the same value never key apart.
static func _key_value(v):
	if v is Object:
		return "obj:%d" % (v as Object).get_instance_id()
	if v is int:
		return float(v)
	return v


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
	# Driven (or undeclared) params write straight to the shared entry: convergent by
	# construction, never identity-changing.
	if not content_params().has(param):
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


## Whether `name` is part of the content key (as opposed to a runtime-driven per-node
## uniform, or a uniform the receiver does not declare). Bench/diagnostic use.
static func is_key_param(name: String) -> bool:
	return content_params().has(name)


## Read-only view of the live entries: key -> {"material": ShaderMaterial, "refs": int}.
## Bench/diagnostic use; never mutate the returned materials.
static func snapshot() -> Dictionary:
	var out := {}
	for key in _entries:
		out[key] = {"material": _entries[key][0], "refs": _entries[key][1]}
	return out
