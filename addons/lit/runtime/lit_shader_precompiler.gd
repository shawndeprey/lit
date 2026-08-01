extends Node
class_name LitShaderPrecompiler

## Headless precompile manager: work list, skip marker, frame-budgeted compile loop,
## PSO warm draws. Presentation lives in lit_precompile_overlay.gd via the signals.

signal progress(done: int, total: int, label: String)
signal finished

const MARKER_PATH := "user://lit_shaders.cfg"
const WORKER_DIR := "user://lit_worker"
const BUILD_BUDGET_MS := 8.0
const SILENT_PER_FRAME := 4
const QUAD_POOL := 16

var took_over := false

var _worker_pid := -1
var _parent_check := 0.0
var _hb_accum := 0.0
var _hb_wait := 0.0
var _worker_wait := 0.0
var _report_done := false
var _hb_thread: Thread
var _hb_exit := false

var _work: Array[int] = []
var _next := 0
var _pending: Array[int] = []
var _batch := 4
var _silent := false
var _async := false
var _prev_paused := false
var _last_tick := 0
var _quad_layer: CanvasLayer
var _quads: Array[Sprite2D] = []


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)


static func work_list() -> Array[int]:
	return LitShaderLibrary.all_variant_flags()


# Version and sources are both inside source_for output; the include bodies catch
# edits to the spine or any unit that no wrapper text reflects.
static func bundle_hash(work: Array[int]) -> String:
	var src: String = LitShaderLibrary.COMMON_INCLUDE.code
	for unit in LitShaderLibrary.INCLUDE_UNITS:
		src += unit.code
	for f in work:
		src += LitShaderLibrary.source_for(f)
	return src.md5_text()


static func marker_fresh(work: Array[int]) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(MARKER_PATH) != OK:
		return false
	return cfg.get_value("lit", "bundle", "") == bundle_hash(work) \
			and cfg.get_value("lit", "worklist", "") == str(work).md5_text()


static func variant_label(flags: int) -> String:
	if flags == 0:
		return "base"
	var parts: Array[String] = []
	for axis in LitShaderLibrary.AXES:
		if flags & axis.flag != 0:
			parts.append(str(axis.define).trim_prefix("LIT_").to_lower())
	return " + ".join(parts)


## Worker-process entry: compile the full worklist flat out in a hidden instance,
## reporting each baked variant via a done-file the parent polls.
func start_worker(_parent_pid: int) -> void:
	_report_done = true
	DirAccess.make_dir_recursive_absolute(WORKER_DIR)
	# Heartbeat from a thread: compile frames can stall for seconds, and a frame-bound
	# heartbeat reads as death to the parent mid-stall.
	_hb_thread = Thread.new()
	_hb_thread.start(_hb_loop)
	start(false)


func _hb_loop() -> void:
	while not _hb_exit:
		var fa := FileAccess.open(WORKER_DIR + "/worker_alive", FileAccess.WRITE)
		if fa != null:
			fa.close()
		OS.delay_msec(1000)


func _stop_hb() -> void:
	if _hb_thread != null:
		_hb_exit = true
		_hb_thread.wait_to_finish()
		_hb_thread = null


func _exit_tree() -> void:
	_stop_hb()


func start(silent: bool, asynchronous: bool = false, worker_pid: int = -1) -> void:
	_work = work_list()
	_silent = silent
	_async = asynchronous
	_worker_pid = worker_pid if asynchronous else -1
	LitShaderLibrary._warmed.clear()
	for f in _work:
		LitShaderLibrary._warmed[f] = true
	if not silent:
		if not _async:
			took_over = true
			_prev_paused = get_tree().paused
			get_tree().paused = true
		_build_quads()
	_last_tick = Time.get_ticks_usec()
	set_process(true)


