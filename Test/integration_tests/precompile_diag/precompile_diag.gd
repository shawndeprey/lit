extends Control
## Precompile diagnostics: runs the worker-backed shader precompile on launch and shows
## everything about it while it runs: overall progress, the hardware and the thread
## budget behind the worker count, the game process's own frame health, one card per
## worker (what it is compiling, how many cores it is using), and a timeline of every
## shader each worker baked.
##
## Keys: R runs it again, C clears Godot's compiled-shader cache first (the GPU driver's
## own cache stays, so this is a longer run, not a first-launch one), Esc quits.
## Options after "--":
##   cold=on        clear Godot's compiled-shader cache before the first run
##   quit=SECONDS   quit that long after the run finishes
##   capture=PATH   save the screen at half way (PATH) and at the end (PATH + "_done")
##
## Per-worker CPU, thread and memory figures come from a PowerShell sampler, so they are
## Windows-only; everywhere else those fields read "n/a" and the rest still works.

const Pre := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")

const BG := Color("0c0e12")
const PANEL := Color("161920")
const EDGE := Color("272c38")
const TRACK := Color("222733")
const TEXT := Color("e7eaf0")
const DIM := Color("8a92a3")
const ACCENT := Color("ffb454")
const GOOD := Color("5fd38d")
const WARN := Color("ffd166")
const BAD := Color("ff6b6b")

const SCAN_SEC := 0.15
const TEXT_SEC := 0.1
const STALL_MS := 50.0


# --- widgets ---------------------------------------------------------------------------

class Bar extends Control:
	var value := 0.0
	var color := Color.WHITE
	var _back := StyleBoxFlat.new()
	var _fill := StyleBoxFlat.new()

	func _init(height: float, fill: Color) -> void:
		custom_minimum_size = Vector2(0, height)
		color = fill
		for sb in [_back, _fill]:
			sb.set_corner_radius_all(int(height * 0.5))
		_back.bg_color = TRACK

	func set_value(v: float) -> void:
		v = clampf(v, 0.0, 1.0)
		if not is_equal_approx(v, value):
			value = v
			queue_redraw()

	func _draw() -> void:
		draw_style_box(_back, Rect2(Vector2.ZERO, size))
		if value > 0.0:
			_fill.bg_color = color
			draw_style_box(_fill, Rect2(Vector2.ZERO, Vector2(maxf(size.y, size.x * value), size.y)))


class Spark extends Control:
	var values := PackedFloat32Array()
	var capacity := 240
	var floor_top := 1.0
	var color := Color.WHITE
	var guides: Array = []  # [value, color]

	func push(v: float) -> void:
		values.append(v)
		if values.size() > capacity:
			values = values.slice(values.size() - capacity)
		queue_redraw()

	func top() -> float:
		var t := floor_top
		for v in values:
			t = maxf(t, v)
		return t

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), TRACK)
		var t := top()
		for g in guides:
			if g[0] <= t:
				var gy := size.y * (1.0 - float(g[0]) / t)
				draw_line(Vector2(0, gy), Vector2(size.x, gy), g[1], 1.0)
		if values.size() < 2:
			return
		var step := size.x / float(capacity - 1)
		var x0 := size.x - step * float(values.size() - 1)
		var line := PackedVector2Array()
		var fill := PackedVector2Array([Vector2(x0, size.y)])
		for i in values.size():
			var p := Vector2(x0 + step * i, size.y * (1.0 - minf(values[i] / t, 1.0)))
			line.append(p)
			fill.append(p)
		fill.append(Vector2(size.x, size.y))
		draw_colored_polygon(fill, Color(color, 0.18))
		draw_polyline(line, color, 1.5, true)


