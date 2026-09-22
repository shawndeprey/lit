extends Node2D
class_name LitSuiteSection

## Base class for one section of the Lit test suite (Test/test_suite).
##
## A section builds exhibits on screen (every feature it covers stays visible while
## it runs), drives them the way a game would, and records checks. It is a coroutine:
## override run() and `await frames(n)` / `await capture()` between steps. The suite
## runner (test_suite.gd) instantiates each section in turn and collects `results`;
## a section's own .tscn runs it standalone with the same HUD, so a single feature set
## can be debugged in isolation (`quit=on` / `capture=PATH` after "--").
##
## Checks are grouped by `case` - one case per feature. While a section runs only the
## checks that did not pass are printed (`verbose=on` prints every check):
##   SUITE FAIL|GAP <section>/<case>: <what> | expected=.. actual=..
## The report at the end lists every passing feature, then everything that needs a
## look (see print_report). Pixel probes read the rendered frame back (windowed runs
## only: the headless renderer never compiles shaders), so a section verifies what is
## actually drawn, not just what the nodes report.

## Exhibits stay left of this logical x (the HUD panel lives to its right).
const HUD_X := 1400.0
## Default cell grid for exhibits (same layout as the auto-pooling bench).
const CELL := Vector2(228.0, 190.0)
const ORIGIN := Vector2(20.0, 70.0)
const COLS := 6
## The proxied receiver exports (the same eleven on all three receiver classes) and a
## non-default value each; check_proxies() expects the runtime material to mirror them.
const RECEIVER_PROXIES := {
	"emissive_strength": 0.7, "receiver_mask": 3, "self_shadow": true, "specular_strength": 0.9,
	"specular_k": 8.0, "metallic_value": 0.5, "roughness_value": 0.3, "shadow_steps": 32,
	"shadow_min_step": 0.5, "footprint_shadow": 4.0, "directional_horizontal_scale": 8.0,
}

## Set by subclasses: folder name and human title.
@export var section_id := "section"
@export var section_title := "Section"
## Lighting model this run of the section is pinned to: 0 = Blinn-Phong, 1 = PBR. The
## runner sets it before run_section() (model-sensitive sections run once per model);
## standalone, pass `model=pbr`. Numeric expectations go through diffuse_scale() so
## the same checks hold under both models.
var model := 0
## Console verbosity while running: false prints only the checks that did not pass
## (the end-of-run report lists every feature anyway); `verbose=on` prints all of them.
static var verbose := false
## Every SUITE line printed so far, in order; the C key copies them to the clipboard.
static var transcript: PackedStringArray = []
## Under PBR a dielectric's Lambert term is albedo x (1 - F0) = 0.96 x the Phong
## diffuse, and the roughness-1 specular adds under 0.006: one factor covers it.
const PBR_DIFFUSE := 0.96
## Live one-line status a section may set (shown in the runner's status bar).
var status := ""
## Check records: {case, desc, expected, actual, pass}.
var results: Array = []
## Lit version stamp (from plugin.cfg), for sections that print it.
var lit_version := ""

var _cell_index := 0
var _settings_saved := {}
var _finished := false
var _texture_names := {}
var _standalone := false
var _opt_quit := false
var _opt_capture := ""
var _hud: RichTextLabel
var _hud_status: Label
var _t_start := 0


# --- Lifecycle -----------------------------------------------------------------------

func _ready() -> void:
	lit_version = LitShaderLibrary._get_version()
	# Standalone: this section's own scene is the main scene. Build the HUD, run, and
	# report like the suite would.
	if get_tree().current_scene == self:
		_standalone = true
		_parse_args()
		_build_standalone_hud()
		_run_standalone()


func _run_standalone() -> void:
	pin_render_size(get_window())
	await _await_precompile()
	await frames(2)
	say(env_line(get_viewport()))
	await run_section()
	var tagged: Array = []
	for r in results:
		var t: Dictionary = r.duplicate()
		t["section"] = section_id
		tagged.append(t)
	say("SUITE REPORT")
	var rep := print_report(tagged)
	say("SUITE SUMMARY section=%s features=%d features_passed=%d checks=%d passed=%d failed=%d known_gaps=%d model=%s time=%.1fs" % [
			section_id, rep.features, rep.features_passed, results.size(),
			results.size() - failed_count() - gap_count(), failed_count(), gap_count(),
			model_name(), (Time.get_ticks_msec() - _t_start) / 1000.0])
	say("SUITE RESULT %s" % ("PASS" if failed_count() == 0 else "FAIL"))
	_render_standalone_hud()
	if _opt_quit:
		await frames(2)
		if _opt_capture != "":
			get_viewport().get_texture().get_image().save_png(_opt_capture)
			say("SUITE capture=%s" % _opt_capture)
		get_tree().quit(1 if failed_count() > 0 else 0)


