extends Node

## Runtime gather driver, added as an autoload by lit_plugin.gd.
##
## Autoloads don't run in the editor, so this drives the per-frame gather/cull/pack
## only while the game is running; editor-live preview is handled by the EditorPlugin.
##
## The cost here is the pack, not the per-pixel lighting, so a full repack every frame
## is fine; the registry caches the light list and only rebuilds it on tree changes.

signal precompile_progress(done: int, total: int, label: String)
signal precompile_finished

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")
const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const LitPrecompileOverlayScript := preload("res://addons/lit/nodes/lit_precompile_overlay.gd")

const SETTING_PRECOMPILE := "lit/startup/precompile_shaders"
const SETTING_PRECOMPILE_ASYNC := "lit/startup/precompile_async"
const WORKER_ARG := "lit-worker"
const WORKER_SCENE_PATH := "res://addons/lit/runtime/lit_worker_scene.tscn"
# Preloaded so exports always pack the worker scene.
const WorkerScene := preload("res://addons/lit/runtime/lit_worker_scene.tscn")
const SETTING_LIGHTING_MODEL := "lit/render/lighting_model"
const SETTING_Y_SORTING := "lit/render/y_sorting"
const SETTING_Y_SORT_SMOOTHING := "lit/render/y_sort_smoothing"
const SETTING_SDF_CULLING := "lit/render/occluder_mask_sdf_culling"
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
var precompiler: Node = null
var _api_precompiler: Node = null

var lighting_model: int = DEFAULT_LIGHTING_MODEL
var shadow_step_scaling: bool = DEFAULT_SHADOW_STEP_SCALING
var shadow_steps_max: int = DEFAULT_SHADOW_STEPS_MAX
var shadow_samples_max: int = DEFAULT_SHADOW_SAMPLES_MAX

func _ready() -> void:
	_registry = LitLightRegistryScript.new()
	# Run after gameplay scripts have moved their lights this frame.
	process_priority = 1000

	var uargs := OS.get_cmdline_user_args()
	var widx := uargs.find(WORKER_ARG)
	if widx != -1:
		_boot_worker(int(uargs[widx + 1]) if widx + 1 < uargs.size() else -1)
		return

	# Pick up the lit/* project settings now and whenever they change at runtime.
	_reload_settings()
	if not ProjectSettings.settings_changed.is_connected(_reload_settings):
		ProjectSettings.settings_changed.connect(_reload_settings)

	_boot_self_check()
	if bool(ProjectSettings.get_setting(SETTING_PRECOMPILE, true)):
		precompiler = LitShaderPrecompilerScript.new()
		add_child(precompiler)
		var fresh: bool = LitShaderPrecompilerScript.marker_fresh(LitShaderPrecompilerScript.work_list())
		if not fresh:
			var overlay: Node = LitPrecompileOverlayScript.new()
			overlay.name = "LitPrecompileOverlay"
			overlay.attach(precompiler)
			# Deferred root add lands after the main scene in tree order, so the cover
			# wins same-layer ties against game HUDs at layer 128.
			get_tree().root.add_child.call_deferred(overlay)
			var asynchronous := bool(ProjectSettings.get_setting(SETTING_PRECOMPILE_ASYNC, false))
			precompiler.start(fresh, asynchronous, _spawn_worker() if asynchronous else -1)
		else:
			precompiler.start(fresh)


## Hidden second instance of this process: bakes every variant into the shared shader
## caches flat out, so the main process introduces cache hits instead of compiles.
func _spawn_worker() -> int:
	var wd := ProjectSettings.globalize_path(LitShaderPrecompilerScript.WORKER_DIR)
	if DirAccess.dir_exists_absolute(wd):
		for f in DirAccess.get_files_at(wd):
			DirAccess.remove_absolute(wd.path_join(f))
	DirAccess.make_dir_recursive_absolute(wd)
	var hb := FileAccess.open(wd.path_join("parent_alive"), FileAccess.WRITE)
	if hb != null:
		hb.close()
	var exe := OS.get_executable_path()
	var args := PackedStringArray(["--position", "-32000,-32000", "--resolution", "640x220"])
	if OS.has_feature("editor"):
		args.append_array(PackedStringArray(["--path", ProjectSettings.globalize_path("res://")]))
	# Boot the empty worker scene, never the game's main scene.
	args.append(WORKER_SCENE_PATH)
	args.append_array(PackedStringArray(["--", WORKER_ARG, str(OS.get_process_id())]))
	if OS.get_name() == "Windows":
		# start /min births the window minimized so it never flashes on screen. The spaced
		# title is required: create_process drops empty args, and start reads the first
		# quoted token as its title - which would swallow a quoted (spaced) exe path.
		var cargs := PackedStringArray(["/c", "start", "Lit Worker", "/min", exe])
		cargs.append_array(args)
		return OS.create_process("cmd.exe", cargs)
	return OS.create_process(exe, args)


