extends Node2D

## Lit test suite runner (Test/test_suite/TestSuite.tscn).
##
## Runs every section under Test/test_suite/<section>/ back to back in one window,
## each section building its exhibits on screen so the features it checks are
## visible while they are verified, then prints a pass/fail report of every
## feature (one `case` per feature, grouped by section) and shows the same report
## card on the HUD. This is the pre-sign-off check for any change to Lit: every
## feature the plugin ships is exercised, and a broken one shows up as a FAIL line
## with its expected and actual values.
##
## Run windowed (the headless renderer never compiles shaders):
##   godot --path . res://Test/test_suite/TestSuite.tscn
## or play the scene from the editor (embedded Game tab included): the runner pins the
## render to 1920x1080 canvas units = pixels whatever the window is, so results do not
## depend on the window or panel size.
## Options after "--":
##   quit=on          quit after the final report, exit code 1 on any failure
##   capture=PATH     save a PNG of the final report frame (implies quit=on)
##   only=a,b,c       run only these sections (folder names)
##   skip=a,b         skip these sections
##   model=both|phong|pbr   which lighting model(s) the model-sensitive sections run
##                    under (default both: those sections run twice, the PBR pass is
##                    reported as <section>@pbr)
##   hold=SECONDS     keep each finished section on screen this long (visual review)
##   vsync=on         leave vsync on (default: off, so frame waits are as fast as the GPU)
##   verbose=on       also print every passing check while running (default: only the
##                    checks that did not pass, so the console stays short)
## The window stays open on the report by default; Escape quits. Mouse wheel scrolls
## the panel.
##
## Output lines all start with SUITE. While running:
##   SUITE ENV window=.. viewport_px=.. final_scale=.. debugger=.. args=..     (once, the render environment)
##   SUITE ==== <section>: <title> ====                                       (per section)
##   SUITE FAIL|GAP <section>/<feature>: <what> | expected=.. actual=..       (as they land)
## Then the report:
##   SUITE REPORT
##   SUITE PASSED FEATURES (n of m)
##   SUITE   PASS <section>/<feature> (k checks)                              (per feature)
##   SUITE NEEDS CHECKING (f failed, g known gaps)
##   SUITE   FAIL|GAP <section>/<feature>: <what> | expected=.. actual=..     (per check)
##   SUITE SECTIONS
##   SUITE   <section>: k checks, f failed, g known gaps, ms
##   SUITE SUMMARY section_runs=.. features=.. features_passed=.. checks=.. passed=.. failed=.. known_gaps=.. ..
##   SUITE RESULT PASS|FAIL
## A check whose description starts with "(known gap)" documents behaviour Lit does not
## have yet: it is reported as GAP, listed apart from failures, and never fails the run.
## A gap check that PASSES fails the run as "gap closed": remove the label and keep the
## check as a plain regression test.

