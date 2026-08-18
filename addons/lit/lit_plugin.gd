@tool
extends EditorPlugin

## Lit editor plugin.
##
## Responsibilities:
##  - Register the `lit_*` global shader parameters so receiver shaders compile in the
##    editor and in exported builds (see the registration block below for why).
##  - Add the runtime `LitManager` autoload that drives the per-frame gather.
##  - Persist the `lit/*` project settings (the `lit/render/lighting_model` selector and the
##    `lit/quality/*` adaptive shadow march knobs) that the receiver shader reads.
##  - Provide the "Make Selected Nodes Lit" tool and editor-live preview, driving the
##    shared gather against the 2D editor viewport (see _process).
##
## Node registration is implicit: every Lit node script uses `class_name`, so they
## already appear in the Create Node dialog.

const AUTOLOAD_NAME := "LitManager"
const AUTOLOAD_PATH := "res://addons/lit/runtime/lit_manager.gd"

const TOOL_MENU_ITEM := "Make Selected Nodes Lit"
const TOOL_MENU_PRECOMPILE := "Generate Lit Precompile Config"

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")
const LitPostInspectorScript := preload("res://addons/lit/editor/lit_post_inspector.gd")
const LitPrecompileConfigScript := preload("res://addons/lit/editor/lit_precompile_config.gd")
const LitExportPluginScript := preload("res://addons/lit/editor/lit_export_plugin.gd")

# Editor-live refresh cadence. Polling a few times a second relights the viewport when
# a light moves, a property changes, or the 2D editor camera pans or zooms, without
# running the game. Polling is smaller and more robust than per-node transform/property
# signals, and it's the only thing that catches editor-camera pan/zoom, which the
# shadow and position math depend on.
const EDITOR_REFRESH_INTERVAL := 1.0 / 30.0

var _registry: LitLightRegistry
var _refresh_accum := 0.0
var _warm_pending: Array[int] = []
var _post_inspector: EditorInspectorPlugin
var _export_plugin: EditorExportPlugin


# --- Lifecycle ---------------------------------------------------------------
#
# _enter_tree and _exit_tree fire on every editor open and close, not just on
# enable/disable, so writing project.godot from them churns the file. The split:
#
#  - Persistent project.godot entries (the autoload, `shader_globals/*`, and the
#    `lit/*` settings) are written in _enter_tree but guarded, so they're written
#    only when missing, and removed only in _disable_plugin. A normal close never touches
#    the file, yet the entries self-heal if they ever go missing.
#  - Session state (live RenderingServer globals, the tool menu, the editor-live refresh)
#    lives in _enter_tree / _exit_tree and touches no file.

func _enter_tree() -> void:
	_add_live_globals()         # session-only RenderingServer state, not serialized
	_persist_globals()          # guarded: writes project.godot only if a key is missing
	_persist_project_settings() # guarded: same, for the lit/* settings
	_ensure_autoload()          # guarded: adds only if not already registered
	add_tool_menu_item(TOOL_MENU_ITEM, _make_selected_nodes_lit)
	add_tool_menu_item(TOOL_MENU_PRECOMPILE, _generate_precompile_config)
	# The "Add Effect" button on the LitPostProcess inspector.
	_post_inspector = LitPostInspectorScript.new()
	_post_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_post_inspector)
	# Packs lit_precompile.cfg into exports (see editor/lit_export_plugin.gd).
	_export_plugin = LitExportPluginScript.new()
	add_export_plugin(_export_plugin)
	# Editor-side gather driver; the autoload covers runtime but doesn't run here.
	_registry = LitLightRegistryScript.new()
	# Silent background warm so first-session editor tier swaps never pay a compile.
	_warm_pending = LitShaderLibrary.all_variant_flags()
	set_process(true)

func _exit_tree() -> void:
	# Session teardown only; no project.godot writes here.
	set_process(false)
	_registry = null
	LitLightRegistryScript.editor_release_live()
	remove_tool_menu_item(TOOL_MENU_ITEM)
	remove_tool_menu_item(TOOL_MENU_PRECOMPILE)
	remove_inspector_plugin(_post_inspector)
	_post_inspector = null
	remove_export_plugin(_export_plugin)
	_export_plugin = null
	_remove_live_globals()

