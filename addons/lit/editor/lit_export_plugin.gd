@tool
extends EditorExportPlugin

## Packs res://lit_precompile.cfg into every export when it exists: a loose .cfg is
## not a resource, so the exporter would otherwise strip it and shipped games would
## silently fall back to the full precompile. The export dialog warns when the file
## is missing or leaves out variants the saved scenes use.

const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const LitPrecompileConfigScript := preload("res://addons/lit/editor/lit_precompile_config.gd")
const OPTION_CHECK := "lit/check_precompile_config"

var _warning_key := ""
var _warning := ""


func _get_name() -> String:
	return "LitPrecompileConfig"


func _get_export_options(_platform: EditorExportPlatform) -> Array[Dictionary]:
	return [{"option": {"name": OPTION_CHECK, "type": TYPE_BOOL}, "default_value": true}]


func _get_export_option_warning(_platform: EditorExportPlatform, option: String) -> String:
	if option != OPTION_CHECK or get_export_preset() == null or not bool(get_option(OPTION_CHECK)):
		return ""
	return config_warning()


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var cfg_path: String = LitShaderPrecompilerScript.CONFIG_PATH
	if FileAccess.file_exists(cfg_path):
		add_file(cfg_path, FileAccess.get_file_as_bytes(cfg_path), false)
	var warning := config_warning() if bool(get_option(OPTION_CHECK)) else ""
	if warning != "":
		push_warning("Lit: " + warning)


## Why the precompile config is missing or stale, else "". The scan is cached until a
## scene, the config or the y-sort setting changes: the dialog asks on every refresh.
func config_warning() -> String:
	var cfg_path: String = LitShaderPrecompilerScript.CONFIG_PATH
	var scenes: Array[String] = []
	LitShaderPrecompilerScript._collect_scenes("res://", scenes)
	var key := "%s|%d" % [ProjectSettings.get_setting("lit/render/y_sorting", false),
			FileAccess.get_modified_time(cfg_path) if FileAccess.file_exists(cfg_path) else -1]
	for s in scenes:
		key += "|%s:%d" % [s, FileAccess.get_modified_time(s)]
	if key == _warning_key:
		return _warning
	_warning_key = key
	_warning = ""
	var tool := "Project > Tools > Generate Lit Precompile Config"
	if not FileAccess.file_exists(cfg_path):
		_warning = "No res://lit_precompile.cfg: players compile all %d Lit shader variants on first launch. Generate one with %s." \
				% [LitShaderPrecompilerScript.default_variant_flags().size(), tool]
		return _warning
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return _warning
	var gaps: Dictionary = LitPrecompileConfigScript.config_gaps(LitPrecompileConfigScript.scan(), cfg)
	var missing: int = gaps.variants.size() + gaps.shaders.size()
	if missing > 0:
		_warning = "res://lit_precompile.cfg leaves out %d shaders your scenes use, so they compile mid-game. Regenerate it with %s." \
				% [missing, tool]
	return _warning
