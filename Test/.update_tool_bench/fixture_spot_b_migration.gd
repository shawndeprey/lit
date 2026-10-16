extends "res://addons/lit/editor/lit_update_tool/migrations/migration.gd"


func _init() -> void:
	to_version = LitShaderLibrary._get_version()
	target_class = &"LitSpotLight2D"
	renames = {&"mid_cone": &"spot_angle"}