func _disable_plugin() -> void:
	# Real deactivation, not just an editor close: drop the persistent entries.
	remove_autoload_singleton(AUTOLOAD_NAME)
	_unpersist_globals()
	_unpersist_project_settings()

## Register the runtime autoload, but only if it isn't already in project.godot.
## add_autoload_singleton rewrites and saves the file, so guarding it keeps a normal
## editor open from churning project.godot.
func _ensure_autoload() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)

# --- Editor-live preview -----------------------------------------------------
#
# Autoloads don't run in the editor, so the plugin is the edit-time driver for the same
# refresh() the runtime LitManager uses. It packs against the 2D editor viewport, whose
# canvas transform reflects the editor camera, so lights and their shadows stay aligned
# with what's displayed.
#
# A throttled poll keeps the viewport redrawing while the plugin is active; that's the
# live-preview tradeoff. Idling when nothing changed would be a later optimization.

func _process(delta: float) -> void:
	if not _warm_pending.is_empty():
		for i in 2:
			if _warm_pending.is_empty():
				break
			LitShaderLibrary.get_receiver(_warm_pending.pop_back())
	_refresh_accum += delta
	if _refresh_accum < EDITOR_REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	# Mirror the runtime LitManager: publish the selected lighting model so the editor
	# preview reflects the lit/render/lighting_model setting. The autoload that does this
	# at runtime doesn't run in the editor, so without this the preview would always be
	# Phong (the global's default) regardless of the setting.
	RenderingServer.global_shader_parameter_set("lit_lighting_model",
		int(ProjectSettings.get_setting("lit/render/lighting_model", 0)))
	var ysort := bool(ProjectSettings.get_setting("lit/render/y_sorting", false))
	RenderingServer.global_shader_parameter_set("lit_ysort_enabled", ysort)
	RenderingServer.global_shader_parameter_set("lit_ysort_band",
		maxf(float(ProjectSettings.get_setting("lit/render/y_sort_smoothing", 12.0)), 0.01))
	if _registry == null or EditorInterface.get_edited_scene_root() == null:
		return  # no scene open / nothing to light
	_registry.set_ysort(ysort)
	# Mirror the runtime manager's CPU-side stochastic sample cap for the preview.
	_registry.shadow_samples_max = clampi(
		int(ProjectSettings.get_setting("lit/quality/shadow_samples_max", 32)), 1, 32)
	_registry.refresh(get_tree(), EditorInterface.get_editor_viewport_2d(),
		EditorInterface.get_edited_scene_root(), self)

# --- "Make Selected Nodes Lit" tool ------------------------------------------
#
# Batch-converts the selected 2D nodes into Lit receivers by assigning each a fresh
# receiver ShaderMaterial. Works on any CanvasItem (Sprite2D, AnimatedSprite2D,
# TileMapLayer, Polygon2D, MeshInstance2D, ...) since `material` lives on CanvasItem;
# tilemaps are first-class world geometry, so the tool has to cover them too. Each node
# gets its own material so the per-instance uniforms (receiver_mask, emissive_strength)
# stay independent. For nodes that draw a single Texture2D, the texture is wrapped in a
# CanvasTexture so the normal/specular slots appear. Lives under Project > Tools, and is
# undoable as one action.
#
# This is the batch path for existing art; LitSprite2D is the from-scratch path. It also
# sidesteps the Quick Load friction, since a node's `material` slot only accepts a
# Material, never a `.gdshader`.

