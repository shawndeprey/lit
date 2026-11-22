extends Label

## Perf readout shared by every scene the harness loads: FPS, frame time, render CPU and
## GPU ms averaged over 0.2 s (GPU reads n/a on ANGLE, which has no GL timer query),
## enabled Lit lights and draw calls. The Stats button or the H key toggles it.

var _accum := 0.0
var _frames := 0
var _cpu := 0.0
var _gpu := 0.0
var _gpu_timer: bool = not RenderingServer.get_video_adapter_name().begins_with("ANGLE")

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo() and event.keycode == KEY_H:
		toggle()

func toggle() -> void:
	visible = not visible

func _process(dt: float) -> void:
	if not visible:
		return
	var vp := get_viewport().get_viewport_rid()
	_frames += 1
	_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	_gpu += _gpu_ms(vp)
	_accum += dt
	if _accum < 0.2:
		return
	var fps := Engine.get_frames_per_second()
	var gpu_txt := ("%6.2f ms" % (_gpu / _frames)) if _gpu_timer else "   n/a"
	text = "FPS    %4d\nFrame  %6.2f ms\nCPU    %6.2f ms\nGPU    %s\nLights %4d\nDraws  %5d" % [
			roundi(fps), 1000.0 / maxf(fps, 1.0), _cpu / _frames, gpu_txt, _light_count(),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))]
	_accum = 0.0
	_frames = 0
	_cpu = 0.0
	_gpu = 0.0

func _light_count() -> int:
	var n := 0
	for l in get_tree().get_nodes_in_group("lit_lights"):
		if l.get("enabled") and l.is_visible_in_tree():
			n += 1
	return n

func _gpu_ms(vp: RID) -> float:
	var ms := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return ms if _gpu_timer and ms >= 0.0 and ms < 10000.0 else 0.0