func _boot_worker(parent_pid: int) -> void:
	var w := get_window()
	w.title = "Lit Shader Worker"
	w.mode = Window.MODE_MINIMIZED
	# Unfocusable maps to WS_EX_NOACTIVATE on Windows, which also drops the taskbar
	# button - the worker can't be clicked into view.
	w.unfocusable = true
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	precompiler = LitShaderPrecompilerScript.new()
	add_child(precompiler)
	# Some launch shapes ignore the boot-scene argument; swap the main scene out either way.
	_ensure_worker_scene.call_deferred()
	var overlay: Node = LitPrecompileOverlayScript.new()
	overlay.force_takeover = true
	overlay.attach(precompiler)
	get_tree().root.add_child.call_deferred(overlay)
	precompiler.start_worker(parent_pid)


func _ensure_worker_scene() -> void:
	var cs := get_tree().current_scene
	if cs == null or cs.scene_file_path != WORKER_SCENE_PATH:
		get_tree().change_scene_to_packed(WorkerScene)


## Public API: run the precompile pipeline on demand (always worker-backed); wire UI to
## precompile_progress / precompile_finished. False if a precompile is already in flight.
func precompile_shaders() -> bool:
	if _api_precompiler != null or (precompiler != null and precompiler.is_processing()):
		return false
	_api_precompiler = LitShaderPrecompilerScript.new()
	add_child(_api_precompiler)
	_api_precompiler.progress.connect(_on_api_progress)
	_api_precompiler.finished.connect(_on_api_finished)
	_api_precompiler.start(false, true, _spawn_worker())
	return true


func _on_api_progress(done: int, total: int, label: String) -> void:
	precompile_progress.emit(done, total, label)


func _on_api_finished() -> void:
	var pre := _api_precompiler
	_api_precompiler = null
	pre.queue_free()
	precompile_finished.emit()

# Exports drop bare .gdshaderinc dependencies; the library preload normally carries the
# spine through, so a miss here means the preload chain was broken.
func _boot_self_check() -> void:
	if not ResourceLoader.exists(LitShaderLibrary.COMMON_INCLUDE_PATH):
		push_error("Lit: %s failed to resolve; no receiver variant can compile. If this is an exported build, add '*.gdshaderinc' to the export's resource filters." % LitShaderLibrary.COMMON_INCLUDE_PATH)

## Public API: how much Lit light reaches `world_pos`, as one scalar.
##
## 0.0 = pitch black. 1.0 = fully lit: the center of a plain white energy-1 light, or
## standing in full white ambient. Brighter or overlapping lights push it above 1.0,
## so clamp (or divide by your scene's maximum) for a 0-1 stealth meter.
##
## The value tracks what's rendered: distance falloff, spot cones, cookie textures,
## light/receiver masks, ambient darkness (LitCanvasModulate), subtractive lights and
## shadow occlusion all apply. Occlusion is a geometric umbra test against the same
## occluders that cast shadows, so penumbra softness is not reflected - a point is
## either in shadow or not.
##
## `receiver_mask` filters lights exactly like a receiver's Receiver Mask;
## `shadow_ignore_mask` mirrors a receiver's Shadow Ignore Mask.
## `exclude_occluders_of` mirrors a receiver's self-shadow exemption: occluders in
## that node's subtree or among its direct siblings don't shadow the sample (a
## sprite's own footprint occluder shadows the world behind it, never itself).
## LitSprite2D.get_luminance() calls this with the sprite's own values.
func sample_luminance(world_pos: Vector2, receiver_mask: int = 1,
		shadow_ignore_mask: int = 0, exclude_occluders_of: Node = null) -> float:
	return _registry.sample_luminance(get_tree(), get_tree().root, world_pos,
			receiver_mask, shadow_ignore_mask, exclude_occluders_of)


func _process(_delta: float) -> void:
	_registry.refresh(get_tree(), get_viewport(), get_tree().root, self)

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

	# Runtime only: pull globally excluded occluders out of the SDF instead of exempting
	# them in-shader. The editor previews via the _gx shaders and never mutates nodes.
	_registry.sdf_cull = bool(ProjectSettings.get_setting(SETTING_SDF_CULLING, true))

	# Publish to the receiver shader as globals. lit_lighting_model selects the Phong/PBR
	# branch; the shadow pair feeds the adaptive shadow march.
	RenderingServer.global_shader_parameter_set("lit_lighting_model", lighting_model)
	RenderingServer.global_shader_parameter_set("lit_shadow_steps_max", shadow_steps_max)
	RenderingServer.global_shader_parameter_set("lit_shadow_step_scaling", shadow_step_scaling)
	RenderingServer.global_shader_parameter_set("lit_ysort_enabled", y_sorting)
	RenderingServer.global_shader_parameter_set("lit_ysort_band", y_sort_band)
