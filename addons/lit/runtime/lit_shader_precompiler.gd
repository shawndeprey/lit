extends Node
class_name LitShaderPrecompiler

## Headless precompile manager: work list, skip marker, frame-budgeted compile loop,
## PSO warm draws. Presentation lives in lit_precompile_overlay.gd via the signals.

signal progress(done: int, total: int, label: String)
signal finished

const MARKER_PATH := "user://lit_shaders.cfg"
const BUILD_BUDGET_MS := 8.0
const SILENT_PER_FRAME := 4
const QUAD_POOL := 16

var took_over := false

var _work: Array[int] = []
var _next := 0
var _pending: Array[int] = []
var _batch := 4
var _silent := false
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


func start(silent: bool) -> void:
	_work = work_list()
	_silent = silent
	LitShaderLibrary._warmed.clear()
	for f in _work:
		LitShaderLibrary._warmed[f] = true
	if not silent:
		took_over = true
		_prev_paused = get_tree().paused
		get_tree().paused = true
		_build_quads()
	_last_tick = Time.get_ticks_usec()
	set_process(true)


func _process(_delta: float) -> void:
	if _silent:
		for i in SILENT_PER_FRAME:
			if _next >= _work.size():
				_finish()
				return
			LitShaderLibrary.get_receiver(_work[_next])
			_next += 1
		return

	# Whatever was assigned last frame has drawn by now: its pipelines are warm.
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
		get_tree().paused = _prev_paused
		if _quad_layer != null:
			_quad_layer.queue_free()
			_quad_layer = null
			_quads.clear()
	progress.emit(_work.size(), _work.size(), "")
	set_process(false)
	finished.emit()


func _write_marker() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("lit", "version", LitShaderLibrary._get_version())
	cfg.set_value("lit", "bundle", bundle_hash(_work))
	cfg.set_value("lit", "worklist", str(_work).md5_text())
	cfg.save(MARKER_PATH)


# 4x4 quads drawn behind the overlay's opaque cover, matching real receiver render
# state (default canvas_item vertex format and blend); their draw forces tier C.
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