## One cell per hardware thread, grouped six to a worker.
class ThreadStrip extends Control:
	var threads := 0
	var launched := 0
	var colors: Array = []

	func _draw() -> void:
		if threads <= 0:
			return
		var per := Pre.THREADS_PER_WORKER
		var groups := int(ceil(float(threads) / per))
		var gap := 3.0
		var group_gap := 10.0
		var cell := minf(size.y, (size.x - group_gap * (groups - 1)) / float(threads) - gap)
		var x := 0.0
		for i in threads:
			var group := i / per
			if i > 0 and i % per == 0:
				x += group_gap
			var full_group := (group + 1) * per <= threads
			var c := EDGE
			if full_group and group < launched:
				c = colors[group % colors.size()]
			elif full_group:
				c = Color(DIM, 0.45)
			draw_rect(Rect2(x, (size.y - cell) * 0.5, cell, cell), c)
			x += cell + gap


class Timeline extends Control:
	var host: Control

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			host._hover_at((event as InputEventMouseMotion).position)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT and host != null:
			host._hover_at(Vector2(-1, -1))

	func _draw() -> void:
		host._draw_timeline(self)


class Slowest extends Control:
	var host: Control

	func _draw() -> void:
		host._draw_slowest(self)


# --- state -----------------------------------------------------------------------------

var _mgr: Node
var _work: Array = []
var _labels := {}
var _expected_workers := 1
var _state := "STARTING"
var _run_start := 0.0
var _run_end := -1.0
var _items := {}      # key -> {label, pid, start, end}
var _workers := {}    # pid -> {index, done, time}
var _order: Array[int] = []
var _proc := {}       # pid -> {cpu, at, cores, threads, mem, seen}
var _phys_cores := 0
var _stalls := 0
var _worst_ms := 0.0
var _frame_sum := 0.0
var _frame_n := 0
var _last_usec := 0
var _scan_at := 0.0
var _text_at := 0.0
var _clock := 0.0
var _hover_key := ""
var _blocks: Array = []   # [Rect2, key] of the last timeline draw

var _opt_quit := -1.0
var _opt_capture := ""
var _captured_half := false
var _quit_at := -1.0

var _sampler := {}
var _sampler_thread: Thread
var _sampler_lines: Array[String] = []
var _sampler_mutex := Mutex.new()

var _font: Font
var _cards: Array = []
var _ui := {}


func _ready() -> void:
	_font = get_theme_default_font()
	_mgr = get_node("/root/LitManager")
	var cold := false
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() == 2:
			match kv[0]:
				"cold":
					cold = kv[1] == "on"
				"quit":
					_opt_quit = float(kv[1])
				"capture":
					_opt_capture = kv[1]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_work = Pre.work_list()
	for item in _work:
		_labels[Pre.done_key(item)] = Pre.item_label(item)
	_expected_workers = Pre.worker_count(_work.size())
	_build_ui()
	_start_sampler()
	_mgr.precompile_finished.connect(_on_finished)
	# A startup precompile (takeover or async) may already be running: let it end first.
	if _mgr.precompiler != null and _mgr.precompiler.is_processing():
		_state = "WAITING FOR STARTUP PRECOMPILE"
		await _mgr.precompiler.finished
	# Let this screen's own first frames (fonts, UI pipelines) settle before measuring.
	await get_tree().create_timer(0.6).timeout
	_begin(cold)


func _exit_tree() -> void:
	if not _sampler.is_empty():
		OS.kill(_sampler.pid)
	if _sampler_thread != null:
		_sampler_thread.wait_to_finish()


func _begin(cold: bool) -> void:
	if cold:
		_clear_godot_cache()
	_items.clear()
	_workers.clear()
	_order.clear()
	_blocks.clear()
	_hover_key = ""
	_stalls = 0
	_worst_ms = 0.0
	_frame_sum = 0.0
	_frame_n = 0
	_run_end = -1.0
	_captured_half = false
	_run_start = Time.get_unix_time_from_system()
	_state = "BAKING" if _mgr.precompile_shaders() else "BUSY"
	_last_usec = 0  # the setup above is not a frame of the run
	_layout_cards()