# "pbr": true marks a section whose exhibits are shaded by the receiver's lighting
# model; it runs once per model (see model=). The rest is model-independent and runs
# once (the lighting_model section switches models itself).
const SECTIONS := [
	{"id": "harness", "title": "Harness & Ambient", "script": "res://Test/test_suite/harness/harness_section.gd"},
	{"id": "lights", "title": "Lights", "script": "res://Test/test_suite/lights/lights_section.gd", "pbr": true},
	{"id": "cookies", "title": "Light Textures (Cookies)", "script": "res://Test/test_suite/cookies/cookies_section.gd", "pbr": true},
	{"id": "receivers", "title": "Receivers", "script": "res://Test/test_suite/receivers/receivers_section.gd", "pbr": true},
	{"id": "animated_sprite", "title": "LitAnimatedSprite2D", "script": "res://Test/test_suite/animated_sprite/animated_sprite_section.gd", "pbr": true},
	{"id": "tilemap", "title": "LitTileMapLayer", "script": "res://Test/test_suite/tilemap/tilemap_section.gd", "pbr": true},
	{"id": "shadows", "title": "Shadows", "script": "res://Test/test_suite/shadows/shadows_section.gd", "pbr": true},
	{"id": "shadow_masks", "title": "Shadow Masks & Exclusions", "script": "res://Test/test_suite/shadow_masks/shadow_masks_section.gd", "pbr": true},
	{"id": "camera", "title": "Camera Transforms", "script": "res://Test/test_suite/camera/camera_section.gd", "pbr": true},
	{"id": "lighting_model", "title": "Lighting Model (Phong / PBR)", "script": "res://Test/test_suite/lighting_model/lighting_model_section.gd"},
	{"id": "luminance", "title": "Luminance Query", "script": "res://Test/test_suite/luminance/luminance_section.gd", "pbr": true},
	{"id": "post_process", "title": "Post Processing", "script": "res://Test/test_suite/post_process/post_process_section.gd"},
	{"id": "auto_pooling", "title": "Material Auto-Pooling", "script": "res://Test/test_suite/auto_pooling/auto_pooling_bench.gd"},
	{"id": "registry", "title": "Registry & Receiver Driving", "script": "res://Test/test_suite/registry/registry_section.gd"},
	{"id": "shader_library", "title": "Shader Library & Precompile", "script": "res://Test/test_suite/shader_library/shader_library_section.gd"},
	{"id": "migration", "title": "Schema Lock & Migrations", "script": "res://Test/test_suite/migration/migration_section.gd"},
	{"id": "update_tool", "title": "Update Project to Lit", "script": "res://Test/test_suite/update_tool/update_tool_section.gd"},
	{"id": "splash", "title": "Splash Screen", "script": "res://Test/test_suite/splash/splash_section.gd"},
]

const HUD_X := LitSuiteSection.HUD_X

var _opt_quit := false
var _opt_capture := ""
var _opt_only: PackedStringArray = []
var _opt_skip: PackedStringArray = []
var _opt_hold := 0.0
var _opt_vsync := false
var _opt_model := "both"

var _hud: RichTextLabel
var _status: Label
var _title: Label
var _current: LitSuiteSection = null
var _section_index := 0
var _planned: Array = []
var _section_results: Array = []   # {id, title, results, ms}
var _all_results: Array = []       # results tagged with section id
var _finished := false
var _t0 := 0


func _ready() -> void:
	_parse_args()
	LitSuiteSection.pin_render_size(get_window())
	if not _opt_vsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	RenderingServer.set_default_clear_color(Color.BLACK)
	for s in SECTIONS:
		if not _opt_only.is_empty() and not _opt_only.has(s.id):
			continue
		if _opt_skip.has(s.id):
			continue
		var sensitive: bool = s.get("pbr", false)
		if not sensitive or _opt_model != "pbr":
			_planned.append({"id": s.id, "run_id": s.id, "title": s.title, "script": s.script, "model": 0})
		if sensitive and _opt_model != "phong":
			_planned.append({"id": s.id, "run_id": s.id + "@pbr", "title": s.title + " [PBR]",
					"script": s.script, "model": 1})
	_build_hud()
	_run_all()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"quit":
				_opt_quit = kv[1] == "on" or kv[1] == "1" or kv[1] == "true"
			"capture":
				_opt_capture = kv[1]
				_opt_quit = true
			"only", "sections":
				_opt_only = kv[1].split(",", false)
			"skip":
				_opt_skip = kv[1].split(",", false)
			"hold":
				_opt_hold = float(kv[1])
			"vsync":
				_opt_vsync = kv[1] == "on" or kv[1] == "1" or kv[1] == "true"
			"model":
				_opt_model = kv[1]
			"verbose":
				LitSuiteSection.verbose = kv[1] == "on" or kv[1] == "1" or kv[1] == "true"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()


# --- Driving ------------------------------------------------------------------------------

