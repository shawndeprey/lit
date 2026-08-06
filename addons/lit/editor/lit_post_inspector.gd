@tool
extends EditorInspectorPlugin

## The "Add Effect" button at the top of the LitPostProcess inspector: a categorized
## menu of the built-in passes, grouped by pipeline stage in canonical chain order.
## Picking one adds that effect node as a child at its canonical pipeline position
## (undoable) and selects it; child order is the draw order, so reorder freely after.
## Effects already in the chain are greyed out; duplicates can still be made by hand.
##
## User scripts with a class_name extending LitPostEffect appear under a Custom
## category automatically, and "New Custom Effect..." generates a blank-canvas
## script + screen-reading shader at a chosen path, then drops the new pass into
## the chain.

const CATEGORIES := [
	["Exposure", [
		["Auto Exposure", "res://addons/lit/nodes/post/lit_post_auto_exposure.gd"],
	]],
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

const NEW_CUSTOM_ID := 9001

const SCRIPT_TEMPLATE := """@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name %s

## Describe your effect here.

const SHADER := preload("%s")


func _shader() -> Shader:
	return SHADER

# Mirror exported knobs to shader uniforms: {"uniform_name": "property_name"}. Give
# each exported property a setter that calls apply_params().
#func _param_map() -> Dictionary:
#	return {}

# Default insertion slot in the chain (built-in passes use 10..200, default 1000 =
# end). Draw order is the child order; this only picks where Add Effect drops it.
#func _rank() -> int:
#	return 1000

# For effects that track data over time (auto exposure, trails, ...); runs only
# while the effect is parented to a LitPostProcess.
#func _effect_process(delta: float) -> void:
#	pass
"""

const SHADER_TEMPLATE := """shader_type canvas_item;

// Starter post shader: reads the frame as processed by the passes above this one.
// The placeholder body inverts the frame so a fresh effect is visibly working;
// replace it with your effect. Add uniforms here and mirror them from exported
// script properties via _param_map().
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	COLOR = vec4(1.0 - col, 1.0);
}
"""

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
	var categories := CATEGORIES.duplicate()
	var custom := _custom_effect_entries()
	if not custom.is_empty():
		categories.append(["Custom", custom])
	for cat in categories:
		var sub := PopupMenu.new()
		sub.id_pressed.connect(_on_pick.bind(sub, host))
		for item in cat[1]:
			var id: int = sub.item_count
			sub.add_item(item[0], id)
			sub.set_item_metadata(id, item[1])
			sub.set_item_disabled(id, present.has(item[1]))
		popup.add_submenu_node_item(cat[0], sub)
	popup.add_separator()
	popup.add_item("New Custom Effect...", NEW_CUSTOM_ID)
	popup.id_pressed.connect(_on_root_pick.bind(host))
	add_custom_control(btn)


## [display name, script path] for every global class extending LitPostEffect that
## isn't one of the built-in passes.
func _custom_effect_entries() -> Array:
	var classes := ProjectSettings.get_global_class_list()
	var by_name := {}
	for c in classes:
		by_name[String(c["class"])] = c
	var entries := []
	for c in classes:
		if String(c["path"]).begins_with("res://addons/lit/"):
			continue
		var base := String(c["base"])
		while base != "" and base != "LitPostEffect" and by_name.has(base):
			base = String(by_name[base]["base"])
		if base == "LitPostEffect":
			entries.append([String(c["class"]), String(c["path"])])
	entries.sort()
	return entries


func _on_pick(id: int, menu: PopupMenu, host: LitPostProcess) -> void:
	var index := menu.get_item_index(id)
	var fx: Node = (load(menu.get_item_metadata(index)) as Script).new()
	fx.name = StringName(String(menu.get_item_text(index)).replace(" ", ""))
	_add_effect_node(host, fx)


func _on_root_pick(id: int, host: LitPostProcess) -> void:
	if id != NEW_CUSTOM_ID:
		return
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.gd", "GDScript")
	dialog.title = "New Custom Post Effect (script + shader are created together)"
	dialog.current_file = "my_effect.gd"
	dialog.file_selected.connect(_generate_custom.bind(host))
	EditorInterface.get_base_control().add_child(dialog)
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free())
	dialog.popup_centered_ratio(0.5)


## Write the starter script + shader at the chosen path, then add the new pass to the
## chain and open its script.
func _generate_custom(path: String, host: LitPostProcess) -> void:
	var base_name := path.get_file().get_basename().to_snake_case()
	base_name = base_name.validate_filename().replace(" ", "_")
	if base_name.is_empty() or base_name[0].is_valid_int():
		base_name = "fx_" + base_name
	var class_str := base_name.to_pascal_case()
	var script_path := path.get_base_dir().path_join(base_name + ".gd")
	var shader_path := path.get_base_dir().path_join(base_name + ".gdshader")

	for c in ProjectSettings.get_global_class_list():
		if String(c["class"]) == class_str and String(c["path"]) != script_path:
			push_error("Lit: class_name '%s' already exists (%s); pick another name." %
				[class_str, c["path"]])
			return
	if FileAccess.file_exists(shader_path) and not FileAccess.file_exists(script_path):
		push_error("Lit: %s already exists; pick another name or remove it first." % shader_path)
		return

	var shader_file := FileAccess.open(shader_path, FileAccess.WRITE)
	if shader_file == null:
		push_error("Lit: can't write %s" % shader_path)
		return
	shader_file.store_string(SHADER_TEMPLATE)
	shader_file.close()
	var script_file := FileAccess.open(script_path, FileAccess.WRITE)
	if script_file == null:
		push_error("Lit: can't write %s" % script_path)
		return
	script_file.store_string(SCRIPT_TEMPLATE % [class_str, shader_path])
	script_file.close()
	EditorInterface.get_resource_filesystem().scan()

	var script := load(script_path) as Script
	var fx: Node = script.new()
	fx.name = StringName(class_str)
	_add_effect_node(host, fx)
	EditorInterface.edit_resource(script)


func _add_effect_node(host: LitPostProcess, fx: Node) -> void:
	var owner_node: Node = host.owner if host.owner != null else host
	undo_redo.create_action("Add Post Effect")
	undo_redo.add_do_method(host, "add_effect", fx)
	undo_redo.add_do_method(fx, "set_owner", owner_node)
	undo_redo.add_do_reference(fx)
	undo_redo.add_undo_method(host, "remove_child", fx)
	undo_redo.commit_action()
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(fx)