func _on_finished() -> void:
	if _state != "BAKING":
		return
	_scan()
	_run_end = Time.get_unix_time_from_system()
	_state = "DONE" if _done_count() >= _work.size() else "INCOMPLETE"
	if _opt_quit >= 0.0:
		_quit_at = _clock + _opt_quit
	_refresh()
	if _opt_capture != "":
		_capture.call_deferred(_opt_capture.get_basename() + "_done." + _opt_capture.get_extension())


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_ESCAPE:
			get_tree().quit()
		KEY_R:
			if _state != "BAKING":
				_begin(false)
		KEY_C:
			if _state != "BAKING":
				_begin(true)


# Godot's compiled canvas shaders and Lit's marker. The GPU driver keeps its own cache
# elsewhere; this does not touch it.
func _clear_godot_cache() -> void:
	var root := ProjectSettings.globalize_path("user://shader_cache/CanvasShaderRD")
	for d in DirAccess.get_directories_at(root):
		for f in DirAccess.get_files_at(root.path_join(d)):
			DirAccess.remove_absolute(root.path_join(d).path_join(f))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Pre.MARKER_PATH))


# --- data ------------------------------------------------------------------------------

# Seconds into the current run; 0 until a run has started.
func _now() -> float:
	if _run_start <= 0.0:
		return 0.0
	return maxf((_run_end if _run_end >= 0.0 else Time.get_unix_time_from_system()) - _run_start, 0.0)


func _done_count() -> int:
	var n := 0
	for key in _items:
		if _items[key].end >= 0.0:
			n += 1
	return n


func _worker(pid: int) -> Dictionary:
	if not _workers.has(pid):
		_workers[pid] = {"index": _order.size(), "done": 0, "time": 0.0}
		_order.append(pid)
		_layout_cards()
	return _workers[pid]


# Claims and done-files of this run, read straight from the worker directory.
func _scan() -> void:
	var wd := ProjectSettings.globalize_path(Pre.WORKER_DIR)
	for d in DirAccess.get_directories_at(wd):
		var key := d.trim_suffix(".claim")
		if _items.has(key) or not _labels.has(key):
			continue
		var files := DirAccess.get_files_at(wd.path_join(d))
		if files.is_empty():
			continue
		var start := FileAccess.get_file_as_string(wd.path_join(d).path_join(files[0])).to_float()
		if start < _run_start - 0.5:
			continue
		_items[key] = {"label": _labels[key], "pid": int(files[0]), "start": start - _run_start, "end": -1.0}
		_worker(int(files[0]))
	for f in DirAccess.get_files_at(wd):
		if not f.ends_with(".done"):
			continue
		var key := f.trim_suffix(".done")
		if not _labels.has(key) or (_items.has(key) and _items[key].end >= 0.0):
			continue
		var parts := FileAccess.get_file_as_string(wd.path_join(f)).split(" ")
		if parts.size() != 3 or parts[1].to_float() < _run_start - 0.5:
			continue
		var pid := int(parts[0])
		var item := {"label": _labels[key], "pid": pid, "start": parts[1].to_float() - _run_start,
				"end": parts[2].to_float() - _run_start}
		_items[key] = item
		var w := _worker(pid)
		w.done += 1
		w.time += item.end - item.start


func _start_sampler() -> void:
	if OS.get_name() != "Windows":
		return
	var script := ("$n='%s';" % OS.get_executable_path().get_file().get_basename().replace("'", "''")) \
			+ "$c=(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum;" \
			+ "[Console]::Out.WriteLine('H ' + $c);" \
			+ "while($true){$t=[DateTime]::UtcNow.Ticks;" \
			+ "foreach($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)){" \
			+ "[Console]::Out.WriteLine('P ' + $t + ' ' + $p.Id + ' ' + $p.TotalProcessorTime.Ticks + ' ' + $p.Threads.Count + ' ' + $p.WorkingSet64)};" \
			+ "[Console]::Out.Flush();Start-Sleep -Milliseconds 500}"
	_sampler = OS.execute_with_pipe("powershell.exe", PackedStringArray(["-NoProfile", "-NonInteractive",
			"-EncodedCommand", Marshalls.raw_to_base64(script.to_utf16_buffer())]))
	if _sampler.is_empty():
		return
	_sampler_thread = Thread.new()
	_sampler_thread.start(_sampler_loop.bind(_sampler.stdio))


