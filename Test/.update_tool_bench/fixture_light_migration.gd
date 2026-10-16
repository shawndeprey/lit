extends "res://addons/lit/editor/lit_update_tool/migrations/migration.gd"


func _init() -> void:
	to_version = LitShaderLibrary._get_version()
	target_class = &"LitPointLight2D"
	renames = {&"legacy_glow": &"energy", &"shadow_filter": &"shadow_samples"}
