extends RefCounted
class_name LitShaderLibrary

## Receiver variant matrix source of truth; nothing else may name a receiver shader path or define.
## Also the one home of the light-node contracts (the enums below): the node scripts
## alias them (const ShadowAlgorithm = LitShaderLibrary.ShadowAlgorithm) so the
## public per-node names keep working.

enum BlendMode { ADD, SUBTRACT }

## Sizing mode for a light's cookie texture.
enum TextureSizeMode { NATIVE, FIT_RANGE }

## Per-light shadow algorithm. The order is a wire format: light_packer.gd packs it
## into flags bits 3-4 of the light's data row and the shader decodes it there, and
## the registry derives active_algos (bit 0 = CONE_TRACED, bit 1 = STOCHASTIC) from
## it for the variant swap. Append new algorithms; never reorder.
enum ShadowAlgorithm { RAYMARCHED, CONE_TRACED, STOCHASTIC }

const F_SELF_EXCL := 1
const F_YSORT := 2
const F_CONE := 4
const F_STOCH := 8
const F_GX := 16
const F_MASKS := 32
const F_RX := 64

const TIER_MASK := F_SELF_EXCL | F_YSORT

# Row order is the canonical variant-name token order; absent_token names an axis's absence.
const AXES := [
	{"flag": F_CONE, "define": "LIT_SHADOW_CONE", "token": "cone", "scope": "activity"},
	{"flag": F_STOCH, "define": "LIT_SHADOW_STOCH", "token": "stoch", "scope": "activity"},
	{"flag": F_SELF_EXCL, "define": "LIT_SELF_EXCLUSION", "token": "", "absent_token": "fast", "scope": "tier"},
	{"flag": F_YSORT, "define": "LIT_YSORT", "token": "ysort", "scope": "tier"},
	{"flag": F_GX, "define": "LIT_OCC_GX", "token": "gx", "scope": "activity"},
	{"flag": F_MASKS, "define": "LIT_OCC_MASKS", "token": "mask", "scope": "activity"},
	{"flag": F_RX, "define": "LIT_OCC_RX", "token": "rx", "scope": "node"},
]

const ENTRY_PATHS := {
	0: "res://addons/lit/shaders/receiver/lit_receiver_fast.gdshader",
	F_SELF_EXCL: "res://addons/lit/shaders/receiver/lit_receiver.gdshader",
	F_SELF_EXCL | F_YSORT: "res://addons/lit/shaders/receiver/lit_receiver_ysort.gdshader",
}

const COMMON_INCLUDE_PATH := "res://addons/lit/shaders/receiver/lit_receiver_common.gdshaderinc"
# Preloaded so exports ship the includes (.gdshaderinc files are not exported as dependencies).
const COMMON_INCLUDE: ShaderInclude = preload("res://addons/lit/shaders/receiver/lit_receiver_common.gdshaderinc")
const INCLUDE_UNITS: Array[ShaderInclude] = [
	preload("res://addons/lit/shaders/receiver/include/lit_header.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_exclusion.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_ysort.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_wsdf.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_shadow_march.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_shadow_cone.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_shadow_stoch.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_brdf.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_shade.gdshaderinc"),
	preload("res://addons/lit/shaders/receiver/include/lit_fragment.gdshaderinc"),
]

# Derived caches only; editor script reloads wipe statics, everything rebuilds on miss.
static var _receivers := {}
static var _flags_by_id := {}
static var _version := ""
static var _warmed := {}  # precompiled work list; dev builds log builds outside it


static func _log_miss(flags: int) -> void:
	if OS.is_debug_build() and not _warmed.is_empty() and not _warmed.has(flags):
		push_warning("Lit: shader variant %d compiled outside the precompiled work list" % flags)


static func resolve(tier: int, node_flags: int, activity: int) -> int:
	return _prune(tier | node_flags | activity)


