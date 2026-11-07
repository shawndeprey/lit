extends "res://Test/integration_tests/line_light_review/demo_base.gd"

## Walkthrough of issue 4: the precompiler's dedupe() folds away the fast-tier ramp shader
## variants, but the game still requests them, so they compile mid-game after a precompile.
## See checks/04_precompile_ramp_twin_check.gd for the automated version.

class WarningCatcher extends Logger:
	var lines: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_mutex.lock()
		lines.append((code + " " + rationale).strip_edges())
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> PackedStringArray:
		_mutex.lock()
		var out := lines.duplicate()
		lines.clear()
		_mutex.unlock()
		return out


const SCENE_RECT := Rect2(940, 64, 960, 420)
const LIGHT_POS := Vector2(1260, 300)

var _catcher := WarningCatcher.new()
var _floor: LitSprite2D
var _post: LitSprite2D
var _light: LitPointLight2D
var _table: VariantTable
var _console: RichTextLabel
var _graph: Graph
var _ramp_lbl: Label
var _variant_lbl: Label
var _countdown: Label
var _spike_lbl: Label
var _last_usec := 0
var _switched := false
var _switch_t := 0.0
var _peak := 0.0
var _warned := false
var _bug_peak := -1.0
var _prev_vsync := DisplayServer.VSYNC_ENABLED


func demo_title() -> String:
	return "Issue 4 - Precompile folds away shader variants the game still asks for"


func build() -> void:
	OS.add_logger(_catcher)
	_prev_vsync = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_floor = floor_receiver(SCENE_RECT)
	_light = point_light(LIGHT_POS, 420.0, 0.9, Color.WHITE, 80.0)
	_light.shadow_enabled = true
	_light.shadow_algorithm = ALGO.RAYMARCHED
	# The post and its occluder share their own group: the occluder is the post's sibling
	# (so the post's shadow_ramp applies to it), not the floor's (the floor stays on the
	# fast tier - the tier whose ramp variants were folded away).
	var props := group("Props")
	_post = box_receiver(LIGHT_POS + Vector2(60, 120), Vector2(8, 8), Color.WHITE, props)
	_post.specular_strength = 0.0
	occluder(LIGHT_POS + Vector2(100, 0), Vector2(16, 120), props)
	panel(SCENE_RECT, "neutral", "a running scene: floor, point light, and a receiver beside an occluder")
	panel(Rect2(20, 64, 900, 800), "neutral", "shader variants: what the precompiler builds")
	_ramp_lbl = readout(SCENE_RECT.position + Vector2(20, 50), 26, C_NOTE)
	_variant_lbl = readout(SCENE_RECT.position + Vector2(20, 90), 22, C_TEXT)
	_countdown = readout(SCENE_RECT.position + Vector2(620, 300), 64, C_NOTE)
	_table = VariantTable.new()
	_table.demo = self
	_ui.add_child(_table)
	_table.setup()
	_graph = graph(Rect2(1000, 540, 420, 215))
	_graph.title = "frame time (ms)"
	_graph.y_min = 0.0
	_graph.y_max = 40.0
	_graph.y_ticks = [[0.0, "0"], [16.7, "16.7"], [33.3, "33.3"]]
	_graph.x_label = "seconds in this step"
	_graph.add_series("frame time", C_NOTE)
	_spike_lbl = _ui_label("", Vector2(1000, 834), 18, C_NOTE)
	var cbg := ColorRect.new()
	cbg.color = Color(0.02, 0.02, 0.03, 0.97)
	cbg.position = Vector2(1450, 520)
	cbg.size = Vector2(440, 300)
	_ui.add_child(cbg)
	_ui_label("console (warnings Lit printed)", Vector2(1456, 494), 16, C_DIM)
	_console = RichTextLabel.new()
	_console.bbcode_enabled = true
	_console.position = Vector2(1460, 528)
	_console.size = Vector2(420, 284)
	_console.add_theme_font_size_override("normal_font_size", 15)
	_console.add_theme_color_override("default_color", Color(1, 0.8, 0.4))
	_ui.add_child(_console)

	add_step("What precompiling is for",
			"Compiling a shader the first time something needs it causes a %s. Lit can build every receiver shader variant up front (%s) so gameplay never compiles one. Left: a few variants and whether the precompiler builds them. Right: a running scene; its floor uses %s." % [
			y("frame hitch"), code("LitShaderPrecompiler"), code("lit_receiver_fast")],
			10.0, _s_intro, _s_intro_tick)
	add_step("Run the precompile pass",
			"The real silent precompile pass runs - what every launch after a precompile does. New in this PR, %s drops each %s whose full-tier twin is in the list, because the two compile to the same GPU code. The %s rows are never built. That would be fine if the game asked for the twin instead - but it doesn't." % [
			code("dedupe()"), y("\"_ramp\" variant"), r("FOLDED AWAY")],
			8.0, _s_precompile, _s_precompile_tick)
	add_step("BEFORE / AFTER: a shadow ramp turns on",
			"%s: shadow_ramp 0, steady frame times. %s: the receiver's %s is set to 100 (it softens shadows behind it). Lit moves the floor to %s - one of the folded variants. Lit's own bookkeeping says it was never built, so it creates and compiles it %s and prints the %s warning (console), telling you to regenerate the config - which cannot fix it. Note the frame-time spike; the next step shows how much of it is this bug." % [
			y("BEFORE"), y("AFTER"), code("shadow_ramp"), code("lit_receiver_fast_ramp"), r("on the main thread, mid-game"),
			r("\"compiled mid-game\"")],
			14.0, _s_bug, _s_bug_tick)
	add_step("Expected: the same switch with the variant built",
			"The same switch, on Cone Traced shadows, after %s by also building the folded twin (%s) during loading. When the ramp turns on, the floor moves to a variant that already exists: %s. The frame-time spike is only a little smaller: most of it is the GPU pipeline being built on first draw, which the silent pass skips for every variant. So the bug's real cost is %s plus a few ms of main-thread shader setup (9-11 ms when measured in isolation by the check scene)." % [
			g("simulating a fix"), code("lit_receiver_cone_fast_ramp"), g("no warning"), r("a misleading warning you cannot get rid of")],
			14.0, _s_fixed, _s_fixed_tick)
	add_step("Why regenerating the config doesn't help",
			"%s reads %s but runs %s on it too. A config that lists both twins (left box) comes out with only one - the ramp variant is dropped again, and the warning returns on the next run." % [
			code("work_list()"), code("res://lit_precompile.cfg"), code("dedupe()")],
			10.0, _s_config, _s_plain_tick)
	add_step("Summary",
			"%s folds %s into %s, but %s keeps F_RAMP on the fast tier, so the request is a different key in %s and misses. Fix: make %s return the twin's Shader for a folded ramp variant (one line), or mark and instantiate the twin under both keys in %s / the silent pass." % [
			code("LitShaderPrecompiler.dedupe()"), code("F_RAMP | X"), code("F_SELF_EXCL | X"), code("LitShaderLibrary._prune()"),
			code("_receivers"), code("get_receiver()"), code("_mark_warmed()")],
			10.0, _s_summary, _s_plain_tick)