func _make_selected_nodes_lit() -> void:
	var targets: Array[CanvasItem] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		var ci := node as CanvasItem
		if ci != null:
			targets.append(ci)
	if targets.is_empty():
		push_warning("Make Selected Nodes Lit: select one or more 2D (CanvasItem) nodes first.")
		return

	var shader := load(LitShaderLibrary.ENTRY_PATHS[0]) as Shader
	var lit_sprite_script := load("res://addons/lit/nodes/lit_sprite_2d.gd") as Script
	var undo := get_undo_redo()
	undo.create_action(TOOL_MENU_ITEM)
	for ci in targets:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		undo.add_do_property(ci, "material", mat)
		undo.add_undo_property(ci, "material", ci.material)

		# Do-method Callables validate at add time.
		if ci is Sprite2D and ci.get_script() == null:
			undo.add_do_property(ci, "script", lit_sprite_script)
			undo.add_undo_property(ci, "script", null)
			undo.add_do_method(self, "_start_converted_sprite", ci)

		# If the node draws a single Texture2D (Sprite2D, Polygon2D, MeshInstance2D, ...),
		# wrap it in a CanvasTexture so the normal/specular slots appear. `texture` isn't
		# on the CanvasItem base, so the dynamic get() returns null for nodes without it
		# (TileMapLayer, AnimatedSprite2D), which then just get the material.
		var tex = ci.get("texture")
		if tex is Texture2D and not (tex is CanvasTexture):
			var ct := CanvasTexture.new()
			ct.diffuse_texture = tex
			undo.add_do_property(ci, "texture", ct)
			undo.add_undo_property(ci, "texture", tex)
	undo.commit_action()

# set_script runs _init but not the ready hook (the node is already in the tree).
func _start_converted_sprite(node: Node) -> void:
	if node.has_method("_lit_ready"):
		node.call("_lit_ready")

# --- Precompile config tool ---------------------------------------------------
#
# "Generate Lit Precompile Config" scans the project's saved scenes for actual Lit
# usage and writes res://lit_precompile.cfg; while that file exists, the startup
# precompiler builds exactly that list instead of the full variant matrix. Deleting
# the file restores the full build. The scan itself lives in
# editor/lit_precompile_config.gd.

func _generate_precompile_config() -> void:
	var result: Dictionary = LitPrecompileConfigScript.generate()
	if not result.saved:
		_popup_tool_dialog("Lit Precompile Config", "Could not write res://lit_precompile.cfg; see the Output log.")
		return
	var variants: PackedStringArray = result.variants
	var shaders: Array = result.shaders
	var text: String
	if variants.is_empty() and shaders.is_empty():
		text = "Scanned %d scenes and found no Lit usage.\nWrote an empty res://lit_precompile.cfg, so the precompiler will build nothing.\nDelete the file to restore full builds." \
				% result.scenes
	else:
		text = "Scanned %d scenes.\nPrecompile list: %d of %d receiver variants, plus %d shader files.\n\nWrote res://lit_precompile.cfg (packed into exports automatically); delete it to return to full builds.\nRegenerate after adding lights, masks, or post effects." \
				% [result.scenes, variants.size(), result.full, shaders.size()]
	_popup_tool_dialog("Lit Precompile Config", text)