func _run_all() -> void:
	await _await_precompile()
	await get_tree().process_frame
	await get_tree().process_frame
	print(LitSuiteSection.env_line(get_viewport()))
	_t0 = Time.get_ticks_msec()
	print("SUITE Lit %s test suite: %d section runs (model=%s)" % [LitShaderLibrary._get_version(), _planned.size(), _opt_model])
	for i in _planned.size():
		_section_index = i
		var spec: Dictionary = _planned[i]
		var script := load(spec.script) as GDScript
		if script == null or not script.can_instantiate():
			_all_results.append({"section": spec.run_id, "case": "load", "desc": "section script loads",
					"expected": spec.script, "actual": "null", "pass": false, "gap": false})
			print("SUITE FAIL %s/load: section script loads | expected=%s actual=null" % [spec.run_id, spec.script])
			_section_results.append({"id": spec.run_id, "title": spec.title, "results": [_all_results[-1]], "ms": 0})
			continue
		var sec := script.new() as LitSuiteSection
		sec.section_id = spec.run_id
		sec.section_title = spec.title
		sec.model = spec.model
		sec.name = spec.run_id.replace("@", "_")
		_current = sec
		add_child(sec)
		var t := Time.get_ticks_msec()
		await sec.run_section()
		var ms := Time.get_ticks_msec() - t
		for r in sec.results:
			var tagged: Dictionary = r.duplicate()
			tagged["section"] = spec.run_id
			_all_results.append(tagged)
		_section_results.append({"id": spec.run_id, "title": spec.title, "results": sec.results.duplicate(),
				"ms": ms})
		_render_hud()
		if _opt_hold > 0.0:
			await get_tree().create_timer(_opt_hold).timeout
		_current = null
		sec.queue_free()
		# Let the freed section's lights, occluders and materials leave the registry
		# before the next section builds.
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	_finish()


## End of run: the two-list report (every passing feature, then everything that needs
## a look), per-section counts, the summary line, and the verdict.
func _finish() -> void:
	_finished = true
	var total_ms := Time.get_ticks_msec() - _t0
	print("SUITE REPORT")
	var rep := LitSuiteSection.print_report(_all_results)
	print("SUITE SECTIONS")
	for s in _section_results:
		var sf := 0
		var sg := 0
		for r in s.results:
			if not r.pass:
				if r.gap:
					sg += 1
				else:
					sf += 1
		print("SUITE   %s: %d checks, %d failed, %d known gaps, %d ms" % [s.id, s.results.size(), sf, sg, s.ms])
	print("SUITE SUMMARY section_runs=%d features=%d features_passed=%d features_failed=%d features_with_gaps=%d checks=%d passed=%d failed=%d known_gaps=%d model=%s time=%.1fs" % [
			_section_results.size(), rep.features, rep.features_passed, rep.features_failed,
			rep.features_with_gaps, _all_results.size(), _all_results.size() - rep.failed - rep.gaps,
			rep.failed, rep.gaps, _opt_model, total_ms / 1000.0])
	print("SUITE RESULT %s" % ("PASS" if rep.failed == 0 else "FAIL"))
	_render_hud()
	if _opt_quit:
		_quit_after_capture(rep.failed)


func _quit_after_capture(failed: int) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if _opt_capture != "":
		get_viewport().get_texture().get_image().save_png(_opt_capture)
		print("SUITE capture=%s" % _opt_capture)
	get_tree().quit(1 if failed > 0 else 0)


## Deterministic runs start after the launch precompile takeover, if one ran.
func _await_precompile() -> void:
	var mgr := get_node_or_null("/root/LitManager")
	if mgr != null and mgr.precompiler != null:
		if mgr.precompiler.is_processing():
			await mgr.precompiler.finished
		while get_tree().root.get_node_or_null("LitPrecompileOverlay") != null:
			await RenderingServer.frame_post_draw
	for i in 3:
		await RenderingServer.frame_post_draw


## One row per (section, case): total, failed and gap checks.
func _feature_table() -> Array:
	return LitSuiteSection.feature_table(_all_results)


# --- HUD -------------------------------------------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	_status = Label.new()
	_status.position = Vector2(20, 12)
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_status.add_theme_constant_override("outline_size", 4)
	layer.add_child(_status)
	_title = Label.new()
	_title.position = Vector2(20, 38)
	_title.add_theme_font_size_override("font_size", 13)
	_title.add_theme_color_override("font_color", Color(0.7, 0.72, 0.8))
	_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_title.add_theme_constant_override("outline_size", 4)
	layer.add_child(_title)
	var panel := PanelContainer.new()
	panel.position = Vector2(HUD_X, 44)
	panel.size = Vector2(1920 - HUD_X - 12, 1080 - 56)
	layer.add_child(panel)
	_hud = RichTextLabel.new()
	_hud.bbcode_enabled = true
	_hud.scroll_active = true
	_hud.fit_content = false
	_hud.add_theme_font_size_override("normal_font_size", 12)
	_hud.text = "[b]Lit test suite[/b]\nstarting..."
	panel.add_child(_hud)


