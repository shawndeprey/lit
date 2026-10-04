extends Node
class_name LitShaderPrecompiler

## Precompile manager: work list, skip marker, and the three ways a list is run.
##  - build: every item is introduced in this process with one warm draw each (the
##    startup takeover, and each worker process over the items it claims);
##  - follow: worker processes bake into the shared disk caches while this process
##    only reports their progress, so its own frames never wait on a compile;
##  - silent: the caches are fresh, so the variants are just instantiated.
## Presentation lives in lit_precompile_overlay.gd via the signals.
##
## What each stage of a cold shader costs decides the shape of all three. Assigning
## shader code parses it on the calling thread and starts the backend compile on the
## engine's thread pool; only the first draw waits for it. That draw then builds the
## pipeline in the GPU driver, the longest step by far, and it always blocks the
## rendering of the process that draws. The driver's own disk cache is read when a
## process starts, so a pipeline baked by a worker is a hit for the next launch, never
## for a process that is already running.

signal progress(done: int, total: int, label: String)
signal finished

const MARKER_PATH := "user://lit_shaders.cfg"
const CONFIG_PATH := "res://lit_precompile.cfg"
const WORKER_DIR := "user://lit_worker"
const WORKER_ARG := "lit-worker"
const WORKER_LOOP_PATH := "res://addons/lit/runtime/lit_worker_loop.gd"
const WorldSdfScript := preload("res://addons/lit/runtime/registry/world_sdf.gd")
const BUILD_BUDGET_MS := 8.0
const SILENT_PER_FRAME := 4
const QUAD_POOL := 16
const SETTING_MAX_WORKERS := "lit/startup/precompile_max_workers"
const DEFAULT_MAX_WORKERS := 4
const THREADS_PER_WORKER := 6
const HEARTBEAT_STALE_SEC := 5.0
const WORKER_BOOT_SEC := 15.0
const FOLLOW_POLL_MSEC := 250

enum Mode { SILENT, BUILD, FOLLOW }

var took_over := false

var _mode := Mode.SILENT
var _is_worker := false
var _work: Array = []
var _next := 0
var _done := 0
var _pending: Array = []
var _claimed_at := {}
var _prev_paused := false
var _quad_layer: CanvasLayer
var _quads: Array[Sprite2D] = []
var _encode_vp: SubViewport

# Follow mode: _plan is filled by the worker thread and adopted on the main thread.
var _plan := {}
var _plan_mutex := Mutex.new()
var _remaining := {}
var _marker := {}
var _follow_poll := 0
var _finishing := false

var _thread: Thread
var _hb_exit := false
var _start_msec := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


## Work items: int = receiver variant flags (compiled from generated source); String =
## a static shader path warmed verbatim. The authored entry files and the world-SDF
## encoder hash to their own cache entries (their source text differs from the
## generated variants), so skipping them here would leave unwarmed PSOs for the first
## frames of async/API runs.
static func work_list() -> Array:
	var configured: Variant = config_work_list()
	if configured != null:
		return configured
	var out: Array = []
	out.append_array(static_shaders())
	out.append_array(used_post_shaders())
	out.append_array(LitShaderLibrary.all_variant_flags())
	return out


## A generated res://lit_precompile.cfg (Project > Tools > Generate Lit Precompile
## Config) replaces the full work list verbatim: exactly what it names, nothing more.
## Returns null when the file is absent or unreadable, which means the full build
## above; delete the file to get back there.
static func config_work_list() -> Variant:
	if not FileAccess.file_exists(CONFIG_PATH):
		return null
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		push_warning("Lit: precompile config '%s' failed to parse; running the full precompile" % CONFIG_PATH)
		return null
	var out: Array = []
	for path in cfg.get_value("lit", "shaders", PackedStringArray()):
		if ResourceLoader.exists(path):
			out.append(String(path))
		else:
			push_warning("Lit: precompile config names a missing shader '%s'; regenerate the config" % path)
	for name in cfg.get_value("lit", "variants", PackedStringArray()):
		var flags := LitShaderLibrary.flags_from_variant_name(String(name))
		if flags >= 0:
			out.append(flags)
		else:
			push_warning("Lit: precompile config names an unknown variant '%s'; regenerate the config" % name)
	return out


static var _post_scan = null

