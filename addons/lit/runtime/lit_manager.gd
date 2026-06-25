extends Node

## Runtime gather driver, added as an autoload by lit_plugin.gd.
##
## Autoloads don't run in the editor, so this drives the per-frame gather/cull/pack
## only while the game is running; editor-live preview is handled by the EditorPlugin.
##
## The cost here is the pack, not the per-pixel lighting, so a full repack every frame
## is fine; the registry caches the light list and only rebuilds it on tree changes.

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")

const SETTING_SHADOW_STEP_SCALING := "lit/quality/shadow_step_scaling"
const SETTING_SHADOW_STEPS_MAX := "lit/quality/shadow_steps_max"

const DEFAULT_SHADOW_STEP_SCALING := false
const DEFAULT_SHADOW_STEPS_MAX := 64

var _registry: LitLightRegistry

var shadow_step_scaling: bool = DEFAULT_SHADOW_STEP_SCALING
var shadow_steps_max: int = DEFAULT_SHADOW_STEPS_MAX

func _ready() -> void:
	_registry = LitLightRegistryScript.new()
	# Run after gameplay scripts have moved their lights this frame.
	process_priority = 1000

	# Pick up the lit/quality/* project settings now and whenever they change at runtime.
	_reload_quality_settings()
	if not ProjectSettings.settings_changed.is_connected(_reload_quality_settings):
		ProjectSettings.settings_changed.connect(_reload_quality_settings)

func _process(_delta: float) -> void:
	_registry.refresh(get_tree(), get_viewport())

func _reload_quality_settings() -> void:
	shadow_step_scaling = bool(ProjectSettings.get_setting(
		SETTING_SHADOW_STEP_SCALING, DEFAULT_SHADOW_STEP_SCALING))
	shadow_steps_max = int(ProjectSettings.get_setting(
		SETTING_SHADOW_STEPS_MAX, DEFAULT_SHADOW_STEPS_MAX))

	# Clamp to the shader's compile-time march cap (LIT_MAX_SHADOW_STEPS).
	shadow_steps_max = clampi(shadow_steps_max, 1, 256)

	# Publish to the receiver shader as globals; both feed the adaptive shadow march.
	RenderingServer.global_shader_parameter_set("lit_shadow_steps_max", shadow_steps_max)
	RenderingServer.global_shader_parameter_set("lit_shadow_step_scaling", shadow_step_scaling)
