extends "res://addons/lit/editor/lit_update_tool/migrations/migration.gd"


func _init() -> void:
	to_version = LitShaderLibrary._get_version()
	target_class = &"LitSprite2D"
	renames = {&"legacy_mask": &"receiver_mask"}
	removes = [&"legacy_emit"]


func apply(node: Node, stored: Dictionary, report: Array) -> bool:
	if not stored.has("legacy_emit"):
		return false
	node.set(&"emissive_strength", float(stored["legacy_emit"]) * 0.5)
	report.append("MIGRATED %s: legacy_emit %s -> emissive_strength %s"
			% [node.name, stored["legacy_emit"], node.get(&"emissive_strength")])
	return true
