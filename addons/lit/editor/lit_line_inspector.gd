@tool
extends EditorInspectorPlugin

## The "Add Path" button at the top of the LitLineLight2D inspector's Line group: a
## categorized menu of starter shapes (lit_line_shapes.gd). Picking one adds a Path2D
## child sized to the light's length, sets `closed` to match the shape (undoable) and
## selects the path for editing. The button hides while the light has a Path2D child.

const Shapes := preload("res://addons/lit/editor/lit_line_shapes.gd")
const FALLBACK_SIZE := 128.0

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is LitLineLight2D


func _parse_group(object: Object, group: String) -> void:
	var light := object as LitLineLight2D
	if group != "Line" or light == null:
		return
	for child in light.get_children():
		if child is Path2D:
			return

	var btn := MenuButton.new()
	btn.text = "Add Path"
	btn.flat = false
	btn.icon = EditorInterface.get_base_control().get_theme_icon("Path2D", "EditorIcons")
	var popup := btn.get_popup()
	for cat in Shapes.CATEGORIES:
		var sub := PopupMenu.new()
		sub.id_pressed.connect(_on_pick.bind(sub, light))
		for shape in cat[1]:
			sub.add_item(shape)
		popup.add_submenu_node_item(cat[0], sub)
	add_custom_control(btn)


func _on_pick(id: int, menu: PopupMenu, light: LitLineLight2D) -> void:
	var shape := menu.get_item_text(menu.get_item_index(id))
	var path := Shapes.make_path(shape, light.length if light.length > 0.0 else FALLBACK_SIZE)
	var owner_node: Node = light.owner if light.owner != null else light
	undo_redo.create_action("Add Line Light Path")
	undo_redo.add_do_method(light, "add_child", path, true)
	undo_redo.add_do_method(path, "set_owner", owner_node)
	undo_redo.add_do_property(light, "closed", Shapes.is_closed(shape))
	undo_redo.add_do_reference(path)
	undo_redo.add_undo_method(light, "remove_child", path)
	undo_redo.add_undo_property(light, "closed", light.closed)
	undo_redo.commit_action()
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(path)