func _sampler_loop(pipe: FileAccess) -> void:
	while pipe.is_open() and pipe.get_error() == OK:
		var line := pipe.get_line()
		if line.is_empty():
			if pipe.get_error() != OK:
				break
			OS.delay_msec(20)
			continue
		_sampler_mutex.lock()
		_sampler_lines.append(line)
		_sampler_mutex.unlock()


func _drain_sampler() -> void:
	_sampler_mutex.lock()
	var lines := _sampler_lines.duplicate()
	_sampler_lines.clear()
	_sampler_mutex.unlock()
	for line: String in lines:
		var p := line.strip_edges().split(" ")
		if p[0] == "H" and p.size() == 2:
			_phys_cores = int(p[1])
		elif p[0] == "P" and p.size() == 6:
			var pid := int(p[2])
			var at := float(p[1]) / 1e7
			var cpu := float(p[3]) / 1e7
			var prev: Dictionary = _proc.get(pid, {})
			var cores := 0.0
			if not prev.is_empty() and at > prev.at:
				cores = maxf((cpu - prev.cpu) / (at - prev.at), 0.0)
			_proc[pid] = {"cpu": cpu, "at": at, "cores": cores, "threads": int(p[4]),
					"mem": float(p[5]) / 1048576.0, "seen": _clock}
			if _workers.has(pid):
				(_cards[_workers[pid].index].spark as Spark).push(cores)
			elif pid == OS.get_process_id():
				(_ui.game_cpu as Spark).push(cores)


# --- frame loop ------------------------------------------------------------------------

func _process(delta: float) -> void:
	_clock += delta
	var now := Time.get_ticks_usec()
	if _last_usec != 0:
		var ms := float(now - _last_usec) / 1000.0
		(_ui.frames as Spark).push(ms)
		if _state == "BAKING":
			_frame_sum += ms
			_frame_n += 1
			_worst_ms = maxf(_worst_ms, ms)
			if ms > STALL_MS:
				_stalls += 1
	_last_usec = now
	(_ui.pulse as Control).rotation = _clock * 3.0

	_drain_sampler()
	if _state == "BUSY" and _mgr.precompile_shaders():
		_state = "BAKING"
		_run_start = Time.get_unix_time_from_system()
	if _state == "BAKING" and _clock - _scan_at >= SCAN_SEC:
		_scan_at = _clock
		_scan()
	if _clock - _text_at >= TEXT_SEC:
		_text_at = _clock
		_refresh()
	if _opt_capture != "" and not _captured_half and _done_count() * 2 >= _work.size():
		_captured_half = true
		_capture.call_deferred(_opt_capture)
	if _quit_at >= 0.0 and _clock >= _quit_at:
		get_tree().quit()


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	_last_usec = 0  # saving the image is this tool's own cost, not a frame of the run


# --- text + bars -----------------------------------------------------------------------

static func _clock_text(sec: float) -> String:
	return "%d:%04.1f" % [int(sec) / 60, fmod(sec, 60.0)]


func _worker_color(index: int) -> Color:
	return Color.from_hsv(fmod(0.08 + index * 0.618034, 1.0), 0.55, 0.96)