## Post-effect shaders referenced by any project scene, found by reading scene
## dependency headers (never loading the scenes themselves). Effects added purely from
## code at runtime are invisible here and compile on first use, as before.
static func used_post_shaders() -> Array:
	if _post_scan != null:
		return _post_scan
	var effect_scripts := _post_effect_scripts()
	var found := {}
	if not effect_scripts.is_empty():
		var scenes: Array[String] = []
		_collect_scenes("res://", scenes)
		for scene in scenes:
			for dep in _scene_deps(scene):
				var path := dep.get_slice("::", dep.get_slice_count("::") - 1)
				if effect_scripts.has(path):
					var script := load(path) as Script
					var sh: Variant = script.get_script_constant_map().get("SHADER") if script != null else null
					if sh is Shader and not (sh as Shader).resource_path.is_empty():
						found[(sh as Shader).resource_path] = true
	var out: Array = found.keys()
	out.sort()
	_post_scan = out
	return out


## Script paths of every global class extending LitPostEffect (the SHADER const
## convention covers built-ins and generated custom effects).
static func _post_effect_scripts() -> Dictionary:
	var classes := ProjectSettings.get_global_class_list()
	var by_name := {}
	for c in classes:
		by_name[c["class"]] = c
	var out := {}
	for c in classes:
		var base: StringName = c.base
		while by_name.has(base):
			if base == &"LitPostEffect":
				out[c.path] = true
				break
			base = by_name[base].base
	return out


