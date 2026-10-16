extends "res://addons/lit/editor/lit_update_tool/migrations/migration.gd"


func _init() -> void:
	to_version = "1.1.4"
	target_class = &"LitSpotLight2D"
	renames = {&"old_cone": &"mid_cone"}