## Runs the section: build, drive, check; returns when every check has landed.
## Every section starts on the Blinn-Phong lighting model (the numeric expectations
## are written against it; the lighting_model section switches to PBR explicitly) and
## on the default quality settings; the project's own values are restored afterwards.
func run_section() -> void:
	_t_start = Time.get_ticks_msec()
	say("SUITE ==== %s: %s ====" % [section_id, section_title])
	# Fresh-launch registry state for every run: the light-mask "seen" latch is a
	# process-wide static that an earlier section's light setters would leave on.
	LitLightRegistry.light_masks_seen = false
	await _await_world_sdf_warmup()
	set_setting("lit/render/lighting_model", model)
	set_setting("lit/quality/shadow_step_scaling", false)
	set_setting("lit/render/y_sorting", false)
	@warning_ignore("redundant_await")   # the base run() is a stub; subclasses' are coroutines
	await run()
	_finished = true
	restore_settings()


## Override: the section body. Await frames()/capture() between steps.
func run() -> void:
	pass


## The world SDF re-renders every frame for its first frames after creation
## (WORLD_SDF_WARMUP in registry/world_sdf.gd); until that window closes, content edits
## look as if they re-rendered the SDF by themselves, so the first section of a run would
## see different staleness behaviour from the rest.
func _await_world_sdf_warmup() -> void:
	var mgr := get_node_or_null("/root/LitManager")
	if mgr == null:
		return
	var wsdf = mgr._registry._world_sdf
	var guard := 0
	while wsdf._wsdf_warmup > 0 and guard < 200:
		await RenderingServer.frame_post_draw
		guard += 1


## Factor on a lit receiver's diffuse term for the pinned model (1 under Blinn-Phong).
func diffuse_scale() -> float:
	return PBR_DIFFUSE if model == 1 else 1.0


func model_name() -> String:
	return "PBR" if model == 1 else "Blinn-Phong"


## Optional extra HUD text (the auto-pooling bench lists its pool entries here).
func hud_extra() -> String:
	return ""


func _exit_tree() -> void:
	restore_settings()


func _unhandled_input(event: InputEvent) -> void:
	if not _standalone or not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_ESCAPE:
		get_tree().quit()
	elif event.keycode == KEY_C:
		status = "copied %d SUITE lines to the clipboard" % copy_transcript()


## Prints a console line and keeps it for copy_transcript().
static func say(line: String) -> void:
	print(line)
	transcript.append(line)


## Copies every SUITE line printed so far to the clipboard; returns the line count.
static func copy_transcript() -> int:
	DisplayServer.clipboard_set("\n".join(transcript))
	return transcript.size()


# --- Checks -----------------------------------------------------------------------------

## Exact check (objects by identity, null only equals null).
func check(case_name: String, desc: String, expected, actual) -> bool:
	return _record(case_name, desc, expected, actual, _eq(expected, actual))


## Boolean check.
func check_true(case_name: String, desc: String, ok: bool) -> bool:
	return _record(case_name, desc, true, ok, ok)


## |expected - actual| <= tol (floats, Vector2, Color: per channel).
func check_approx(case_name: String, desc: String, expected, actual, tol: float) -> bool:
	var ok := false
	if actual == null or expected == null:
		ok = false
	elif expected is Color and actual is Color:
		ok = absf(expected.r - actual.r) <= tol and absf(expected.g - actual.g) <= tol \
				and absf(expected.b - actual.b) <= tol
	elif expected is Vector2 and actual is Vector2:
		ok = (expected - actual).length() <= tol
	else:
		ok = absf(float(expected) - float(actual)) <= tol
	return _record(case_name, desc, "%s ±%s" % [_fmt(expected), _fmt(tol)], actual, ok)


## a > b + margin.
func check_gt(case_name: String, desc: String, a: float, b: float, margin := 0.0) -> bool:
	return _record(case_name, desc, "> %.3f" % (b + margin), a, a > b + margin)