func _process(delta: float) -> void:
	# Worker liveness: pid APIs are unreliable for non-child processes, so the parent
	# heartbeats a file once a second and the worker quits when it goes stale.
	if _report_done:
		_parent_check += delta
		if _parent_check >= 1.0:
			_parent_check = 0.0
			_hb_wait += 1.0
			var hb := FileAccess.get_modified_time(WORKER_DIR + "/parent_alive")
			if (hb > 0 and Time.get_unix_time_from_system() - hb > 5.0) \
					or (hb == 0 and _hb_wait > 10.0):
				get_tree().quit()
				return
	elif _worker_pid > 0:
		_hb_accum += delta
		if _hb_accum >= 1.0:
			_hb_accum = 0.0
			_worker_wait += 1.0
			var fa := FileAccess.open(WORKER_DIR + "/parent_alive", FileAccess.WRITE)
			if fa != null:
				fa.close()
	if _silent:
		for i in SILENT_PER_FRAME:
			if _next >= _work.size():
				_finish()
				return
			LitShaderLibrary.get_receiver(_work[_next])
			_next += 1
		return

	# Whatever was assigned last frame has drawn by now: its pipelines are warm.
	if _report_done:
		for f in _pending:
			var fa := FileAccess.open("%s/f_%d.done" % [WORKER_DIR, f], FileAccess.WRITE)
			if fa != null:
				fa.close()
	var done := _next - _pending.size()
	if _pending.is_empty() and _next >= _work.size():
		_finish()
		return
	_pending.clear()

	# Adapt batch size to the whole previous frame (PSO stalls show up here).
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_tick) / 1000.0
	_last_tick = now
	if frame_ms > 25.0:
		_batch = maxi(1, _batch >> 1)
	elif frame_ms < 12.0:
		_batch = mini(QUAD_POOL, _batch + 2)

	var t0 := Time.get_ticks_usec()
	var quad := 0
	while _next < _work.size() and quad < _batch:
		var flags := _work[_next]
		# Follow the worker: introduce only variants it has baked (cache hits). Worker
		# death is judged by its heartbeat going stale (spawn shells hide the real pid);
		# on death, drop to self-compiling the remainder. Both cases stay silent.
		if _worker_pid > 0 and not FileAccess.file_exists("%s/f_%d.done" % [WORKER_DIR, flags]):
			var wa := FileAccess.get_modified_time(WORKER_DIR + "/worker_alive")
			if (wa > 0 and Time.get_unix_time_from_system() - wa < 5.0) \
					or (wa == 0 and _worker_wait < 15.0):
				break
			_worker_pid = -1
		(_quads[quad].material as ShaderMaterial).shader = LitShaderLibrary.get_receiver(flags)
		_quads[quad].visible = true
		_pending.append(flags)
		_next += 1
		quad += 1
		if float(Time.get_ticks_usec() - t0) / 1000.0 > BUILD_BUDGET_MS:
			break
	for i in range(quad, _quads.size()):
		_quads[i].visible = false

	var label := variant_label(_pending[0]) if not _pending.is_empty() else ""
	progress.emit(done, _work.size(), label)


func _finish() -> void:
	if not _silent:
		_write_marker()
		if not _async:
			get_tree().paused = _prev_paused
		if _quad_layer != null:
			_quad_layer.queue_free()
			_quad_layer = null
			_quads.clear()
	progress.emit(_work.size(), _work.size(), "")
	set_process(false)
	finished.emit()
	if _report_done:
		_stop_hb()
		get_tree().quit()


func _write_marker() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("lit", "version", LitShaderLibrary._get_version())
	cfg.set_value("lit", "bundle", bundle_hash(_work))
	cfg.set_value("lit", "worklist", str(_work).md5_text())
	cfg.save(MARKER_PATH)


# 4x4 quads drawn behind the overlay's opaque cover (async: behind the game, near-
# transparent), matching real receiver render state; their draw forces tier C.
func _build_quads() -> void:
	_quad_layer = CanvasLayer.new()
	_quad_layer.layer = -128 if _async else 99
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
		if _async:
			s.modulate.a = 0.02
		_quad_layer.add_child(s)
		_quads.append(s)
