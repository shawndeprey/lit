extends Node

## Runtime gather driver, added as an autoload by lit_plugin.gd.
##
## Autoloads don't run in the editor, so this drives the per-frame gather/cull/pack
## only while the game is running; editor-live preview is handled by the EditorPlugin.
##
## The cost here is the pack, not the per-pixel lighting, so a full repack every frame
## is fine. Dirty-tracking would be a later optimization.
##
## This node is also the runtime home for the lit/quality/* settings (Phase 0): it reads
## them at startup and live-updates on ProjectSettings.settings_changed. The knobs that
## reach the shader are mirrored to global uniforms here (lit_shadow_steps_max); the
## CPU-side ones are held as fields for later phases to consume (shadow_step_scaling in
## Phase 3b, lighting_resolution_scale in Phase 4). All defaults reproduce current
## behavior, so this phase changes no pixels.

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")

# Setting paths and their defaults (defaults match today's behavior).
const SETTING_SHADOW_STEP_SCALING := "lit/quality/shadow_step_scaling"
const SETTING_SHADOW_STEPS_MAX := "lit/quality/shadow_steps_max"
const SETTING_LIGHTING_RESOLUTION_SCALE := "lit/quality/lighting_resolution_scale"

const DEFAULT_SHADOW_STEP_SCALING := false
const DEFAULT_SHADOW_STEPS_MAX := 64
const DEFAULT_LIGHTING_RESOLUTION_SCALE := 1.0

var _registry: LitLightRegistry

# Cached quality settings, refreshed from ProjectSettings at startup and on change.
var shadow_step_scaling: bool = DEFAULT_SHADOW_STEP_SCALING
var shadow_steps_max: int = DEFAULT_SHADOW_STEPS_MAX
var lighting_resolution_scale: float = DEFAULT_LIGHTING_RESOLUTION_SCALE


func _ready() -> void:
	_registry = LitLightRegistryScript.new()
	# Run after gameplay scripts have moved their lights this frame.
	process_priority = 1000

	# Load quality settings now and keep them live. settings_changed fires on any
	# ProjectSettings write (including the editor's Project Settings dialog at runtime
	# via remote, and runtime ProjectSettings.set_setting calls), so re-reading all
	# knobs on each signal is simplest and cheap.
	_reload_quality_settings()
	if not ProjectSettings.settings_changed.is_connected(_reload_quality_settings):
		ProjectSettings.settings_changed.connect(_reload_quality_settings)


func _process(_delta: float) -> void:
	_registry.refresh(get_tree(), get_viewport())


## Read every lit/quality/* knob, clamp where needed, cache it, and push the
## shader-bound ones to their global uniforms. Falls back to the documented default if a
## setting is absent (project mid-upgrade), so behavior is always defined.
func _reload_quality_settings() -> void:
	shadow_step_scaling = bool(ProjectSettings.get_setting(
		SETTING_SHADOW_STEP_SCALING, DEFAULT_SHADOW_STEP_SCALING))
	shadow_steps_max = int(ProjectSettings.get_setting(
		SETTING_SHADOW_STEPS_MAX, DEFAULT_SHADOW_STEPS_MAX))
	lighting_resolution_scale = float(ProjectSettings.get_setting(
		SETTING_LIGHTING_RESOLUTION_SCALE, DEFAULT_LIGHTING_RESOLUTION_SCALE))

	# Guard against nonsense values reaching the shader loop bound.
	shadow_steps_max = clampi(shadow_steps_max, 1, 256)

	# Mirror the shader-bound knob to its global uniform. At the default 64 this is the
	# same value the shader already used, so it's pixel-neutral until Phase 3b reads it.
	RenderingServer.global_shader_parameter_set("lit_shadow_steps_max", shadow_steps_max)