## a < b - margin.
func check_lt(case_name: String, desc: String, a: float, b: float, margin := 0.0) -> bool:
	return _record(case_name, desc, "< %.3f" % (b - margin), a, a < b - margin)


## lo <= v <= hi.
func check_between(case_name: String, desc: String, v: float, lo: float, hi: float) -> bool:
	return _record(case_name, desc, "[%.3f, %.3f]" % [lo, hi], v, v >= lo and v <= hi)


## Sets every RECEIVER_PROXIES export on a receiver node and checks its material mirrors it.
func check_proxies(case_name: String, node: CanvasItem) -> void:
	for p in RECEIVER_PROXIES:
		node.set(p, RECEIVER_PROXIES[p])
		var got: Variant = (node.material as ShaderMaterial).get_shader_parameter(p)
		if RECEIVER_PROXIES[p] is float and (got is float or got is int):
			got = float(got)
		elif got is float or got is int:
			got = int(got)
		check(case_name, "%s proxies to the material" % p, RECEIVER_PROXIES[p], got)


## Failures, not counting known-gap checks.
func failed_count() -> int:
	var n := 0
	for r in results:
		if not r.pass and not r.gap:
			n += 1
	return n


## Failing checks whose description starts with "(known gap)": behaviour Lit does
## not have yet. Reported apart from failures and never fail the run.
func gap_count() -> int:
	var n := 0
	for r in results:
		if not r.pass and r.gap:
			n += 1
	return n


func _record(case_name: String, desc: String, expected, actual, ok: bool) -> bool:
	var gap := desc.begins_with("(known gap)")
	if gap and ok:
		# The gap closed: fail loudly so the label gets removed and the check becomes a
		# plain regression test (a passing gap would otherwise hide as a PASS).
		gap = false
		ok = false
		desc = "gap closed, remove the (known gap) label: " + desc
	results.append({"case": case_name, "desc": desc, "expected": _fmt(expected),
			"actual": _fmt(actual), "pass": ok, "gap": gap})
	if not ok or verbose:
		var tag := "PASS" if ok else ("GAP" if gap else "FAIL")
		say("SUITE %s %s/%s: %s | expected=%s actual=%s" % [tag, section_id, case_name, desc,
				_fmt(expected), _fmt(actual)])
	return ok


# --- Report -----------------------------------------------------------------------------

## One row per (section, case) over results tagged with a "section" key:
## {section, case, total, failed, gaps}, in first-seen order.
static func feature_table(tagged: Array) -> Array:
	var order: Array = []
	var by_key := {}
	for r in tagged:
		var key: String = "%s/%s" % [r.section, r.case]
		if not by_key.has(key):
			by_key[key] = {"section": r.section, "case": r.case, "total": 0, "failed": 0, "gaps": 0}
			order.append(key)
		by_key[key].total += 1
		if not r.pass:
			if r.gap:
				by_key[key].gaps += 1
			else:
				by_key[key].failed += 1
	var out: Array = []
	for key in order:
		out.append(by_key[key])
	return out


## Prints the end-of-run report over results tagged with a "section" key: every
## feature whose checks all passed on one list, then every check that did not pass
## (failures and known gaps, with their values) on another - the list to look at.
## Returns the counts: {features, features_passed, features_failed, features_with_gaps,
## failed, gaps}.
static func print_report(tagged: Array) -> Dictionary:
	var features := feature_table(tagged)
	var passed: Array = []
	var feat_failed := 0
	var feat_gaps := 0
	for f in features:
		if f.failed > 0:
			feat_failed += 1
		elif f.gaps > 0:
			feat_gaps += 1
		else:
			passed.append(f)
	var failed := 0
	var gaps := 0
	for r in tagged:
		if not r.pass:
			if r.gap:
				gaps += 1
			else:
				failed += 1
	say("SUITE PASSED FEATURES (%d of %d)" % [passed.size(), features.size()])
	for f in passed:
		say("SUITE   PASS %s/%s (%d checks)" % [f.section, f.case, f.total])
	say("SUITE NEEDS CHECKING (%d failed, %d known gaps)" % [failed, gaps])
	if failed + gaps == 0:
		say("SUITE   none")
	for r in tagged:
		if not r.pass:
			say("SUITE   %s %s/%s: %s | expected=%s actual=%s" % ["GAP" if r.gap else "FAIL",
					r.section, r.case, r.desc, r.expected, r.actual])
	return {"features": features.size(), "features_passed": passed.size(),
			"features_failed": feat_failed, "features_with_gaps": feat_gaps,
			"failed": failed, "gaps": gaps}


