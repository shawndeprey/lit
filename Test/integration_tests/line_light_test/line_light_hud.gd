extends Label

## Half-second rolling averages of the numbers the bench tracks, plus the camera zoom.

const WINDOW := 0.5

var _last_usec := 0
var _elapsed := 0.0
var _worst := 0.0
var _proc := 0.0
var _render_cpu := 0.0
var _render_gpu := 0.0
var _draws := 0
var _count := 0

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	var wall := float(now - _last_usec) / 1000000.0 if _last_usec != 0 else 0.0
	_last_usec = now
	var vp := get_viewport().get_viewport_rid()
	_elapsed += wall
	_worst = maxf(_worst, wall)
	_proc += Performance.get_monitor(Performance.TIME_PROCESS)
	_render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	_render_gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	_draws = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_count += 1
	if _elapsed < WINDOW:
		return
	var n := float(_count)
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else 1.0
	text = "fps %d   frame %.2f ms   worst %.1f ms\nprocess %.2f ms   render cpu %.2f ms   gpu %.2f ms\ndraw calls %d   zoom %.2f" % [
			Engine.get_frames_per_second(), _elapsed / n * 1000.0, _worst * 1000.0,
			_proc / n * 1000.0, _render_cpu / n, _render_gpu / n, _draws, zoom]
	_elapsed = 0.0
	_worst = 0.0
	_proc = 0.0
	_render_cpu = 0.0
	_render_gpu = 0.0
	_count = 0
