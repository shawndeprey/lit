@tool
extends EditorPlugin

const AUTOLOAD_NAME := "LitManager"
const AUTOLOAD_PATH := "res://addons/lit/runtime/lit_manager.gd"

const RECEIVER_SHADER_PATH := "res://addons/lit/shaders/lit_receiver.gdshader"
const TOOL_MENU_ITEM := "Make Selected Nodes Lit"

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")
const EDITOR_REFRESH_INTERVAL := 1.0 / 30.0

var _registry: LitLightRegistry
var _refresh_accum := 0.0

func _enter_tree() -> void:
	_add_live_globals()
	_persist_globals()
	_persist_quality_settings()
	_ensure_autoload()
	add_tool_menu_item(TOOL_MENU_ITEM, _make_selected_nodes_lit)
	_registry = LitLightRegistryScript.new()
	set_process(true)

func _exit_tree() -> void:
	set_process(false)
	_registry = null
	remove_tool_menu_item(TOOL_MENU_ITEM)
	_remove_live_globals()

func _disable_plugin() -> void:

	remove_autoload_singleton(AUTOLOAD_NAME)
	_unpersist_globals()
	_unpersist_quality_settings()

func _ensure_autoload() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)

func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum < EDITOR_REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	if _registry == null or EditorInterface.get_edited_scene_root() == null:
		return
	_registry.refresh(get_tree(), EditorInterface.get_editor_viewport_2d())

func _make_selected_nodes_lit() -> void:
	var targets: Array[CanvasItem] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		var ci := node as CanvasItem
		if ci != null:
			targets.append(ci)
	if targets.is_empty():
		push_warning("Make Selected Nodes Lit: select one or more 2D (CanvasItem) nodes first.")
		return

	var shader := load(RECEIVER_SHADER_PATH) as Shader
	var undo := get_undo_redo()
	undo.create_action(TOOL_MENU_ITEM)
	for ci in targets:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		undo.add_do_property(ci, "material", mat)
		undo.add_undo_property(ci, "material", ci.material)

		var tex = ci.get("texture")
		if tex is Texture2D and not (tex is CanvasTexture):
			var ct := CanvasTexture.new()
			ct.diffuse_texture = tex
			undo.add_do_property(ci, "texture", ct)
			undo.add_undo_property(ci, "texture", tex)
	undo.commit_action()

func _ps_global_defs() -> Array:
	return [
		{
			"name": "lit_light_data",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{"name": "lit_light_count", "def": {"type": "int", "value": 0}},
		{"name": "lit_viewport_size", "def": {"type": "vec2", "value": Vector2.ZERO}},
		{"name": "lit_ambient_color", "def": {"type": "color", "value": Color(1, 1, 1, 1)}},
		{"name": "lit_ambient_energy", "def": {"type": "float", "value": 1.0}},
		{"name": "lit_shadow_steps_max", "def": {"type": "int", "value": 64}},
		{"name": "lit_shadow_step_scaling", "def": {"type": "bool", "value": false}},
		{"name": "lit_tile_size", "def": {"type": "int", "value": 64}},
		{"name": "lit_tile_grid", "def": {"type": "ivec2", "value": Vector2i.ZERO}},
		{"name": "lit_directional_count", "def": {"type": "int", "value": 0}},
		{
			"name": "lit_tile_headers",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{
			"name": "lit_tile_indices",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
	]

func _rs_global_defs() -> Array:
	return [
		{
			"name": "lit_light_data",
			"type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D,
			"value": _placeholder_texture(),
		},
		{"name": "lit_light_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_viewport_size", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC2, "value": Vector2.ZERO},
		{"name": "lit_ambient_color", "type": RenderingServer.GLOBAL_VAR_TYPE_COLOR, "value": Color(1, 1, 1, 1)},
		{"name": "lit_ambient_energy", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 1.0},
		{"name": "lit_shadow_steps_max", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 64},
		{"name": "lit_shadow_step_scaling", "type": RenderingServer.GLOBAL_VAR_TYPE_BOOL, "value": false},
		{"name": "lit_tile_size", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 64},
		{"name": "lit_tile_grid", "type": RenderingServer.GLOBAL_VAR_TYPE_IVEC2, "value": Vector2i.ZERO},
		{"name": "lit_directional_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_tile_headers", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_tile_indices", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
	]

func _persist_globals() -> void:
	var ps_changed := false
	for d in _ps_global_defs():
		var key: String = "shader_globals/" + str(d.name)
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, d.def)
			ps_changed = true
	if ps_changed:
		ProjectSettings.save()

func _unpersist_globals() -> void:
	var ps_changed := false
	for d in _ps_global_defs():
		var key: String = "shader_globals/" + str(d.name)
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			ps_changed = true
	if ps_changed:
		ProjectSettings.save()

func _quality_setting_defs() -> Array:
	return [
		{
			"name": "lit/quality/shadow_step_scaling",
			"default": false,
			"info": {"name": "lit/quality/shadow_step_scaling", "type": TYPE_BOOL},
		},
		{
			"name": "lit/quality/shadow_steps_max",
			"default": 64,
			"info": {
				"name": "lit/quality/shadow_steps_max",
				"type": TYPE_INT,
				"hint": PROPERTY_HINT_RANGE,
				"hint_string": "1,256,1",
			},
		},
	]

func _persist_quality_settings() -> void:
	var changed := false
	for d in _quality_setting_defs():
		if not ProjectSettings.has_setting(d.name):
			ProjectSettings.set_setting(d.name, d.default)
			changed = true
		ProjectSettings.set_initial_value(d.name, d.default)
		ProjectSettings.add_property_info(d.info)
	if changed:
		ProjectSettings.save()

func _unpersist_quality_settings() -> void:
	var changed := false
	for d in _quality_setting_defs():
		if ProjectSettings.has_setting(d.name):
			ProjectSettings.set_setting(d.name, null)
			changed = true
	if changed:
		ProjectSettings.save()

func _add_live_globals() -> void:
	var existing := RenderingServer.global_shader_parameter_get_list()
	for g in _rs_global_defs():
		if not existing.has(g.name):
			RenderingServer.global_shader_parameter_add(g.name, g.type, g.value)

func _remove_live_globals() -> void:
	var existing := RenderingServer.global_shader_parameter_get_list()
	for g in _rs_global_defs():
		if existing.has(g.name):
			RenderingServer.global_shader_parameter_remove(g.name)

func _placeholder_texture() -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)
