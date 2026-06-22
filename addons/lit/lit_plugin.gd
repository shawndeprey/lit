@tool
extends EditorPlugin

## Lit — EditorPlugin.
##
## Phase 1 responsibilities (plan §10, D1):
##  - Register the `lit_*` global shader parameters so receiver shaders compile
##    in-editor and in exported builds (see the global-registration block for why).
##  - Add the runtime `LitManager` autoload that drives the per-frame gather.
##
## Node registration is handled implicitly: every Lit node script uses
## `class_name`, so they already appear in the Create-Node dialog.
##
## Phase 4 adds the "Make Selected Sprites Lit" tool and editor-live preview
## (driving the shared gather against the 2D editor viewport — see _process).

const AUTOLOAD_NAME := "LitManager"
const AUTOLOAD_PATH := "res://addons/lit/runtime/lit_manager.gd"

const RECEIVER_SHADER_PATH := "res://addons/lit/shaders/lit_receiver.gdshader"
const TOOL_MENU_ITEM := "Make Selected Sprites Lit"

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")

# Editor-live refresh cadence (plan §8). Poll a few times a second so moving a
# light, editing a property, or panning/zooming the 2D editor camera relights the
# viewport without running the game. Polling (vs. per-node transform/property
# signals) is the smaller, more robust path and is the only thing that catches
# editor-camera pan/zoom — which the shadow/position math depends on.
const EDITOR_REFRESH_INTERVAL := 1.0 / 30.0

var _registry: LitLightRegistry
var _refresh_accum := 0.0


# --- Lifecycle ---------------------------------------------------------------
#
# The project.godot churn-on-close bug came from doing UNCONDITIONAL persistent
# writes in _enter_tree and removals in _exit_tree — but those fire on every editor
# open/close, not just enable/disable, so the file flip-flopped. The rule here:
#
#  - Persistent project.godot entries (autoload + `shader_globals/*`) are written
#    in _enter_tree but GUARDED (only when missing → no write in steady state), and
#    removed ONLY in _disable_plugin — never in _exit_tree. So a normal close never
#    touches the file, yet the entries self-heal if they ever go missing.
#  - Session state (live RenderingServer globals, tool menu, editor-live refresh)
#    lives in _enter_tree/_exit_tree and touches no file.

func _enter_tree() -> void:
	_add_live_globals()       # session-only (RenderingServer state, not serialized)
	_persist_globals()        # guarded: writes project.godot only if a key is missing
	_ensure_autoload()        # guarded: adds only if not already registered
	add_tool_menu_item(TOOL_MENU_ITEM, _make_selected_sprites_lit)
	# Editor-side gather driver (the autoload covers runtime; it doesn't run here).
	_registry = LitLightRegistryScript.new()
	set_process(true)


func _exit_tree() -> void:
	# Session teardown only — NO project.godot writes here (that was the churn bug).
	set_process(false)
	_registry = null
	remove_tool_menu_item(TOOL_MENU_ITEM)
	_remove_live_globals()


func _disable_plugin() -> void:
	# Real deactivation (not a mere editor close): drop the persistent entries.
	remove_autoload_singleton(AUTOLOAD_NAME)
	_unpersist_globals()


## Register the runtime autoload, but only if it isn't already in project.godot —
## add_autoload_singleton rewrites/saves the file, so guarding it keeps a normal
## editor open from churning project.godot.
func _ensure_autoload() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


# --- Editor-live preview (plan §8, §10) --------------------------------------
#
# Autoloads don't run in the editor, so the EditorPlugin is the edit-time driver
# for the same shared refresh() the runtime LitManager uses. It packs against the
# 2D editor viewport, whose canvas transform reflects the editor camera, so lights
# and their shadows stay aligned with what's displayed.
#
# A throttled poll keeps the viewport redrawing continuously while the plugin is
# active; that's the intended live-preview tradeoff. Dirty-tracking to idle when
# nothing changed is a post-v1 optimization (plan §13).

func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum < EDITOR_REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	if _registry == null or EditorInterface.get_edited_scene_root() == null:
		return  # no scene open / nothing to light
	_registry.refresh(get_tree(), EditorInterface.get_editor_viewport_2d())


# --- "Make Selected Sprites Lit" tool (plan §10) -----------------------------
#
# Batch-convert selected plain Sprite2D nodes into Lit receivers: assign a fresh
# receiver ShaderMaterial and wrap a plain texture in a CanvasTexture (so the
# normal/specular slots appear). Each sprite gets its OWN material so per-instance
# uniforms (receiver_mask, emissive_strength) stay independent. Lives under
# Project → Tools → "Make Selected Sprites Lit". Undoable as one action.
#
# This is the batch path for existing art; LitSprite2D is the from-scratch path.

func _make_selected_sprites_lit() -> void:
	var sprites: Array[Sprite2D] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		var s := node as Sprite2D
		if s != null:
			sprites.append(s)
	if sprites.is_empty():
		push_warning("Make Selected Sprites Lit: select one or more Sprite2D nodes first.")
		return

	var shader := load(RECEIVER_SHADER_PATH) as Shader
	var undo := get_undo_redo()
	undo.create_action(TOOL_MENU_ITEM)
	for s in sprites:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		undo.add_do_property(s, "material", mat)
		undo.add_undo_property(s, "material", s.material)

		# Only wrap a plain texture; leave a CanvasTexture (or an empty slot) alone.
		if s.texture != null and not (s.texture is CanvasTexture):
			var ct := CanvasTexture.new()
			ct.diffuse_texture = s.texture
			undo.add_do_property(s, "texture", ct)
			undo.add_undo_property(s, "texture", s.texture)
	undo.commit_action()


# --- Global shader parameter registration (D1) -------------------------------
#
# A receiver shader declares `global uniform ...` names; those names must exist
# in the engine's shader-globals registry *before* the shader compiles or it
# errors out in-editor. We register them two ways, for two reasons:
#
#  1. Persisted into ProjectSettings under `shader_globals/*` (project.godot), via
#     the guarded _persist_globals in _enter_tree (see Lifecycle above). The
#     RenderingServer reads these at engine init, so the names exist with zero
#     load-order race in both the editor and exported games.
#
#  2. Added live via RenderingServer for the *current* editor session (_enter_tree),
#     because project.godot's shader_globals are only parsed at startup — without
#     this, the very first plugin-enable wouldn't expose the names until a restart.
#
# On the next launch the persisted entries auto-register, and the live-add is
# skipped (we check the existing list first), so there's no double-add.

## ProjectSettings serialization defs: name + the Dictionary stored under
## `shader_globals/<name>`. Built at call time because the values aren't
## constant expressions.
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
		{"name": "lit_ambient_color", "type": RenderingServer.GLOBAL_VAR_TYPE_COLOR, "value": Color(1, 1, 1, 1)},
		{"name": "lit_ambient_energy", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 1.0},
	]


## Persist the shader_globals into project.godot (idempotent — writes only the
## missing keys, and saves only if something changed, so a normal editor open with
## the keys already present rewrites nothing).
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


## Add the globals to the RenderingServer for this session (skip any already
## present — e.g. auto-registered from persisted project.godot at engine init).
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


## A 1×1 float texture used only as the sampler global's default value; the
## manager overrides it with real light data every frame.
func _placeholder_texture() -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)