func _eq(a, b) -> bool:
	if a is Object or b is Object:
		return is_same(a, b)
	if a == null or b == null:
		return a == null and b == null
	if a is float or b is float:
		return is_equal_approx(float(a), float(b))
	return a == b


## Override to name values in check output (the pooling bench labels materials M1, M2..).
func format_value(_v) -> String:
	return ""


func _fmt(v) -> String:
	var custom := format_value(v)
	if custom != "":
		return custom
	if v == null:
		return "null"
	if v is float:
		return "%.3f" % v
	if v is Color:
		return "(%.2f, %.2f, %.2f)" % [v.r, v.g, v.b]
	if v is Texture2D:
		return _texture_names.get(v, "texture")
	if v is String:
		return v
	if v is Object:
		return "%s#%d" % [v.get_class(), v.get_instance_id()]
	return str(v)


# --- Frames and pixel probes -------------------------------------------------------------

## Render every run at exactly 1920x1080 canvas units = pixels whatever the window is:
## the probes, penumbra widths and pixel-sized post effects are calibrated for that, and
## the editor's embedded Game tab (or any resized window) would otherwise stretch the
## canvas (the project's canvas_items + expand mode) and change every soft edge.
static func pin_render_size(win: Window) -> void:
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_size = Vector2i(1920, 1080)
	win.content_scale_factor = 1.0


## One line describing the window the run renders into (size, screen scale, viewport
## pixels against canvas units, how the process was launched), so a log explains its own
## environment: the probes are calibrated for a 1920x1080 viewport at one pixel per
## canvas unit, and an embedded or resized editor game window changes both.
static func env_line(vp: Viewport) -> String:
	var win := vp.get_window()
	var wid := win.get_window_id()
	var screen := DisplayServer.window_get_current_screen(wid)
	var tex_size := Vector2i.ZERO
	var tex := vp.get_texture()
	if tex != null:
		tex_size = Vector2i(tex.get_size())
	return "SUITE ENV window=%s screen=%d/%d screen_size=%s screen_scale=%.2f dpi=%d viewport_px=%s canvas_units=%s final_scale=%.3f canvas_scale=%.3f vsync=%d debugger=%s args=%s" % [
			win.size, screen, DisplayServer.get_screen_count(), DisplayServer.screen_get_size(screen),
			DisplayServer.screen_get_scale(screen), DisplayServer.screen_get_dpi(screen),
			tex_size, vp.get_visible_rect().size, vp.get_final_transform().get_scale().x,
			vp.get_canvas_transform().get_scale().x,
			DisplayServer.window_get_vsync_mode(wid), EngineDebugger.is_active(),
			" ".join(OS.get_cmdline_args())]


## Wait for n rendered frames.
func frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw


## Wait for the next drawn frame and read it back.
func capture() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Logical (canvas) point -> pixel in a captured image. The image is the viewport's render
## target (1920x1080 once pin_render_size ran), so the pixel scale is the image size over
## the visible canvas rect; get_final_transform() is the stretch to the *window*, which
## the render target does not carry in viewport stretch mode.
func to_px(canvas_pt: Vector2, img: Image) -> Vector2:
	var vp := get_viewport()
	var canvas_px := vp.get_canvas_transform() * canvas_pt
	var vis := vp.get_visible_rect().size
	return canvas_px * Vector2(img.get_width(), img.get_height()) / vis