func _exit_tree() -> void:
	OS.remove_logger(_catcher)
	DisplayServer.window_set_vsync_mode(_prev_vsync)
	super()


# --- Helpers ------------------------------------------------------------------------------

func floor_variant() -> int:
	return LitShaderLibrary.flags_of((_floor.material as ShaderMaterial).shader)


func _poll_console() -> void:
	for l in _catcher.take():
		if l.contains("Lit"):
			_warned = _warned or l.contains("compiled mid-game")
			_console.append_text("[color=#ffb84d]WARNING:[/color] %s\n\n" % l)


func _frame_tick(t: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec != 0:
		var ms := float(now - _last_usec) / 1000.0
		_graph.push("frame time", t, ms)
		if _switched and t - _switch_t < 1.0:
			_peak = maxf(_peak, ms)
	_last_usec = now
	_variant_lbl.text = "floor shader: %s" % LitShaderLibrary.variant_name(floor_variant())
	_ramp_lbl.text = "receiver shadow_ramp = %d" % roundi(_post.shadow_ramp)
	_poll_console()
	_table.queue_redraw()


func _reset_graph(secs: float) -> void:
	_graph.clear_points()
	_graph.x_min = 0.0
	_graph.x_max = secs
	_graph.x_ticks = [[0.0, "0"], [secs * 0.5, "%d" % roundi(secs * 0.5)], [secs, "%d" % roundi(secs)]]
	_last_usec = 0
	_switched = false
	_peak = 0.0


## Forget a cached variant so the next request is a fresh miss (makes steps replayable).
func _forget(flags: int) -> void:
	var sh: Shader = LitShaderLibrary._receivers.get(flags)
	if sh != null:
		LitShaderLibrary._flags_by_id.erase(sh.get_instance_id())
		LitShaderLibrary._receivers.erase(flags)


func _ensure_precompiled() -> void:
	if not LitShaderLibrary._warmed.is_empty():
		return
	var pre := LitShaderPrecompiler.new()
	add_child(pre)
	pre.start(true)


func _countdown_to(f: float, at: float) -> bool:
	if f < at:
		var left := ceili((at - f) / at * 3.0)
		_countdown.text = str(clampi(left, 1, 3))
		return false
	_countdown.text = ""
	return true


# --- Steps --------------------------------------------------------------------------------

func _s_intro() -> void:
	_post.shadow_ramp = 0.0
	_light.shadow_algorithm = ALGO.RAYMARCHED
	_reset_graph(10.0)
	_countdown.text = ""
	_spike_lbl.text = ""


func _s_intro_tick(_f: float, t: float) -> void:
	_frame_tick(t)


func _s_precompile() -> void:
	_post.shadow_ramp = 0.0
	_reset_graph(8.0)
	_ensure_precompiled()


func _s_precompile_tick(_f: float, t: float) -> void:
	_frame_tick(t)


func _s_bug() -> void:
	_ensure_precompiled()
	_post.shadow_ramp = 0.0
	_light.shadow_algorithm = ALGO.RAYMARCHED
	_forget(LitShaderLibrary.F_RAMP)
	_reset_graph(14.0)
	_spike_lbl.text = ""
	_warned = false
	_console.clear()


func _s_bug_tick(f: float, t: float) -> void:
	if _countdown_to(f, 0.4) and not _switched:
		_switched = true
		_switch_t = t
		_post.shadow_ramp = 100.0
	_frame_tick(t)
	if _switched and t - _switch_t > 1.0:
		_bug_peak = _peak
		_spike_lbl.text = "worst frame right after the switch: %.1f ms   warning printed: %s" % [_peak, "YES" if _warned else "no"]


func _s_fixed() -> void:
	_ensure_precompiled()
	_post.shadow_ramp = 0.0
	_light.shadow_algorithm = ALGO.CONE_TRACED
	_forget(LitShaderLibrary.F_RAMP | LitShaderLibrary.F_CONE)
	_reset_graph(14.0)
	_spike_lbl.text = ""
	_warned = false
	_fix_done = false
	_console.clear()
	_console.append_text("[color=#8a8a95](console cleared)[/color]

")


var _fix_done := false
var sim_fixed := {}   # variants built by the simulated fix (shown as such in the table)


func _s_fixed_tick(f: float, t: float) -> void:
	if f >= 0.15 and not _fix_done:
		# Simulated fix, during "loading": build the folded twin under its own key too.
		_fix_done = true
		var flags := LitShaderLibrary.F_RAMP | LitShaderLibrary.F_CONE
		sim_fixed[flags] = true
		LitShaderLibrary._warmed[flags] = true
		LitShaderLibrary.get_receiver(flags)
	if _countdown_to(f, 0.4) and not _switched:
		_switched = true
		_switch_t = t
		_post.shadow_ramp = 100.0
	_frame_tick(t)
	if _switched and t - _switch_t > 1.0:
		_spike_lbl.text = "worst frame right after the switch: %.1f ms (bug case: %s)   warning printed: %s" % [
				_peak, "%.1f ms" % _bug_peak if _bug_peak >= 0.0 else "-", "YES" if _warned else "no"]


func _s_config() -> void:
	_post.shadow_ramp = 0.0
	_light.shadow_algorithm = ALGO.RAYMARCHED
	_reset_graph(10.0)
	_spike_lbl.text = ""
	_table.show_config = true


func _s_summary() -> void:
	_post.shadow_ramp = 0.0
	_reset_graph(10.0)
	_spike_lbl.text = ""
	_table.show_config = false


func _s_plain_tick(_f: float, t: float) -> void:
	_frame_tick(t)


# --- Variant table ------------------------------------------------------------------------

class VariantTable extends Node2D:
	var demo
	var pairs: Array = []      # [ramp_flags, twin_flags]
	var missing_total := 0
	var show_config := false
	const ORIGIN := Vector2(44, 120)

	func setup() -> void:
		var work: Array = LitShaderPrecompiler.work_list()
		var listed := {}
		for item in work:
			if item is int:
				listed[item] = true
		var wanted := [LitShaderLibrary.F_RAMP, LitShaderLibrary.F_RAMP | LitShaderLibrary.F_CONE]
		var others := []
		for fl in LitShaderLibrary.all_variant_flags():
			if fl & LitShaderLibrary.F_RAMP != 0 and fl & LitShaderLibrary.F_SELF_EXCL == 0 \
					and LitShaderLibrary._prune(fl) == fl and not listed.has(fl):
				missing_total += 1
				if not wanted.has(fl):
					others.append(fl)
		for fl in wanted + others.slice(0, 5):
			pairs.append([fl, (fl & ~LitShaderLibrary.F_RAMP) | LitShaderLibrary.F_SELF_EXCL])

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var warmed: Dictionary = LitShaderLibrary._warmed
		var done := not warmed.is_empty()
		var floor_flags: int = demo.floor_variant()
		var yy := ORIGIN.y
		draw_string(font, Vector2(ORIGIN.x, yy), "variant", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(0.7, 0.7, 0.75))
		draw_string(font, Vector2(ORIGIN.x + 430, yy), "precompiled?", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(0.7, 0.7, 0.75))
		yy += 14
		draw_line(Vector2(ORIGIN.x, yy), Vector2(ORIGIN.x + 840, yy), Color(0.3, 0.3, 0.35), 1.0)
		yy += 30
		var floor_row := [LitShaderLibrary.F_SELF_EXCL & 0]   # lit_receiver_fast
		for fl in floor_row:
			_row(font, yy, fl, done, warmed, floor_flags, "")
			yy += 34
		for p in pairs:
			_row(font, yy, p[0], done, warmed, floor_flags, "")
			yy += 30
			_row(font, yy, p[1], done, warmed, floor_flags, "      ^ its twin")
			yy += 38
		draw_string(font, Vector2(ORIGIN.x, yy), "... %d folded ramp variants in total, every one of them requestable at runtime" % missing_total,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.8, 0.85))
		if show_config:
			var box := Rect2(ORIGIN.x, yy + 24, 840, 120)
			draw_rect(box, Color(0.02, 0.02, 0.04))
			draw_rect(box, Color(0.6, 0.78, 1.0), false, 1.0)
			var folded: Array = LitShaderPrecompiler.dedupe([LitShaderLibrary.F_RAMP, LitShaderLibrary.F_SELF_EXCL])
			var names := PackedStringArray()
			for f in folded:
				names.append(LitShaderLibrary.variant_name(f))
			draw_string(font, box.position + Vector2(14, 34), "lit_precompile.cfg lists:  lit_receiver_fast_ramp, lit_receiver",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(0.75, 0.85, 1.0))
			draw_string(font, box.position + Vector2(14, 70), "work_list() -> dedupe() keeps:  " + ", ".join(names),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(1.0, 0.45, 0.4))
			draw_string(font, box.position + Vector2(14, 104), "(the ramp variant is dropped again)",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.8, 0.8, 0.85))

	func _row(font: Font, yy: float, fl: int, done: bool, warmed: Dictionary, floor_flags: int, suffix: String) -> void:
		var name: String = LitShaderLibrary.variant_name(fl)
		var is_floor := fl == floor_flags
		if is_floor:
			draw_rect(Rect2(ORIGIN.x - 8, yy - 22, 856, 30), Color(1, 0.84, 0.25, 0.18))
		draw_string(font, Vector2(ORIGIN.x, yy), name + suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
				Color(1, 0.9, 0.5) if is_floor else Color(0.9, 0.9, 0.95))
		var status := "not built yet"
		var col := Color(0.6, 0.6, 0.65)
		if done:
			if demo.sim_fixed.has(fl):
				status = "built (simulated fix)"
				col = Color(0.45, 0.75, 1.0)
			elif warmed.has(fl):
				status = "built"
				col = Color(0.36, 0.9, 0.45)
			else:
				status = "FOLDED AWAY - never built"
				col = Color(1.0, 0.36, 0.3)
		draw_string(font, Vector2(ORIGIN.x + 430, yy), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, col)
		if is_floor:
			draw_string(font, Vector2(ORIGIN.x + 700, yy), "<- floor uses it now", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 0.84, 0.25))
