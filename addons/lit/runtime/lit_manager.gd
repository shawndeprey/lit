extends Node

## Runtime gather driver, added as an autoload by lit_plugin.gd.
##
## Autoloads don't run in the editor, so this drives the per-frame gather/cull/pack
## only while the game is running; editor-live preview is handled by the EditorPlugin.
##
## The cost here is the pack, not the per-pixel lighting, so a full repack every frame
## is fine; the registry caches the light list and only rebuilds it on tree changes.

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")

const SETTING_LIGHTING_MODEL := "lit/render/lighting_model"
const SETTING_Y_SORTING := "lit/render/y_sorting"
const SETTING_Y_SORT_SMOOTHING := "lit/render/y_sort_smoothing"
const SETTING_SHADOW_STEP_SCALING := "lit/quality/shadow_step_scaling"
const SETTING_SHADOW_STEPS_MAX := "lit/quality/shadow_steps_max"
const SETTING_SHADOW_SAMPLES_MAX := "lit/quality/shadow_samples_max"

# Must match LIT_MODEL_* in lit_receiver_common.gdshaderinc and the enum order of the
# lit/render/lighting_model project setting registered by lit_plugin.gd.
enum LightingModel { PHONG = 0, PBR = 1 }

const DEFAULT_LIGHTING_MODEL := LightingModel.PHONG
const DEFAULT_Y_SORTING := false
const DEFAULT_Y_SORT_SMOOTHING := 12.0
const DEFAULT_SHADOW_STEP_SCALING := false
const DEFAULT_SHADOW_STEPS_MAX := 64
const DEFAULT_SHADOW_SAMPLES_MAX := 32

var _registry: LitLightRegistry

var lighting_model: int = DEFAULT_LIGHTING_MODEL
var shadow_step_scaling: bool = DEFAULT_SHADOW_STEP_SCALING
var shadow_steps_max: int = DEFAULT_SHADOW_STEPS_MAX
var shadow_samples_max: int = DEFAULT_SHADOW_SAMPLES_MAX

func _ready() -> void:
	_registry = LitLightRegistryScript.new()
	# Run after gameplay scripts have moved their lights this frame.
	process_priority = 1000

	# Pick up the lit/* project settings now and whenever they change at runtime.
	_reload_settings()
	if not ProjectSettings.settings_changed.is_connected(_reload_settings):
		ProjectSettings.settings_changed.connect(_reload_settings)

func _process(_delta: float) -> void:
	_registry.refresh(get_tree(), get_viewport(), get_tree().root)

func _reload_settings() -> void:
	# Render model selector; clamped to a known value so a stray setting can't index past
	# the shader's branch.
	lighting_model = clampi(int(ProjectSettings.get_setting(
		SETTING_LIGHTING_MODEL, DEFAULT_LIGHTING_MODEL)), LightingModel.PHONG, LightingModel.PBR)

	shadow_step_scaling = bool(ProjectSettings.get_setting(
		SETTING_SHADOW_STEP_SCALING, DEFAULT_SHADOW_STEP_SCALING))
	shadow_steps_max = int(ProjectSettings.get_setting(
		SETTING_SHADOW_STEPS_MAX, DEFAULT_SHADOW_STEPS_MAX))

	# Clamp to the shader's compile-time march cap (LIT_MAX_SHADOW_STEPS).
	shadow_steps_max = clampi(shadow_steps_max, 1, 256)

	# Scene-wide cap on stochastic shadow samples, applied CPU-side at pack time
	# (clamped to the shader's compile-time LIT_MAX_SHADOW_SAMPLES).
	shadow_samples_max = clampi(int(ProjectSettings.get_setting(
		SETTING_SHADOW_SAMPLES_MAX, DEFAULT_SHADOW_SAMPLES_MAX)), 1, 32)
	_registry.shadow_samples_max = shadow_samples_max

	# Band floor keeps the shader's smoothstep edges ordered.
	var y_sorting := bool(ProjectSettings.get_setting(SETTING_Y_SORTING, DEFAULT_Y_SORTING))
	var y_sort_band := maxf(float(ProjectSettings.get_setting(
			SETTING_Y_SORT_SMOOTHING, DEFAULT_Y_SORT_SMOOTHING)), 0.01)
	_registry.set_ysort(y_sorting)

	# Publish to the receiver shader as globals. lit_lighting_model selects the Phong/PBR
	# branch; the shadow pair feeds the adaptive shadow march.
	RenderingServer.global_shader_parameter_set("lit_lighting_model", lighting_model)
	RenderingServer.global_shader_parameter_set("lit_shadow_steps_max", shadow_steps_max)
	RenderingServer.global_shader_parameter_set("lit_shadow_step_scaling", shadow_step_scaling)
	RenderingServer.global_shader_parameter_set("lit_ysort_enabled", y_sorting)
	RenderingServer.global_shader_parameter_set("lit_ysort_band", y_sort_band)