func _process(_delta: float) -> void:
	var failed := 0
	var gaps := 0
	for r in _all_results:
		if not r.pass:
			if r.gap:
				gaps += 1
			else:
				failed += 1
	if _finished:
		_status.text = "Lit %s test suite   DONE   checks %d   failed %d   known gaps %d   %s" % [
				LitShaderLibrary._get_version(), _all_results.size(), failed, gaps,
				"ALL PASS" if failed == 0 else "FAILURES"]
		_title.text = "Escape quits. Mouse wheel scrolls the report."
		return
	var cur_checks := _current.results.size() if _current != null else 0
	var cur_failed := _current.failed_count() if _current != null else 0
	_status.text = "Lit %s test suite   section %d/%d   checks %d (%d failed)   %.1f s" % [
			LitShaderLibrary._get_version(), _section_index + 1, _planned.size(),
			_all_results.size() + cur_checks, failed + cur_failed,
			(Time.get_ticks_msec() - _t0) / 1000.0 if _t0 > 0 else 0.0]
	if _current != null:
		_title.text = "%s   (%s)   %s" % [_current.section_title, _current.model_name(), _current.status]
		_hud.text = _current.render_results_bbcode() + _current.hud_extra()


func _render_hud() -> void:
	if not _finished:
		return
	var features := _feature_table()
	var failed := 0
	var gaps := 0
	for r in _all_results:
		if not r.pass:
			if r.gap:
				gaps += 1
			else:
				failed += 1
	var t := "[b]Lit %s test suite - report[/b]\n" % LitShaderLibrary._get_version()
	t += "section runs=%d  features=%d  checks=%d  [color=#8f8]passed=%d[/color]  [color=#f88]failed=%d[/color]  [color=#fc8]known gaps=%d[/color]  model=%s  %.1f s\n\n" % [
			_section_results.size(), features.size(), _all_results.size(), _all_results.size() - failed - gaps,
			failed, gaps, _opt_model, (Time.get_ticks_msec() - _t0) / 1000.0]
	# What needs a look first (the top of the panel is what is on screen), grouped by
	# feature with every check that did not pass under it.
	t += "[b]Needs checking[/b]  (%d failed, %d known gaps; gaps document behaviour Lit does not have yet and never fail the run)\n" % [failed, gaps]
	var any_bad := false
	for f in features:
		if f.failed == 0 and f.gaps == 0:
			continue
		any_bad = true
		var tag := "[color=#f88]FAIL[/color]" if f.failed > 0 else "[color=#fc8]GAP[/color]"
		t += "%s %s/%s [color=#888](%d/%d passed)[/color]\n" % [tag, f.section, f.case, f.total - f.failed - f.gaps, f.total]
		for r in _all_results:
			if r.section == f.section and r.case == f.case and not r.pass:
				t += "      [color=%s]%s[/color] %s\n            expected %s, got %s\n" % [
						"#fc8" if r.gap else "#f88", "GAP" if r.gap else "FAIL", r.desc, r.expected, r.actual]
	if not any_bad:
		t += "[color=#8f8]none - every feature passed[/color]\n"
	t += "\n[b]Passed features[/b]\n"
	var last_section := ""
	for f in features:
		if f.failed > 0 or f.gaps > 0:
			continue
		if f.section != last_section:
			last_section = f.section
			var title: String = f.section
			for s in _section_results:
				if s.id == f.section:
					title = "%s  (%d ms)" % [s.title, s.ms]
			t += "[color=#9cf]%s[/color]\n" % title
		t += "  [color=#8f8]PASS[/color] %s [color=#888](%d checks)[/color]\n" % [f.case, f.total]
	_hud.text = t