func _popup_tool_dialog(title: String, text: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	EditorInterface.get_base_control().add_child(dlg)
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	dlg.popup_centered()

# --- Global shader parameter registration -------------------------------------
#
# A receiver shader declares `global uniform ...` names, and those names must exist in
# the engine's shader-globals registry before the shader compiles or it errors out in
# the editor. We register them two ways:
#
#  1. Persisted into ProjectSettings under `shader_globals/*` (project.godot), via the
#     guarded _persist_globals in _enter_tree. The RenderingServer reads these at engine
#     init, so the names exist with no load-order race in the editor or in exports.
#
#  2. Added live via RenderingServer for the current editor session, because
#     project.godot's shader_globals are only parsed at startup; without this the very
#     first plugin-enable wouldn't expose the names until a restart.
#
# On the next launch the persisted entries auto-register and the live-add is skipped
# (we check the existing list first), so there's no double-add. The lit_tile_* and
# lit_shadow_* entries feed the tiled light culling and adaptive shadow march.

## ProjectSettings serialization defs: each name plus the Dictionary stored under
## `shader_globals/<name>`. Built at call time because the values aren't constant
## expressions.
func _ps_global_defs() -> Array:
	return [
		{
			"name": "lit_light_data",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{"name": "lit_light_count", "def": {"type": "int", "value": 0}},
		{"name": "lit_viewport_size", "def": {"type": "vec2", "value": Vector2.ZERO}},
		{"name": "lit_canvas_scale", "def": {"type": "float", "value": 1.0}},
		{
			"name": "lit_world_sdf",
			"def": {"type": "sampler2D", "value": "", "filter": "linear", "repeat": "disable"},
		},
		{"name": "lit_wsdf_basis", "def": {"type": "vec4", "value": Vector4()}},
		{"name": "lit_wsdf_origin", "def": {"type": "vec2", "value": Vector2.ZERO}},
		{"name": "lit_ambient_color", "def": {"type": "color", "value": Color(1, 1, 1, 1)}},
		{"name": "lit_ambient_energy", "def": {"type": "float", "value": 1.0}},
		{"name": "lit_shadow_steps_max", "def": {"type": "int", "value": 64}},
		{"name": "lit_shadow_step_scaling", "def": {"type": "bool", "value": false}},
		{"name": "lit_tile_size", "def": {"type": "int", "value": 64}},
		{"name": "lit_tile_grid", "def": {"type": "ivec2", "value": Vector2i.ZERO}},
		{"name": "lit_directional_count", "def": {"type": "int", "value": 0}},
		{"name": "lit_lighting_model", "def": {"type": "int", "value": 0}},
		{
			"name": "lit_tile_headers",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{
			"name": "lit_tile_indices",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{
			# Sampled (not texelFetch), so it filters linearly.
			"name": "lit_cookie_atlas",
			"def": {"type": "sampler2D", "value": "", "filter": "linear", "repeat": "disable"},
		},
		{"name": "lit_ysort_enabled", "def": {"type": "bool", "value": false}},
		{"name": "lit_ysort_band", "def": {"type": "float", "value": 12.0}},
		{
			"name": "lit_occ_data",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{
			"name": "lit_occ_headers",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{
			"name": "lit_occ_indices",
			"def": {"type": "sampler2D", "value": "", "filter": "nearest", "repeat": "disable"},
		},
		{"name": "lit_gx_count", "def": {"type": "int", "value": 0}},
		{"name": "lit_gx_rect0", "def": {"type": "vec4", "value": Vector4()}},
		{"name": "lit_gx_rect1", "def": {"type": "vec4", "value": Vector4()}},
		{"name": "lit_gx_rect2", "def": {"type": "vec4", "value": Vector4()}},
		{"name": "lit_gx_rect3", "def": {"type": "vec4", "value": Vector4()}},
	]

## RenderingServer live-add defs: name + GlobalShaderParameterType + default.
## `lit_ambient_color` uses COLOR to match the shader's `vec4 : source_color`.
func _rs_global_defs() -> Array:
	return [
		{
			"name": "lit_light_data",
			"type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D,
			"value": _placeholder_texture(),
		},
		{"name": "lit_light_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_viewport_size", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC2, "value": Vector2.ZERO},
		{"name": "lit_canvas_scale", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 1.0},
		{"name": "lit_world_sdf", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_wsdf_basis", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_wsdf_origin", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC2, "value": Vector2.ZERO},
		{"name": "lit_ambient_color", "type": RenderingServer.GLOBAL_VAR_TYPE_COLOR, "value": Color(1, 1, 1, 1)},
		{"name": "lit_ambient_energy", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 1.0},
		{"name": "lit_shadow_steps_max", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 64},
		{"name": "lit_shadow_step_scaling", "type": RenderingServer.GLOBAL_VAR_TYPE_BOOL, "value": false},
		{"name": "lit_tile_size", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 64},
		{"name": "lit_tile_grid", "type": RenderingServer.GLOBAL_VAR_TYPE_IVEC2, "value": Vector2i.ZERO},
		{"name": "lit_directional_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_lighting_model", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_tile_headers", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_tile_indices", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_cookie_atlas", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_ysort_enabled", "type": RenderingServer.GLOBAL_VAR_TYPE_BOOL, "value": false},
		{"name": "lit_ysort_band", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 12.0},
		{"name": "lit_occ_data", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_occ_headers", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_occ_indices", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": _placeholder_texture()},
		{"name": "lit_gx_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_gx_rect0", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_gx_rect1", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_gx_rect2", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_gx_rect3", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
	]

## Persist the shader_globals into project.godot. Idempotent: writes only the missing
## keys and saves only if something changed, so a normal editor open with the keys
## already present rewrites nothing.
func _persist_globals() -> void:
	var ps_changed := false
	for d in _ps_global_defs():
		var key: String = "shader_globals/" + str(d.name)
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, d.def)
			ps_changed = true
	if ps_changed:
		ProjectSettings.save()

## Remove the persisted shader_globals from project.godot. Called from
## _disable_plugin only (deactivating the plugin removes its features).
func _unpersist_globals() -> void:
	var ps_changed := false
	for d in _ps_global_defs():
		var key: String = "shader_globals/" + str(d.name)
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			ps_changed = true
	if ps_changed:
		ProjectSettings.save()

## The lit/* project settings, surfaced in Project Settings with typed hints so they get
## a proper editor (a dropdown, a checkbox, a 1..256 range slider). LitManager reads these
## at runtime and republishes them as shader globals; the editor preview (_process) mirrors
## the render model so authoring reflects the toggle.
func _project_setting_defs() -> Array:
	return [
		{
			# 0 = Blinn-Phong (ambient + Lambert + half-vector specular), 1 = PBR
			# (metallic-roughness Cook-Torrance). Must match LIT_MODEL_* in the receiver
			# shader and LitManager.LightingModel.
			#
			# The hint_string is the dropdown's only place to convey the tradeoffs: Godot has
			# no per-option tooltip or description for custom project settings, so a short
			# inline summary rides on each label. Labels are comma-delimited, so the inline
			# bullets use ` · ` (never commas) to avoid splitting a label in two.
			"name": "lit/render/lighting_model",
			"default": 0,
			"info": {
				"name": "lit/render/lighting_model",
				"type": TYPE_INT,
				"hint": PROPERTY_HINT_ENUM,
				"hint_string": "Blinn–Phong (BP) — faster · uses only the CanvasTexture · stylized highlights,Physically Based Rendering (PBR) — realistic surfaces · adds metallic/roughness/AO · slight perf cost",
			},
		},
		{
			# Runtime SDF culling of occluders excluded from every light's shadow_mask.
			# The canvas SDF also feeds GPUParticles2D collision; turn this off if
			# excluded occluders must keep colliding with particles (they then fall back
			# to in-shader exemption).
			"name": "lit/render/occluder_mask_sdf_culling",
			"default": true,
			"info": {"name": "lit/render/occluder_mask_sdf_culling", "type": TYPE_BOOL},
		},
		{
			# Top-down shadow depth by occluder footprint bottoms; not Godot y-sort.
			"name": "lit/render/y_sorting",
			"default": false,
			"info": {"name": "lit/render/y_sorting", "type": TYPE_BOOL},
		},
		{
			# Launch-time variant precompile takeover; marker-skipped once caches are warm.
			"name": "lit/startup/precompile_shaders",
			"default": true,
			"info": {"name": "lit/startup/precompile_shaders", "type": TYPE_BOOL},
		},
		{
			# Custom precompile screen title; empty uses "Lit Shaders Precompiling".
			"name": "lit/startup/precompile_title",
			"default": "",
			"info": {"name": "lit/startup/precompile_title", "type": TYPE_STRING},
		},
		{
			# Show the variant being compiled below the progress bar.
			"name": "lit/startup/precompile_verbose",
			"default": true,
			"info": {"name": "lit/startup/precompile_verbose", "type": TYPE_BOOL},
		},
		{
			# Compile behind the running game (no takeover) with a floating progress box.
			"name": "lit/startup/precompile_async",
			"default": false,
			"info": {"name": "lit/startup/precompile_async", "type": TYPE_BOOL},
		},
		{
			"name": "lit/startup/precompile_async_position",
			"default": 8,
			"info": {
				"name": "lit/startup/precompile_async_position",
				"type": TYPE_INT,
				"hint": PROPERTY_HINT_ENUM,
				"hint_string": "Top Left,Top Center,Top Right,Center Left,Center,Center Right,Bottom Left,Bottom Center,Bottom Right",
			},
		},
		{
			# Fade half-width in world pixels around the depth boundary.
			"name": "lit/render/y_sort_smoothing",
			"default": 12.0,
			"info": {
				"name": "lit/render/y_sort_smoothing",
				"type": TYPE_FLOAT,
				"hint": PROPERTY_HINT_RANGE,
				"hint_string": "0,64,0.5,or_greater",
			},
		},
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
		{
			# Scene-wide cap on each light's stochastic shadow_samples, applied at pack
			# time; the global quality floor/ceiling for the Stochastic algorithm.
			"name": "lit/quality/shadow_samples_max",
			"default": 32,
			"info": {
				"name": "lit/quality/shadow_samples_max",
				"type": TYPE_INT,
				"hint": PROPERTY_HINT_RANGE,
				"hint_string": "1,32,1",
			},
		},
		{
			# Max edge (pixels) of the cookie atlas; cookies that don't fit are skipped.
			"name": "lit/quality/cookie_atlas_max_size",
			"default": 2048,
			"info": {
				"name": "lit/quality/cookie_atlas_max_size",
				"type": TYPE_INT,
				"hint": PROPERTY_HINT_RANGE,
				"hint_string": "256,8192,64",
			},
		},
	]

## Persist the lit/* settings into project.godot, guarded like _persist_globals.
## set_initial_value + add_property_info run every enable so the inspector keeps the
## default and the typed editor even when the key already exists.
func _persist_project_settings() -> void:
	var changed := false
	var defs := _project_setting_defs()
	for d in defs:
		if not ProjectSettings.has_setting(d.name):
			ProjectSettings.set_setting(d.name, d.default)
			changed = true
		ProjectSettings.set_initial_value(d.name, d.default)
		ProjectSettings.add_property_info(d.info)
	# Display order follows defs order; without this, any setting changed from its
	# default persists into project.godot and jumps to file order in the dialog.
	var order := ProjectSettings.get_order(defs[0].name)
	for d in defs:
		ProjectSettings.set_order(d.name, order)
		order += 1
	if changed:
		ProjectSettings.save()

## Remove the persisted lit/* settings. Called from _disable_plugin only.
func _unpersist_project_settings() -> void:
	var changed := false
	for d in _project_setting_defs():
		if ProjectSettings.has_setting(d.name):
			ProjectSettings.set_setting(d.name, null)
			changed = true
	if changed:
		ProjectSettings.save()

## Add the globals to the RenderingServer for this session, skipping any already present
## (for example auto-registered from persisted project.godot at engine init).
## RenderingServer state isn't serialized, so this touches no file.
func _add_live_globals() -> void:
	var existing := RenderingServer.global_shader_parameter_get_list()
	for g in _rs_global_defs():
		if not existing.has(g.name):
			RenderingServer.global_shader_parameter_add(g.name, g.type, g.value)

## Remove the session's RenderingServer globals. On a normal editor close the
## persisted entries re-register at the next launch's engine init; on plugin
## disable, _unpersist_globals also drops the persisted copies. No file write.
func _remove_live_globals() -> void:
	var existing := RenderingServer.global_shader_parameter_get_list()
	for g in _rs_global_defs():
		if existing.has(g.name):
			RenderingServer.global_shader_parameter_remove(g.name)

## A 1x1 float texture used only as the sampler global's default value; the manager
## overrides it with real light data every frame.
func _placeholder_texture() -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)
