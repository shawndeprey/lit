@tool
extends EditorInspectorPlugin

## Notes on the receiver inspectors (LitSprite2D, LitAnimatedSprite2D, LitTileMapLayer)
## for exports the project settings make inert: the Blinn-Phong specular pair under
## PBR, the PBR pair under Blinn-Phong, and Shadow Steps while Shadow Step Scaling is
## on. Each note names the setting responsible and sits above the first property of
## its set; the properties themselves render read-only through the nodes'
## _validate_property (LitReceiverHelper.validate_receiver_property). The plugin
## re-lists the selected receivers' properties when one of those settings changes, so
## the notes follow the setting without reselecting the node.


static func handles(object: Object) -> bool:
	return object is LitSprite2D or object is LitAnimatedSprite2D or object is LitTileMapLayer


func _can_handle(object: Object) -> bool:
	return handles(object)


func _parse_property(_object: Object, _type: Variant.Type, name: String,
		_hint_type: PropertyHint, _hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if not LitReceiverHelper.GATED_SETS.has(name):
		return false
	var reason := LitReceiverHelper.inactive_reason(name)
	if reason != "":
		add_custom_control(_note(reason))
	return false  # the property itself still renders (read-only)


func _note(text: String) -> Control:
	var base := EditorInterface.get_base_control()
	var row := HBoxContainer.new()
	var icon := TextureRect.new()
	icon.texture = base.get_theme_icon("NodeWarning", "EditorIcons")
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(icon)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", base.get_theme_color("warning_color", "Editor"))
	row.add_child(label)
	return row
