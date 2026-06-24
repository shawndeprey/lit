extends Node

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

	process_priority = 1000

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

	shadow_steps_max = clampi(shadow_steps_max, 1, 256)

	RenderingServer.global_shader_parameter_set("lit_shadow_steps_max", shadow_steps_max)
	RenderingServer.global_shader_parameter_set("lit_shadow_step_scaling", shadow_step_scaling)
