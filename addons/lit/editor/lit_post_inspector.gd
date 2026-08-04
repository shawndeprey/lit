@tool
extends EditorInspectorPlugin

## The "Add Effect" button at the top of the LitPostProcess inspector: a categorized
## menu of the built-in passes, grouped by pipeline stage in canonical chain order.
## Picking one adds that effect node as a child (undoable) and selects it. Effects
## already in the chain are greyed out; duplicates can still be made by hand if wanted.

const CATEGORIES := [
	["Glow", [
		["Threshold", "res://addons/lit/nodes/post/lit_post_threshold.gd"],
		["Bloom", "res://addons/lit/nodes/post/lit_post_bloom.gd"],
		["Halation", "res://addons/lit/nodes/post/lit_post_halation.gd"],
	]],
	["Signal", [
		["Glitch", "res://addons/lit/nodes/post/lit_post_glitch.gd"],
	]],
	["Grade", [
		["Color Grade", "res://addons/lit/nodes/post/lit_post_color_grade.gd"],
		["LUT", "res://addons/lit/nodes/post/lit_post_lut.gd"],
	]],
	["Stylize", [
		["Pixelate", "res://addons/lit/nodes/post/lit_post_pixelate.gd"],
		["Posterize", "res://addons/lit/nodes/post/lit_post_posterize.gd"],
		["Edge Outline", "res://addons/lit/nodes/post/lit_post_outline.gd"],
		["Halftone", "res://addons/lit/nodes/post/lit_post_halftone.gd"],
		["Dither", "res://addons/lit/nodes/post/lit_post_dither.gd"],
	]],
	["Matte", [
		["Letterbox", "res://addons/lit/nodes/post/lit_post_letterbox.gd"],
	]],
	["Display", [
		["Lens Distortion", "res://addons/lit/nodes/post/lit_post_lens_distortion.gd"],
		["VHS", "res://addons/lit/nodes/post/lit_post_vhs.gd"],
		["CRT", "res://addons/lit/nodes/post/lit_post_crt.gd"],
		["Chromatic Aberration", "res://addons/lit/nodes/post/lit_post_aberration.gd"],
		["Light Leaks", "res://addons/lit/nodes/post/lit_post_light_leaks.gd"],
		["Film Grain", "res://addons/lit/nodes/post/lit_post_film_grain.gd"],
		["Vignette", "res://addons/lit/nodes/post/lit_post_vignette.gd"],
		["Focus", "res://addons/lit/nodes/post/lit_post_focus.gd"],
	]],
]

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is LitPostProcess


func _parse_begin(object: Object) -> void:
	var host := object as LitPostProcess
	var present := {}
	for child in host.get_children():
		if child is LitPostEffect and child.get_script() != null:
			present[child.get_script().resource_path] = true

	var btn := MenuButton.new()
	btn.text = "Add Effect"
	btn.flat = false
	btn.icon = EditorInterface.get_base_control().get_theme_icon("Add", "EditorIcons")
	var popup := btn.get_popup()
	for cat in CATEGORIES:
		var sub := PopupMenu.new()
		sub.id_pressed.connect(_on_pick.bind(sub, host))
		for item in cat[1]:
			var id: int = sub.item_count
			sub.add_item(item[0], id)
			sub.set_item_metadata(id, item[1])
			sub.set_item_disabled(id, present.has(item[1]))
		popup.add_submenu_node_item(cat[0], sub)
	add_custom_control(btn)


func _on_pick(id: int, menu: PopupMenu, host: LitPostProcess) -> void:
	var index := menu.get_item_index(id)
	var fx: Node = (load(menu.get_item_metadata(index)) as Script).new()
	fx.name = StringName(String(menu.get_item_text(index)).replace(" ", ""))
	var owner_node: Node = host.owner if host.owner != null else host
	undo_redo.create_action("Add Post Effect")
	undo_redo.add_do_method(host, "add_child", fx)
	undo_redo.add_do_method(fx, "set_owner", owner_node)
	undo_redo.add_do_reference(fx)
	undo_redo.add_undo_method(host, "remove_child", fx)
	undo_redo.commit_action()
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(fx)
