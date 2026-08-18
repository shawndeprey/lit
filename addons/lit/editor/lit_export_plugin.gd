@tool
extends EditorExportPlugin

## Packs res://lit_precompile.cfg into every export when it exists: a loose .cfg is
## not a resource, so the exporter would otherwise strip it and shipped games would
## silently fall back to the full precompile.

const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")


func _get_name() -> String:
	return "LitPrecompileConfig"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var cfg_path: String = LitShaderPrecompilerScript.CONFIG_PATH
	if FileAccess.file_exists(cfg_path):
		add_file(cfg_path, FileAccess.get_file_as_bytes(cfg_path), false)