func _refresh() -> void:
	var total := _work.size()
	var done := _done_count()
	var now := _now()
	var running := _state == "BAKING"

	var state_color := ACCENT
	if _state == "DONE":
		state_color = GOOD
	elif _state == "INCOMPLETE":
		state_color = BAD
	(_ui.state as Label).text = _state
	(_ui.state as Label).add_theme_color_override("font_color", state_color)
	(_ui.elapsed as Label).text = _clock_text(now) if _state != "STARTING" else "0:00.0"

	(_ui.percent as Label).text = "%d%%" % int(100.0 * done / maxf(total, 1))
	(_ui.overall as Bar).set_value(float(done) / maxf(total, 1))
	(_ui.overall as Bar).color = state_color
	var in_flight := _items.size() - done
	var variants := 0
	for item in _work:
		if item is int:
			variants += 1
	var rate := done / maxf(now, 0.001)
	var eta := "-"
	if running and done > 0:
		eta = _clock_text((total - done) / rate)
	elif not running and _run_end >= 0.0:
		eta = "finished"
	(_ui.counts as Label).text = "%d of %d items   ·   %d compiling   ·   %d queued" \
			% [done, total, in_flight, total - _items.size()]
	(_ui.overall_stats as Label).text = \
			"List          %d receiver variants + %d shader files%s\nRate          %.2f items / s\nETA           %s\nMarker        %s" % [
			variants, total - variants,
			"   (from lit_precompile.cfg)" if FileAccess.file_exists(Pre.CONFIG_PATH) else "   (full matrix)",
			rate, eta,
			"written" if FileAccess.file_exists(Pre.MARKER_PATH) else "not written yet"]

	# Hardware
	var threads := OS.get_processor_count()
	var by_rule := maxi(threads / Pre.THREADS_PER_WORKER, 1)
	var cap := int(ProjectSettings.get_setting(Pre.SETTING_MAX_WORKERS, Pre.DEFAULT_MAX_WORKERS))
	(_ui.hw as Label).text = "%s\n%s cores   ·   %d threads\n%s   ·   %s" % [
			OS.get_processor_name(), str(_phys_cores) if _phys_cores > 0 else "n/a", threads,
			RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_driver_name()]
	(_ui.rule as Label).text = \
			"%d threads / %d per worker = %d   ·   cap %d   ·   %d items\nLaunched %d worker%s, each allowed up to %d threads" % [
			threads, Pre.THREADS_PER_WORKER, by_rule, cap, total,
			_expected_workers, "" if _expected_workers == 1 else "s", Pre.THREADS_PER_WORKER]
	var strip := _ui.strip as ThreadStrip
	if strip.threads != threads or strip.launched != _expected_workers:
		strip.threads = threads
		strip.launched = _expected_workers
		strip.colors = []
		for i in _expected_workers:
			strip.colors.append(_worker_color(i))
		strip.queue_redraw()

	# Game process
	var me: Dictionary = _proc.get(OS.get_process_id(), {})
	var vp := get_viewport().get_viewport_rid()
	var frames := _ui.frames as Spark
	var last_ms := frames.values[-1] if not frames.values.is_empty() else 0.0
	(_ui.fps as Label).text = "%d fps" % Engine.get_frames_per_second()
	(_ui.game_stats as Label).text = \
			"Frame         %.2f ms now   ·   %.2f ms avg\nWorst         %.1f ms   ·   %d stall%s over %d ms\nRender        cpu %.2f ms   ·   gpu %.2f ms\nProcess       %s" % [
			last_ms, _frame_sum / maxf(_frame_n, 1), _worst_ms, _stalls, "" if _stalls == 1 else "s", int(STALL_MS),
			RenderingServer.viewport_get_measured_render_time_cpu(vp),
			RenderingServer.viewport_get_measured_render_time_gpu(vp),
			("%.1f cores busy   ·   %d threads   ·   %d MB" % [me.cores, me.threads, int(me.mem)]) if not me.is_empty() else "n/a"]
	(_ui.game_stats as Label).add_theme_color_override("font_color", BAD if _stalls > 0 else TEXT)

	# Workers
	for i in _cards.size():
		var card: Dictionary = _cards[i]
		var color := _worker_color(i)
		if i >= _order.size():
			(card.title as Label).text = "WORKER %d" % (i + 1)
			(card.state as Label).text = "STARTING" if running else "-"
			(card.state as Label).add_theme_color_override("font_color", DIM)
			(card.now as Label).text = "waiting for its first claim"
			(card.stats as Label).text = ""
			(card.bar as Bar).set_value(0.0)
			continue
		var pid: int = _order[i]
		var w: Dictionary = _workers[pid]
		var current: Array[String] = []
		var since := 0.0
		for key in _items:
			var item: Dictionary = _items[key]
			if item.pid == pid and item.end < 0.0:
				current.append(item.label)
				since = maxf(since, now - item.start)
		var ps: Dictionary = _proc.get(pid, {})
		var alive := not ps.is_empty() and _clock - float(ps.seen) < 2.0
		var st := "COMPILING"
		var st_color := color
		if not running or (not alive and not ps.is_empty()):
			st = "EXITED"
			st_color = DIM
		elif current.is_empty():
			st = "BETWEEN ITEMS"
			st_color = DIM
		(card.title as Label).text = "WORKER %d" % (i + 1)
		(card.pid as Label).text = "pid %d" % pid
		(card.state as Label).text = st
		(card.state as Label).add_theme_color_override("font_color", st_color)
		(card.bar as Bar).color = color
		(card.bar as Bar).set_value(float(w.done) / maxf(float(total) / maxf(_expected_workers, 1), 1.0))
		(card.share as Label).text = "%d items   ·   %d%% of the bake" % [w.done, int(100.0 * w.done / maxf(total, 1))]
		if current.is_empty():
			(card.now as Label).text = "-"
		else:
			(card.now as Label).text = "%s   (%.1f s)%s" % [current[0], since,
					"   +%d more" % (current.size() - 1) if current.size() > 1 else ""]
		(card.stats as Label).text = "%s\navg %.2f s / item" % [
				("%.1f cores busy   ·   %d threads   ·   %d MB" % [ps.cores, ps.threads, int(ps.mem)]) if alive else "cpu n/a",
				w.time / maxf(w.done, 1)]

	(_ui.timeline as Control).queue_redraw()
	(_ui.slowest as Control).queue_redraw()
	if _hover_key != "" and _items.has(_hover_key):
		var item: Dictionary = _items[_hover_key]
		(_ui.hover as Label).text = "%s   ·   worker %d   ·   %s" % [item.label, _workers[item.pid].index + 1,
				("%.2f s" % (item.end - item.start)) if item.end >= 0.0 else "compiling for %.1f s" % (now - item.start)]
	else:
		(_ui.hover as Label).text = "Hover a block to see the shader.   R run again   ·   C clear Godot's shader cache and run   ·   Esc quit"