static func _prune(flags: int) -> int:
	if flags & F_YSORT != 0:
		flags |= F_SELF_EXCL
	if flags & (F_MASKS | F_RX) != 0:
		flags &= ~F_GX
	return flags


static func get_receiver(flags: int) -> Shader:
	flags = _prune(flags)
	var sh: Shader = _receivers.get(flags)
	if sh == null:
		_log_miss(flags)
		sh = Shader.new()
		sh.code = source_for(flags)
		_receivers[flags] = sh
		_flags_by_id[sh.get_instance_id()] = flags
	return sh


static func source_for(flags: int) -> String:
	var src := "shader_type canvas_item;\nrender_mode unshaded;\n// lit_flags=%d lit_version=%s\n" \
			% [flags, _get_version()]
	for axis in AXES:
		if flags & axis.flag != 0:
			src += "#define %s\n" % axis.define
	return src + "#include \"%s\"\n" % COMMON_INCLUDE_PATH


static func flags_of(shader: Shader) -> int:
	if shader == null:
		return -1
	var id := shader.get_instance_id()
	var cached = _flags_by_id.get(id)
	if cached != null:
		return cached
	var flags := -1
	if shader.resource_path.is_empty():
		var at := shader.code.find("// lit_flags=")
		if at != -1:
			flags = shader.code.substr(at + 13).get_slice(" ", 0).to_int()
	else:
		flags = flags_from_path(shader.resource_path)
	_flags_by_id[id] = flags
	return flags


static func variant_name(flags: int) -> String:
	var n := "lit_receiver"
	for axis in AXES:
		if flags & axis.flag != 0:
			if axis.token != "":
				n += "_" + axis.token
		elif axis.get("absent_token", "") != "":
			n += "_" + axis.get("absent_token", "")
	return n


static func flags_from_path(path: String) -> int:
	if not path.begins_with("res://addons/lit/shaders/"):
		return -1
	var fname := path.get_file()
	if not fname.ends_with(".gdshader"):
		return -1
	return flags_from_variant_name(fname.get_basename())


## Inverse of variant_name; -1 for anything that isn't a canonical variant name.
static func flags_from_variant_name(name: String) -> int:
	if not name.begins_with("lit_receiver"):
		return -1
	var flags := 0
	for axis in AXES:
		if axis.get("absent_token", "") != "":
			flags |= axis.flag
	for token in name.substr(12).split("_", false):
		var matched := false
		for axis in AXES:
			if token == axis.token:
				flags |= axis.flag
				matched = true
			elif token == axis.get("absent_token", ""):
				flags &= ~axis.flag
				matched = true
		if not matched:
			return -1
	return flags


static func all_variant_flags() -> Array[int]:
	var seen := {}
	for combo in 1 << AXES.size():
		var flags := 0
		for i in AXES.size():
			if combo & (1 << i) != 0:
				flags |= AXES[i].flag
		seen[_prune(flags)] = true
	var out: Array[int] = []
	for f in seen:
		out.append(f)
	out.sort()
	return out


## Shared _validate_property body for the light nodes: show only the dials the
## selected algorithm reads. source_prop is "source_radius" on point/spot lights and
## "source_angle" on directionals.
static func validate_light_property(property: Dictionary, algorithm: int, source_prop: String) -> void:
	if property.name == source_prop:
		if algorithm == ShadowAlgorithm.RAYMARCHED:
			property.usage &= ~PROPERTY_USAGE_EDITOR
	elif property.name == "shadow_samples" or property.name == "shadow_jitter":
		if algorithm != ShadowAlgorithm.STOCHASTIC:
			property.usage &= ~PROPERTY_USAGE_EDITOR


static func _get_version() -> String:
	if _version.is_empty():
		var cfg := ConfigFile.new()
		_version = str(cfg.get_value("plugin", "version", "0")) \
				if cfg.load("res://addons/lit/plugin.cfg") == OK else "0"
	return _version