## Mean colour of the (2*half+1)^2 pixel square around a logical point.
func probe(img: Image, at: Vector2, half := 3) -> Color:
	var c := to_px(at, img)
	var cx := int(round(c.x))
	var cy := int(round(c.y))
	var sum := Color(0, 0, 0, 0)
	var n := 0
	for y in range(cy - half, cy + half + 1):
		for x in range(cx - half, cx + half + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			sum += img.get_pixel(x, y)
			n += 1
	if n == 0:
		return Color.BLACK
	return sum / float(n)


## Mean luminance (Rec. 601) around a logical point.
func lum(img: Image, at: Vector2, half := 3) -> float:
	var c := probe(img, at, half)
	return c.r * 0.299 + c.g * 0.587 + c.b * 0.114


## Brightest channel of the mean colour around a logical point (coloured lights).
func peak(img: Image, at: Vector2, half := 3) -> float:
	var c := probe(img, at, half)
	return maxf(c.r, maxf(c.g, c.b))


## Mean absolute per-channel difference of two captures inside a logical rect.
func image_diff(a: Image, b: Image, rect: Rect2, step := 4) -> float:
	var p0 := to_px(rect.position, a)
	var p1 := to_px(rect.end, a)
	var sum := 0.0
	var n := 0
	var y := int(p0.y)
	while y < int(p1.y):
		var x := int(p0.x)
		while x < int(p1.x):
			if x >= 0 and y >= 0 and x < a.get_width() and y < a.get_height() \
					and x < b.get_width() and y < b.get_height():
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
				n += 1
			x += step
		y += step
	return 0.0 if n == 0 else sum / float(n * 3)


## Luminance variance inside a logical rect (texture / noise detector).
func image_variance(img: Image, rect: Rect2, step := 2) -> float:
	var p0 := to_px(rect.position, img)
	var p1 := to_px(rect.end, img)
	var vals := PackedFloat32Array()
	var y := int(p0.y)
	while y < int(p1.y):
		var x := int(p0.x)
		while x < int(p1.x):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				var c := img.get_pixel(x, y)
				vals.append(c.r * 0.299 + c.g * 0.587 + c.b * 0.114)
			x += step
		y += step
	if vals.is_empty():
		return 0.0
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= vals.size()
	var var_sum := 0.0
	for v in vals:
		var_sum += (v - mean) * (v - mean)
	return var_sum / vals.size()


## Mean colour inside a logical rect.
func image_mean(img: Image, rect: Rect2, step := 4) -> Color:
	var p0 := to_px(rect.position, img)
	var p1 := to_px(rect.end, img)
	var sum := Color(0, 0, 0, 0)
	var n := 0
	var y := int(p0.y)
	while y < int(p1.y):
		var x := int(p0.x)
		while x < int(p1.x):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				sum += img.get_pixel(x, y)
				n += 1
			x += step
		y += step
	return Color.BLACK if n == 0 else sum / float(n)


# --- Project settings (restored when the section ends) ------------------------------------

func set_setting(setting: String, value) -> void:
	if not _settings_saved.has(setting):
		_settings_saved[setting] = ProjectSettings.get_setting(setting, null)
	ProjectSettings.set_setting(setting, value)


func restore_settings() -> void:
	for setting in _settings_saved:
		ProjectSettings.set_setting(setting, _settings_saved[setting])
	_settings_saved.clear()


# --- Scene building helpers ------------------------------------------------------------

## Ambient / darkness for the section (every section owns one).
func env(color := Color(0.1, 0.1, 0.12), energy := 1.0) -> LitCanvasModulate:
	var cm := LitCanvasModulate.new()
	cm.name = "Ambient"
	cm.color = color
	cm.ambient_energy = energy
	add_child(cm)
	return cm


func point_light(pos: Vector2, p_range := 400.0, energy := 1.0, color := Color.WHITE,
		height := 120.0, parent: Node = null) -> LitPointLight2D:
	var l := LitPointLight2D.new()
	l.position = pos
	l.range = p_range
	l.energy = energy
	l.color = color
	l.height = height
	(parent if parent != null else self).add_child(l)
	return l


func spot_light(pos: Vector2, rot: float, p_range := 400.0, energy := 1.0, color := Color.WHITE,
		height := 120.0, parent: Node = null) -> LitSpotLight2D:
	var l := LitSpotLight2D.new()
	l.position = pos
	l.rotation = rot
	l.range = p_range
	l.energy = energy
	l.color = color
	l.height = height
	(parent if parent != null else self).add_child(l)
	return l


func directional_light(rot: float, energy := 1.0, color := Color.WHITE, height := 16.0,
		parent: Node = null) -> LitDirectionalLight2D:
	var l := LitDirectionalLight2D.new()
	l.rotation = rot
	l.energy = energy
	l.color = color
	l.height = height
	(parent if parent != null else self).add_child(l)
	return l


## A flat white receiver covering `rect` (LitSprite2D, specular off so probes are
## plain diffuse + ambient). Unscaled, on a texture of the rect's exact size, so
## child occluders are positioned in plain pixels relative to its centre.
func floor_receiver(rect: Rect2, color := Color.WHITE, parent: Node = null,
		specular := 0.0) -> LitSprite2D:
	var s := LitSprite2D.new()
	s.name = "Floor"
	var ct := CanvasTexture.new()
	ct.diffuse_texture = tex_sized(rect.size)
	s.texture = ct
	s.modulate = color
	s.position = rect.get_center()
	s.specular_strength = specular
	(parent if parent != null else self).add_child(s)
	return s


## A solid-colour LitSprite2D of an exact pixel size (unscaled).
func box_receiver(pos: Vector2, size: Vector2, color := Color.WHITE, parent: Node = null,
		normal: Texture2D = null, specular: Texture2D = null) -> LitSprite2D:
	var s := LitSprite2D.new()
	s.texture = canvas_tex(tex_sized(size), normal, specular)
	s.modulate = color
	s.position = pos
	(parent if parent != null else self).add_child(s)
	return s


## A LitSprite2D on a CanvasTexture built from the given maps.
func lit_sprite(diffuse: Texture2D, pos: Vector2, scale_f := 1.0, normal: Texture2D = null,
		specular: Texture2D = null, parent: Node = null) -> LitSprite2D:
	var s := LitSprite2D.new()
	s.texture = canvas_tex(diffuse, normal, specular)
	s.position = pos
	s.scale = Vector2.ONE * scale_f
	(parent if parent != null else self).add_child(s)
	return s


## Rectangle LightOccluder2D centred on `pos` (local to `parent`).
func occluder(pos: Vector2, size: Vector2, parent: Node = null, mask := 1) -> LightOccluder2D:
	var o := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var h := size * 0.5
	poly.polygon = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y),
			Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	o.occluder = poly
	o.position = pos
	o.occluder_light_mask = mask
	(parent if parent != null else self).add_child(o)
	return o