func _hover_at(pos: Vector2) -> void:
	_hover_key = ""
	for block in _blocks:
		if (block[0] as Rect2).has_point(pos):
			_hover_key = block[1]


func _draw_timeline(c: Control) -> void:
	_blocks.clear()
	var lanes := maxi(_order.size(), _expected_workers)
	var left := 44.0
	var bottom := 22.0
	var span := maxf(_now(), 4.0)
	var w := c.size.x - left
	var lane_h := minf((c.size.y - bottom) / float(lanes), 84.0)
	var step := 1.0
	for candidate: float in [1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0, 120.0, 300.0, 600.0]:
		step = candidate
		if span / candidate <= 12.0:
			break
	step = maxf(step, span / 12.0)  # never more than a dozen ticks, whatever the span
	var t := 0.0
	while t <= span:
		var x := left + w * t / span
		c.draw_line(Vector2(x, 0), Vector2(x, lane_h * lanes), EDGE, 1.0)
		c.draw_string(_font, Vector2(x + 3, lane_h * lanes + 16), "%ds" % int(t), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DIM)
		t += step
	for i in lanes:
		var y := lane_h * i
		c.draw_string(_font, Vector2(0, y + lane_h * 0.5 + 5), "W%d" % (i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, _worker_color(i))
		c.draw_rect(Rect2(left, y + 4, w, lane_h - 8), TRACK)
	for key in _items:
		var item: Dictionary = _items[key]
		var i: int = _workers[item.pid].index
		var end: float = item.end if item.end >= 0.0 else _now()
		var r := Rect2(left + w * item.start / span, lane_h * i + 6,
				maxf(w * (end - item.start) / span - 1.0, 1.5), lane_h - 12)
		var color := _worker_color(i)
		if item.end < 0.0:
			color = Color(color, 0.45 + 0.25 * sin(_clock * 6.0))
		elif key == _hover_key:
			color = color.lightened(0.35)
		c.draw_rect(r, color)
		_blocks.append([r, key])


func _draw_slowest(c: Control) -> void:
	var done: Array = []
	for key in _items:
		if _items[key].end >= 0.0:
			done.append(_items[key])
	done.sort_custom(func(a, b): return a.end - a.start > b.end - b.start)
	var row := 30.0
	var top := 0.0
	for n in mini(done.size(), int(c.size.y / row)):
		var item: Dictionary = done[n]
		var dur: float = item.end - item.start
		var y := row * n
		if n == 0:
			top = maxf(dur, 0.001)
		c.draw_rect(Rect2(0, y + 19, c.size.x, 5), TRACK)
		c.draw_rect(Rect2(0, y + 19, c.size.x * dur / top, 5), _worker_color(_workers[item.pid].index))
		c.draw_string(_font, Vector2(0, y + 14), item.label, HORIZONTAL_ALIGNMENT_LEFT, c.size.x - 70, 13, TEXT)
		c.draw_string(_font, Vector2(c.size.x - 66, y + 14), "%.2f s" % dur, HORIZONTAL_ALIGNMENT_RIGHT, 66, 13, DIM)


# --- layout ----------------------------------------------------------------------------

func _label(text: String, font_size: int, color: Color, parent: Node) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.clip_text = true
	parent.add_child(l)
	return l


func _panel(title: String, parent: Node, stretch: float) -> VBoxContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.border_color = EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = stretch
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	if title != "":
		_label(title, 13, DIM, box)
	return box


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 26)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	# Header
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	root.add_child(header)
	var pulse_holder := Control.new()
	pulse_holder.custom_minimum_size = Vector2(26, 26)
	pulse_holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(pulse_holder)
	var pulse := ColorRect.new()
	pulse.color = ACCENT
	pulse.size = Vector2(16, 16)
	pulse.position = Vector2(5, 5)
	pulse.pivot_offset = Vector2(8, 8)
	pulse_holder.add_child(pulse)
	_ui.pulse = pulse
	_label("LIT  ·  SHADER PRECOMPILE DIAGNOSTICS", 24, TEXT, header).clip_text = false
	_ui.state = _label(_state, 18, ACCENT, header)
	_ui.state.clip_text = false
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_ui.elapsed = _label("0:00.0", 30, TEXT, header)
	_ui.elapsed.clip_text = false

	# Row A: overall, hardware, game process
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 14)
	row_a.custom_minimum_size = Vector2(0, 262)
	root.add_child(row_a)

	var overall := _panel("OVERALL", row_a, 1.25)
	var big := HBoxContainer.new()
	big.add_theme_constant_override("separation", 18)
	overall.add_child(big)
	_ui.percent = _label("0%", 46, TEXT, big)
	_ui.percent.clip_text = false
	_ui.counts = _label("", 16, DIM, big)
	_ui.counts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ui.counts.size_flags_vertical = Control.SIZE_SHRINK_END
	_ui.overall = Bar.new(18, ACCENT)
	overall.add_child(_ui.overall)
	_ui.overall_stats = _label("", 15, TEXT, overall)

	var hw := _panel("HARDWARE AND THREAD BUDGET", row_a, 1.0)
	_ui.hw = _label("", 15, TEXT, hw)
	_ui.strip = ThreadStrip.new()
	_ui.strip.custom_minimum_size = Vector2(0, 26)
	hw.add_child(_ui.strip)
	_ui.rule = _label("", 15, TEXT, hw)
	_label("A coloured block of six is one worker's threads; grey is headroom the cap left unused.", 13, DIM, hw) \
			.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var game := _panel("GAME PROCESS (THIS WINDOW)", row_a, 1.25)
	var game_top := HBoxContainer.new()
	game_top.add_theme_constant_override("separation", 16)
	game.add_child(game_top)
	_ui.fps = _label("0 fps", 30, TEXT, game_top)
	_ui.fps.clip_text = false
	_ui.fps.custom_minimum_size = Vector2(150, 0)
	_ui.frames = Spark.new()
	_ui.frames.capacity = 420
	_ui.frames.floor_top = 20.0
	_ui.frames.color = GOOD
	_ui.frames.guides = [[16.7, Color(DIM, 0.5)], [STALL_MS, Color(BAD, 0.7)]]
	_ui.frames.custom_minimum_size = Vector2(0, 58)
	_ui.frames.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_top.add_child(_ui.frames)
	_ui.game_stats = _label("", 15, TEXT, game)
	var cpu_row := HBoxContainer.new()
	cpu_row.add_theme_constant_override("separation", 12)
	game.add_child(cpu_row)
	_label("cores busy", 13, DIM, cpu_row).clip_text = false
	_ui.game_cpu = Spark.new()
	_ui.game_cpu.capacity = 120
	_ui.game_cpu.floor_top = 2.0
	_ui.game_cpu.color = ACCENT
	_ui.game_cpu.custom_minimum_size = Vector2(0, 30)
	_ui.game_cpu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cpu_row.add_child(_ui.game_cpu)

	# Row B: workers
	var workers := _panel("WORKERS", root, 1.0)
	workers.get_parent().size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_ui.grid = GridContainer.new()
	_ui.grid.add_theme_constant_override("h_separation", 14)
	_ui.grid.add_theme_constant_override("v_separation", 12)
	workers.add_child(_ui.grid)

	# Row C: timeline and slowest shaders
	var row_c := HBoxContainer.new()
	row_c.add_theme_constant_override("separation", 14)
	row_c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(row_c)
	var tl := _panel("TIMELINE  ·  ONE LANE PER WORKER, ONE BLOCK PER SHADER", row_c, 3.0)
	_ui.timeline = Timeline.new()
	_ui.timeline.host = self
	_ui.timeline.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tl.add_child(_ui.timeline)
	_ui.hover = _label("", 14, DIM, tl)
	var slow := _panel("SLOWEST SHADERS", row_c, 1.0)
	_ui.slowest = Slowest.new()
	_ui.slowest.host = self
	_ui.slowest.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slow.add_child(_ui.slowest)
	_layout_cards()


