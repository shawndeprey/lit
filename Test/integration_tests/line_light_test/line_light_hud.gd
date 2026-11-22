extends Label

## Bench driver for the line light scenes (on-screen stats come from the integration test
## harness). `-- bench=on` averages BENCH_MEASURE s after BENCH_WARMUP s, prints LITBENCH
## lines and quits; `capture=PATH` saves the frame first.

const BENCH_WARMUP := 3.0
const BENCH_MEASURE := 6.0

# ANGLE has no GL timer query, so Godot reports 0 (or garbage) GPU time there.
var _gpu_timer: bool = not RenderingServer.get_video_adapter_name().begins_with("ANGLE")
var _last_usec := 0
var _bench := false
var _capture := ""
var _bench_time := 0.0
var _bench_gpu := 0.0
var _bench_cpu := 0.0
var _bench_frames := 0

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	for arg in OS.get_cmdline_user_args():
		if arg == "bench=on":
			_bench = true
		elif arg.begins_with("capture="):
			_capture = arg.trim_prefix("capture=")

func _process(_dt: float) -> void:
	var now := Time.get_ticks_usec()
	var wall := float(now - _last_usec) / 1000000.0 if _last_usec != 0 else 0.0
	_last_usec = now
	if _bench:
		_bench_step(wall, get_viewport().get_viewport_rid())

func _bench_step(wall: float, vp: RID) -> void:
	if wall > 1.0:
		# A shader compile stall (cold GL / ANGLE cache) restarts the warmup instead of counting as frames.
		_bench_time = 0.0
		_bench_frames = 0
		_bench_gpu = 0.0
		_bench_cpu = 0.0
		return
	_bench_time += wall
	if _bench_time < BENCH_WARMUP:
		return
	_bench_frames += 1
	_bench_gpu += _gpu_ms(vp)
	_bench_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	if _bench_time < BENCH_WARMUP + BENCH_MEASURE:
		return
	_bench = false
	var n := float(_bench_frames)
	print("LITBENCH render_gpu_ms=%s" % (("%.3f" % (_bench_gpu / n)) if _gpu_timer else "n/a"))
	print("LITBENCH render_cpu_ms=%.3f" % (_bench_cpu / n))
	print("LITBENCH avg_fps=%.1f" % (n / (_bench_time - BENCH_WARMUP)))
	if _capture != "":
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(_capture)
		print("LITBENCH capture=%s" % _capture)
	get_tree().quit()


func _gpu_ms(vp: RID) -> float:
	var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return ms if _gpu_timer and ms >= 0.0 and ms < 10000.0 else 0.0