## A plain (unlit) sprite: a visual marker that ignores lighting.
func marker(pos: Vector2, size: Vector2, color: Color, parent: Node = null) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = white()
	s.modulate = color
	s.position = pos
	s.scale = size
	(parent if parent != null else self).add_child(s)
	return s


## Wrapper Node2D (keeps occluders from being "owned" by sibling receivers).
func group(node_name := "Group", parent: Node = null) -> Node2D:
	var n := Node2D.new()
	n.name = node_name
	(parent if parent != null else self).add_child(n)
	return n


func label(text: String, pos: Vector2, size := 12, color := Color(0.85, 0.85, 0.9),
		parent: Node = null) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	(parent if parent != null else self).add_child(l)
	return l


## Cell grid (6 x 5 cells of 228 x 190 under the title bar).
func cell(title: String) -> int:
	var idx := _cell_index
	_cell_index += 1
	label(title, cell_pos(idx) + Vector2(4, 4))
	return idx


func cell_pos(idx: int) -> Vector2:
	return ORIGIN + Vector2(idx % COLS, floori(idx / float(COLS))) * CELL


func cell_center(idx: int) -> Vector2:
	return cell_pos(idx) + Vector2(CELL.x * 0.5, CELL.y * 0.5 + 14)


func place(node: Node2D, idx: int, offset := Vector2.ZERO, scale_f := 1.0, parent: Node = null) -> void:
	node.position = cell_center(idx) + offset
	node.scale = Vector2.ONE * scale_f
	(parent if parent != null else self).add_child(node)


# --- Textures ------------------------------------------------------------------------------

static var _white_tex: ImageTexture

## 1x1 white: a sprite on it is exactly `scale` pixels wide.
func white() -> ImageTexture:
	if _white_tex == null:
		_white_tex = tex_solid(1, Color.WHITE)
	return _white_tex


## Solid texture of an exact pixel size (unscaled sprites, so child nodes use plain
## pixel coordinates).
func tex_sized(size: Vector2, color := Color.WHITE) -> ImageTexture:
	var img := Image.create(maxi(int(size.x), 1), maxi(int(size.y), 1), false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func tex_solid(size: int, color: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func tex_fn(w: int, h: int, fn: Callable) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, fn.call(x, y))
	return ImageTexture.create_from_image(img)


## Normal-map colour for a tangent-space normal (Godot 2D: R = +X right, G = +Y, B = +Z).
static func normal_color(nx: float, ny := 0.0) -> Color:
	var n := Vector3(nx, ny, 1.0).normalized()
	return Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5)