# One card per expected worker (more if more show up); compact once they need two rows.
func _layout_cards() -> void:
	var want := maxi(_expected_workers, _order.size())
	var grid := _ui.grid as GridContainer
	grid.columns = want if want <= 4 else (4 if want <= 8 else 8)
	while _cards.size() < want:
		var index := _cards.size()
		var holder := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = BG
		sb.border_color = Color(_worker_color(index), 0.55)
		sb.set_border_width_all(1)
		sb.border_width_top = 3
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(12)
		holder.add_theme_stylebox_override("panel", sb)
		holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(holder)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 6)
		holder.add_child(box)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 10)
		box.add_child(head)
		var card := {}
		card.title = _label("WORKER %d" % (index + 1), 17, _worker_color(index), head)
		card.title.clip_text = false
		card.pid = _label("", 13, DIM, head)
		card.pid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.state = _label("", 13, DIM, head)
		card.state.clip_text = false
		card.bar = Bar.new(10, _worker_color(index))
		box.add_child(card.bar)
		card.share = _label("", 13, DIM, box)
		card.now = _label("", 15, TEXT, box)
		card.spark = Spark.new()
		card.spark.capacity = 120
		card.spark.floor_top = float(Pre.THREADS_PER_WORKER)
		card.spark.color = _worker_color(index)
		card.spark.guides = [[1.0, Color(DIM, 0.4)]]
		card.spark.custom_minimum_size = Vector2(0, 40)
		box.add_child(card.spark)
		card.stats = _label("", 13, DIM, box)
		_cards.append(card)
	for card in _cards:
		(card.spark as Control).visible = want <= 8