static func _collect_scenes(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		var path := String(dir.path_join(f)).trim_suffix(".remap")
		if path.get_extension() == "tscn" or path.get_extension() == "scn":
			out.append(path)
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_collect_scenes(dir.path_join(d), out)


static func _scene_deps(scene: String) -> PackedStringArray:
	var deps := ResourceLoader.get_dependencies(scene)
	# Exported PCKs remap converted scenes; follow the redirect by hand if the loader didn't.
	if deps.is_empty() and FileAccess.file_exists(scene + ".remap"):
		var cfg := ConfigFile.new()
		if cfg.load(scene + ".remap") == OK:
			deps = ResourceLoader.get_dependencies(str(cfg.get_value("remap", "path", "")))
	return deps


## The disk shaders warmed as-is: the three tier entry files (what authored scene
## materials reference) plus the world-SDF encode shader (compiles at first world-SDF
## creation on every cold machine otherwise).
static func static_shaders() -> Array:
	var out: Array = []
	for tier in LitShaderLibrary.ENTRY_PATHS:
		out.append(LitShaderLibrary.ENTRY_PATHS[tier])
	out.append(WorldSdfScript.ENCODE_SHADER_PATH)
	return out


# Version and sources are both inside source_for output; the include bodies catch
# edits to the spine or any unit that no wrapper text reflects. Static shaders fold in
# their own source so editing an entry file re-triggers one takeover.
static func bundle_hash(work: Array) -> String:
	var src: String = LitShaderLibrary.COMMON_INCLUDE.code
	for unit in LitShaderLibrary.INCLUDE_UNITS:
		src += unit.code
	for item in work:
		if item is int:
			src += LitShaderLibrary.source_for(item)
		else:
			src += (load(item) as Shader).code
	return src.md5_text()


static func marker_fresh(work: Array) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(MARKER_PATH) != OK:
		return false
	var want := marker_values(work)
	return cfg.get_value("lit", "bundle", "") == want.bundle \
			and cfg.get_value("lit", "worklist", "") == want.worklist


static func marker_values(work: Array) -> Dictionary:
	return {
		"version": LitShaderLibrary._get_version(),
		"bundle": bundle_hash(work),
		"worklist": str(work).md5_text(),
	}


## Worker done-file key for a work item (variant flags or static shader path).
static func done_key(item: Variant) -> String:
	if item is int:
		return "f_%d" % item
	return "s_%s" % str(item).md5_text().substr(0, 12)


static func variant_label(flags: int) -> String:
	if flags == 0:
		return "base"
	var parts: Array[String] = []
	for axis in LitShaderLibrary.AXES:
		if flags & axis.flag != 0:
			parts.append(str(axis.define).trim_prefix("LIT_").to_lower())
	return " + ".join(parts)


static func item_label(item: Variant) -> String:
	if item is int:
		return variant_label(item)
	return str(item).get_file().get_basename()


## How many worker processes bake a list of this size: one per THREADS_PER_WORKER
## hardware threads (a shader's backend compile runs six engine variants in parallel),
## up to the lit/startup/precompile_max_workers setting. Each is a whole engine
## instance, and measured scaling is well short of linear (about 1.5x for two, 2x for
## four), so the default cap stays low.
static func worker_count(work_size: int) -> int:
	var cap := clampi(int(ProjectSettings.get_setting(SETTING_MAX_WORKERS, DEFAULT_MAX_WORKERS)), 1, 16)
	return clampi(mini(OS.get_processor_count() / THREADS_PER_WORKER, work_size), 1, cap)


## Run the work list. Silent only instantiates the variants (the caches are fresh).
## Otherwise follow_workers picks between baking in worker processes, which this call
## spawns and then only reports on, and building everything here behind a paused tree.
func start(silent: bool, follow_workers: bool = false) -> void:
	if not silent and follow_workers:
		# Listing the work, hashing it and spawning the workers all happen on the
		# thread, so calling this mid-game costs the caller's frame nothing.
		_mode = Mode.FOLLOW
		_start_thread(_follow_thread)
		set_process(true)
		return
	_work = work_list()
	_mark_warmed()
	if silent:
		_mode = Mode.SILENT
	else:
		_mode = Mode.BUILD
		took_over = true
		_prev_paused = get_tree().paused
		get_tree().paused = true
		_build_quads()
	set_process(true)


## Worker-process entry: build the items this process manages to claim, flat out in a
## hidden instance, reporting each baked item via a done-file the parent polls.
func start_worker() -> void:
	_is_worker = true
	_mode = Mode.BUILD
	_work = work_list()
	_start_thread(_heartbeat.bind("worker_alive", "parent_alive"))
	_build_quads()
	set_process(true)


# Dev builds log variants compiled outside the work list (LitShaderLibrary._log_miss).
func _mark_warmed() -> void:
	LitShaderLibrary._warmed.clear()
	for item in _work:
		if item is int:
			LitShaderLibrary._warmed[item] = true


func _start_thread(body: Callable) -> void:
	_start_msec = Time.get_ticks_msec()
	_hb_exit = false
	_thread = Thread.new()
	_thread.start(body)


func _follow_thread() -> void:
	var work := work_list()
	var plan := {"work": work, "marker": marker_values(work)}
	_spawn_workers(worker_count(work.size()))
	_plan_mutex.lock()
	_plan = plan
	_plan_mutex.unlock()
	_heartbeat("parent_alive", "")


# Liveness runs on a thread on both sides: a frame-bound heartbeat stops for as long
# as a compile or a scene load holds the frame, which reads as death to the other side.
# A worker also watches its parent from here and ends the process outright, so it
# never outlives the game by the length of the compile its frame is sitting in.
func _heartbeat(file: String, watch: String) -> void:
	while not _hb_exit:
		var fa := FileAccess.open(WORKER_DIR + "/" + file, FileAccess.WRITE)
		if fa != null:
			fa.close()
		if watch != "" and _peer_dead(watch):
			OS.kill(OS.get_process_id())
		for i in 20:
			if _hb_exit:
				break
			OS.delay_msec(50)


func _stop_thread() -> void:
	if _thread != null:
		_hb_exit = true
		_thread.wait_to_finish()
		_thread = null


func _exit_tree() -> void:
	_stop_thread()


# The other side is gone once its heartbeat file is stale, or never appeared within
# the boot window.
func _peer_dead(file: String) -> bool:
	var at := FileAccess.get_modified_time(WORKER_DIR + "/" + file)
	if at > 0:
		return Time.get_unix_time_from_system() - at > HEARTBEAT_STALE_SEC
	return float(Time.get_ticks_msec() - _start_msec) / 1000.0 > WORKER_BOOT_SEC


## Hidden extra instances of this process, each claiming items off the same list and
## baking them into the shared shader caches. Thread-safe: only OS and file calls.
static func _spawn_workers(count: int) -> void:
	var wd := ProjectSettings.globalize_path(WORKER_DIR)
	clear_worker_dir()
	DirAccess.make_dir_recursive_absolute(wd)
	var hb := FileAccess.open(wd.path_join("parent_alive"), FileAccess.WRITE)
	if hb != null:
		hb.close()
	var exe := OS.get_executable_path()
	var args := PackedStringArray(["--position", "-32000,-32000", "--resolution", "640x220"])
	if OS.has_feature("editor"):
		args.append_array(PackedStringArray(["--path", ProjectSettings.globalize_path("res://")]))
	# A script main loop boots the autoloads and no scene, never the game's main scene.
	args.append_array(PackedStringArray(["--script", WORKER_LOOP_PATH, "--", WORKER_ARG]))
	if OS.get_name() == "Windows" and _spawn_hidden(exe, args, count):
		return
	for i in count:
		if OS.get_name() == "Windows":
			# start /min births the window minimized so it never flashes on screen. The
			# spaced title is required: create_process drops empty args, and start reads
			# the first quoted token as its title - which would swallow a quoted (spaced)
			# exe path.
			var cargs := PackedStringArray(["/c", "start", "Lit Worker", "/min", exe])
			cargs.append_array(args)
			OS.create_process("cmd.exe", cargs)
		else:
			OS.create_process(exe, args)


# Start-Process -WindowStyle Hidden hands each worker a hidden first window show, so
# neither a window nor a taskbar button ever appears (a minimized birth still puts a
# button on the taskbar until the worker has booted far enough to drop it). The
# command goes over encoded, so no path in it needs shell quoting.
static func _spawn_hidden(exe: String, args: PackedStringArray, count: int) -> bool:
	var line := PackedStringArray()
	for arg in args:
		line.append("\"%s\"" % arg if arg.contains(" ") else arg)
	var script := "1..%d | ForEach-Object { Start-Process -WindowStyle Hidden -FilePath '%s' -ArgumentList '%s' }" \
			% [count, exe.replace("'", "''"), " ".join(line).replace("'", "''")]
	return OS.create_process("powershell.exe", PackedStringArray(["-NoProfile", "-NonInteractive",
			"-EncodedCommand", Marshalls.raw_to_base64(script.to_utf16_buffer())])) != -1


func _process(_delta: float) -> void:
	if _finishing:
		# The thread sees the exit flag within one sleep slice; joining it only once
		# it has returned keeps the join from holding a frame.
		if not _thread.is_alive():
			_stop_thread()
			_finishing = false
			set_process(false)
			finished.emit()
		return
	match _mode:
		Mode.SILENT:
			_process_silent()
		Mode.FOLLOW:
			_process_follow()
		Mode.BUILD:
			_process_build()


func _process_silent() -> void:
	for i in SILENT_PER_FRAME:
		if _next >= _work.size():
			_finish(true)
			return
		var item: Variant = _work[_next]
		# Statics warm the disk cache only; the in-process shader dict is variant-only.
		if item is int:
			LitShaderLibrary.get_receiver(item)
		_next += 1


# The workers do all of the building; this process only counts their done-files, one
# directory listing per poll. It never introduces a baked item itself: that would
# build the pipeline a second time, on this process's own frames.
func _process_follow() -> void:
	var now := Time.get_ticks_msec()
	if now - _follow_poll < FOLLOW_POLL_MSEC:
		return
	_follow_poll = now
	var first := _marker.is_empty()
	if first:
		_plan_mutex.lock()
		var plan := _plan
		_plan_mutex.unlock()
		if plan.is_empty():
			return
		_work = plan.work
		_marker = plan.marker
		for item in _work:
			_remaining[done_key(item) + ".done"] = item
		_mark_warmed()
	var label := ""
	for f in DirAccess.get_files_at(WORKER_DIR):
		if _remaining.has(f):
			label = item_label(_remaining[f])
			_remaining.erase(f)
	if label != "" or first:
		_done = _work.size() - _remaining.size()
		progress.emit(_done, _work.size(), label)
	if _remaining.is_empty():
		_finish(true)
		return
	# Workers that died or never came up leave the rest unbuilt: stop without the
	# marker, so the next launch runs the list again with the baked items as hits.
	if _peer_dead("worker_alive"):
		push_warning("Lit: shader precompile workers stopped with %d of %d items left; the next launch resumes" % [_remaining.size(), _work.size()])
		_finish(false)


func _process_build() -> void:
	# Whatever was assigned last frame has drawn by now: its pipelines are warm.
	if _is_worker:
		for item in _pending:
			var fa := FileAccess.open("%s/%s.done" % [WORKER_DIR, done_key(item)], FileAccess.WRITE)
			if fa != null:
				fa.store_string("%d %.3f %.3f" % [OS.get_process_id(), _claimed_at.get(item, 0.0),
						Time.get_unix_time_from_system()])
				fa.close()
	_done += _pending.size()
	_pending.clear()

	var t0 := Time.get_ticks_usec()
	var quad := 0
	while _next < _work.size() and quad < _quads.size():
		var item: Variant = _work[walk_index(_next, _work.size())]
		_next += 1
		if _is_worker and not _claim(item):
			continue
		if item is String and item == WorldSdfScript.ENCODE_SHADER_PATH:
			# PSOs key on the render-pass format: the encode shader draws into an HDR
			# target in real use, so its warm draw runs in the matching SubViewport
			# built by _build_quads.
			_encode_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		else:
			(_quads[quad].material as ShaderMaterial).shader = \
					LitShaderLibrary.get_receiver(item) if item is int else load(item)
			_quads[quad].visible = true
			quad += 1
		_pending.append(item)
		if float(Time.get_ticks_usec() - t0) / 1000.0 > BUILD_BUDGET_MS:
			break
	for i in range(quad, _quads.size()):
		_quads[i].visible = false
	if _pending.is_empty():
		_finish(true)
		return
	progress.emit(_done, _work.size(), item_label(_pending[0]))


## Build order: the list walked from both ends at once. Its light and heavy ends
## alternate, so progress moves at an even pace instead of crawling through the heavy
## tail, and the workers' last items are not all the slow ones.
static func walk_index(step: int, size: int) -> int:
	var at := step >> 1
	return at if step & 1 == 0 else size - 1 - at


# Directory creation is atomic across processes: exactly one worker gets OK. The file
# inside it (named by pid, holding the claim time) and the done-file's content exist
# for diagnostics only; the bake itself reads neither.
func _claim(item: Variant) -> bool:
	var dir := "%s/%s.claim" % [WORKER_DIR, done_key(item)]
	if DirAccess.make_dir_absolute(dir) != OK:
		return false
	_claimed_at[item] = Time.get_unix_time_from_system()
	var fa := FileAccess.open("%s/%d" % [dir, OS.get_process_id()], FileAccess.WRITE)
	if fa != null:
		fa.store_string("%.3f" % _claimed_at[item])
		fa.close()
	return true


## Empties the worker directory: heartbeats, done-files and claim folders.
static func clear_worker_dir() -> void:
	var wd := ProjectSettings.globalize_path(WORKER_DIR)
	if not DirAccess.dir_exists_absolute(wd):
		return
	for f in DirAccess.get_files_at(wd):
		DirAccess.remove_absolute(wd.path_join(f))
	for d in DirAccess.get_directories_at(wd):
		for f in DirAccess.get_files_at(wd.path_join(d)):
			DirAccess.remove_absolute(wd.path_join(d).path_join(f))
		DirAccess.remove_absolute(wd.path_join(d))


# complete = every item of the list is baked. A worker only ever bakes its share and
# leaves the marker to its parent.
func _finish(complete: bool) -> void:
	if _mode == Mode.BUILD:
		if took_over:
			get_tree().paused = _prev_paused
		if _quad_layer != null:
			_quad_layer.queue_free()
			_quad_layer = null
			_quads.clear()
		if _encode_vp != null:
			_encode_vp.queue_free()
			_encode_vp = null
	if _is_worker:
		_stop_thread()
		get_tree().quit()
		return
	if complete:
		if _mode != Mode.SILENT:
			_write_marker(_marker if _mode == Mode.FOLLOW else marker_values(_work))
		progress.emit(_work.size(), _work.size(), "")
	if _thread != null:
		_hb_exit = true
		_finishing = true
		return
	set_process(false)
	finished.emit()


static func _write_marker(values: Dictionary) -> void:
	var cfg := ConfigFile.new()
	for key in values:
		cfg.set_value("lit", key, values[key])
	cfg.save(MARKER_PATH)


# 4x4 quads drawn behind the overlay's opaque cover, matching real receiver render
# state; their draw forces the pipeline build.
func _build_quads() -> void:
	_quad_layer = CanvasLayer.new()
	_quad_layer.layer = 99
	add_child(_quad_layer)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)
	for i in QUAD_POOL:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.position = Vector2(4 + i * 6, 4)
		s.material = ShaderMaterial.new()
		s.visible = false
		_quad_layer.add_child(s)
		_quads.append(s)

	# World-SDF encode warm target: an HDR SubViewport matching world_sdf.gd's render
	# state (a main-viewport quad would bake a PSO for the wrong target format).
	# Parked until its work item comes up in _process_build.
	_encode_vp = SubViewport.new()
	_encode_vp.size = Vector2i(64, 64)
	_encode_vp.use_hdr_2d = true
	_encode_vp.disable_3d = true
	_encode_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var enc_layer := CanvasLayer.new()
	var enc_rect := ColorRect.new()
	enc_rect.size = Vector2(64, 64)
	var enc_mat := ShaderMaterial.new()
	enc_mat.shader = load(WorldSdfScript.ENCODE_SHADER_PATH)
	enc_rect.material = enc_mat
	enc_layer.add_child(enc_rect)
	_encode_vp.add_child(enc_layer)
	add_child(_encode_vp)