## Flat normal map tilted toward (nx, ny).
func tex_normal(size: int, nx: float, ny := 0.0) -> ImageTexture:
	return tex_solid(size, normal_color(nx, ny))


func canvas_tex(diffuse: Texture2D, normal: Texture2D = null,
		specular: Texture2D = null) -> CanvasTexture:
	var ct := CanvasTexture.new()
	ct.diffuse_texture = diffuse
	ct.normal_texture = normal
	ct.specular_texture = specular
	return ct


func name_texture(tex: Texture2D, tex_name: String) -> void:
	_texture_names[tex] = tex_name


func receiver_material(flags := 0) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = LitShaderLibrary.get_receiver(flags)
	return mat


# --- Standalone plumbing --------------------------------------------------------------------

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
			"model":
				model = 1 if kv[1] == "pbr" or kv[1] == "1" else 0
			"verbose":
				verbose = kv[1] == "on" or kv[1] == "1" or kv[1] == "true"


## Deterministic runs start after the launch precompile takeover, if one ran.
func _await_precompile() -> void:
	var mgr := get_node_or_null("/root/LitManager")
	if mgr != null and mgr.precompiler != null:
		if mgr.precompiler.is_processing():
			await mgr.precompiler.finished
		while get_tree().root.get_node_or_null("LitPrecompileOverlay") != null:
			await RenderingServer.frame_post_draw
	await frames(2)


func _build_standalone_hud() -> void:
	RenderingServer.set_default_clear_color(Color.BLACK)
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	_hud_status = Label.new()
	_hud_status.position = Vector2(20, 12)
	_hud_status.add_theme_font_size_override("font_size", 18)
	layer.add_child(_hud_status)
	var panel := PanelContainer.new()
	panel.position = Vector2(HUD_X, 44)
	panel.size = Vector2(1920 - HUD_X - 12, 1080 - 56)
	layer.add_child(panel)
	_hud = RichTextLabel.new()
	_hud.bbcode_enabled = true
	_hud.scroll_active = true
	_hud.fit_content = false
	_hud.selection_enabled = true
	_hud.focus_mode = Control.FOCUS_CLICK
	_hud.add_theme_font_size_override("normal_font_size", 12)
	_hud.text = "[b]%s[/b]\nrunning..." % section_title
	panel.add_child(_hud)


func _process(_delta: float) -> void:
	if _standalone and _hud_status != null:
		_hud_status.text = "%s (standalone, %s)   checks %d   failed %d   Escape quits, C copies the report   %s" % [section_title,
				model_name(), results.size(), failed_count(), status]
		if not _finished:
			_render_standalone_hud()


func _render_standalone_hud() -> void:
	if _hud == null:
		return
	_hud.text = render_results_bbcode() + hud_extra()


## BBCode block of this section's results: failures first, then every check by case.
func render_results_bbcode() -> String:
	var failed := failed_count()
	var gaps := gap_count()
	var t := "[b]%s[/b]   checks=%d  [color=#8f8]passed=%d[/color]  [color=#f88]failed=%d[/color]  [color=#fc8]known gaps=%d[/color]\n\n" \
			% [section_title, results.size(), results.size() - failed - gaps, failed, gaps]
	if failed > 0:
		t += "[b]Failures[/b]\n"
		for r in results:
			if not r.pass and not r.gap:
				t += "[color=#f88]FAIL[/color] %s: %s\n      expected %s, got %s\n" \
						% [r.case, r.desc, r.expected, r.actual]
		t += "\n"
	if gaps > 0:
		t += "[b]Known gaps[/b]\n"
		for r in results:
			if not r.pass and r.gap:
				t += "[color=#fc8]GAP[/color] %s: %s\n      expected %s, got %s\n" \
						% [r.case, r.desc, r.expected, r.actual]
		t += "\n"
	t += "[b]All checks[/b]\n"
	var last_case := ""
	for r in results:
		if r.case != last_case:
			last_case = r.case
			t += "[color=#9cf]%s[/color]\n" % r.case
		t += "  %s %s [color=#888](%s / %s)[/color]\n" % [
				"[color=#8f8]ok[/color]" if r.pass else ("[color=#fc8]GAP[/color]" if r.gap else "[color=#f88]FAIL[/color]"),
				r.desc, r.expected, r.actual]
	return t
