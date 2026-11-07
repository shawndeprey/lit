extends "res://Test/integration_tests/line_light_review/demo_base.gd"

## Walkthrough of issue 5: a curved LitLineLight2D on RAYMARCHED shadows marches
## `shadow_samples` full rays per pixel, but the inspector hides `shadow_samples` on
## RAYMARCHED and the docs say "one hard march". See checks/05_raymarch_curved_samples_check.gd.

const PANEL_S := Rect2(20, 64, 610, 470)
const PANEL_C := Rect2(650, 64, 610, 470)
const RANGE := 140.0
const SAMPLE_SET := [1, 2, 4, 8, 16, 32]
const HOLD := 2.0          # seconds (at 1x) per sample value in the ramp steps
const SETTLE := 0.8        # of which the first part is not measured

var _straight: Array[LitLineLight2D] = []
var _curved: Array[LitLineLight2D] = []
var _graph: Graph
var _slider: HiddenSlider
var _inspector: Inspector
var _samples := 8
var _gpu_sum := 0.0
var _gpu_n := 0
var _cur_idx := -1
var _vp: RID
var _prev_vsync := DisplayServer.VSYNC_ENABLED
var _phase: Label
var _insets: Array[Sprite2D] = []
var _inset_lbls: Array[Label] = []
var _flash := -1


func demo_title() -> String:
	return "Issue 5 - Curved line lights on Raymarched: cost set by a hidden setting"


func build() -> void:
	_prev_vsync = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	var occ := group("Occluders")
	for k in 2:
		var rect: Rect2 = [PANEL_S, PANEL_C][k]
		floor_receiver(rect)
		for row in 2:
			for col in 3:
				var c := rect.position + Vector2(rect.size.x * (col + 0.5) / 3.0, 60 + (rect.size.y - 60) * (row + 0.5) / 2.0)
				var l := line_light(c, 120.0 if k == 0 else 0.0, RANGE, 0.7, 60.0)
				if k == 1:
					var path := Path2D.new()
					var curve := Curve2D.new()
					curve.add_point(Vector2(-60, 0), Vector2.ZERO, Vector2(35, -55))
					curve.add_point(Vector2(60, 0), Vector2(-35, 55), Vector2.ZERO)
					path.curve = curve
					l.add_child(path)
				l.shadow_enabled = true
				l.shadow_algorithm = ALGO.RAYMARCHED
				l.shadow_samples = _samples
				(_straight if k == 0 else _curved).append(l)
				occluder(c + Vector2(-35, 55), Vector2(22, 22), occ)
				occluder(c + Vector2(45, -50), Vector2(14, 30), occ)
	panel(PANEL_S, "expected", "6 straight line lights, RAYMARCHED (control)")
	panel(PANEL_C, "actual", "6 curved line lights, RAYMARCHED")
	_phase = readout(Vector2(40, 490), 22, C_NOTE)
	_inspector = Inspector.new()
	_inspector.demo = self
	_ui.add_child(_inspector)
	_inspector.setup()
	_slider = HiddenSlider.new()
	_slider.demo = self
	_ui.add_child(_slider)
	_graph = graph(Rect2(110, 600, 560, 200))
	_graph.title = "GPU frame time vs shadow_samples (both RAYMARCHED)"
	_graph.x_min = -0.2
	_graph.x_max = 5.2
	_graph.y_min = 0.0
	_graph.y_max = 4.0
	_graph.x_ticks = [[0.0, "1"], [1.0, "2"], [2.0, "4"], [3.0, "8"], [4.0, "16"], [5.0, "32"]]
	_graph.y_ticks = [[0.0, "0 ms"], [1.0, "1"], [2.0, "2"], [3.0, "3"], [4.0, "4"]]
	_graph.x_label = "shadow_samples (hidden in the inspector on RAYMARCHED)"
	_graph.add_series("straight lights", C_EXPECTED)
	_graph.add_series("curved lights", C_ACTUAL)
	for i in 2:
		var spr := Sprite2D.new()
		spr.position = Vector2(1300 + i * 305, 610)
		spr.visible = false
		_ui.add_child(spr)
		_insets.append(spr)
		var il := _ui_label("", spr.position + Vector2(0, -24), 17, C_ACTUAL)
		il.visible = false
		_inset_lbls.append(il)

	add_step("What the docs and the inspector say",
			"Both panels use %s shadows, documented on %s as %s - the cheapest algorithm. The inspector agrees (right): on Raymarched it hides %s, because only Cone Traced and Stochastic use samples... supposedly. Every light here is on the default %s." % [
			code("Raymarched"), code("LitLineLight2D"), y("\"Raymarched casts one hard march\""), code("shadow_samples"), code("shadow_samples = 8")],
			11.0, _s_intro, _s_intro_tick)
	add_step("Control: straight lights, shadow_samples 1 -> 32",
			"Only the %s are on. We step the hidden %s from 1 to 32 (the slider shows the value you cannot see in the inspector) and record GPU time. The %s line stays %s: a straight line light on Raymarched really is one hard march." % [
			g("straight lights"), code("shadow_samples"), g("green"), g("flat")],
			HOLD * SAMPLE_SET.size() + 1.0, _s_ramp_straight, _s_ramp_tick)
	add_step("Curved lights, shadow_samples 1 -> 32",
			"Now only the %s are on, same steps. The %s line %s: on Raymarched a curved line light marches %s full hard rays per pixel - one per shadow chord - with no early-out gate. At the default 8 it already costs several times a straight light, and nothing in the inspector shows why or lets you lower it." % [
			r("curved lights"), r("red"), r("climbs"), r("shadow_samples")],
			HOLD * SAMPLE_SET.size() + 1.0, _s_ramp_curved, _s_ramp_tick)
	add_step("BEFORE / AFTER: the hidden setting changes the picture",
			"The curved lights flip between %s and %s every 2.5 s. The shadows change shape and softness (3x zoom, right) - so the setting the inspector hides is not only a cost, it is also part of the look, and a scene that changes it from code (or a default change) silently alters Raymarched curved shadows." % [
			y("shadow_samples 1 (BEFORE)"), y("32 (AFTER)")],
			15.0, _s_look, _s_look_tick)
	add_step("Summary",
			"In %s a curved line on algorithm 0 calls %s with n = %s, which runs one full %s per chord. Meanwhile %s hides %s unless the algorithm is Stochastic (the line light re-shows it for Cone Traced only). Fix: either march one hard ray from the nearest point on Raymarched (as documented), or show %s for curved lights on Raymarched and document the cost." % [
			code("lit_shade.gdshaderinc"), code("lit_shadow_path_hard()"), code("shadow_samples"), code("lit_shadow()"),
			code("LitShaderLibrary.validate_light_property()"), code("shadow_samples"), code("shadow_samples")],
			10.0, _s_summary, Callable())


func _exit_tree() -> void:
	DisplayServer.window_set_vsync_mode(_prev_vsync)
	super()


# --- Helpers ------------------------------------------------------------------------------

func set_samples(n: int) -> void:
	_samples = n
	for l in _straight + _curved:
		l.shadow_samples = n


func _enable(straight: bool, curved: bool) -> void:
	for l in _straight:
		l.enabled = straight
	for l in _curved:
		l.enabled = curved


func _hide_insets() -> void:
	for s in _insets:
		s.visible = false
	for l in _inset_lbls:
		l.visible = false


# --- Steps --------------------------------------------------------------------------------

func _s_intro() -> void:
	_phase.position = Vector2(40, 490)
	_enable(true, true)
	set_samples(8)
	_graph.visible = false
	_phase.text = ""
	_hide_insets()


func _s_intro_tick(_f: float, _t: float) -> void:
	pass


var _ramp_series := ""


func _s_ramp_straight() -> void:
	_enable(true, false)
	_ramp_series = "straight lights"
	_ramp_start()
	_phase.text = "curved lights switched off for this measurement"


func _s_ramp_curved() -> void:
	_enable(false, true)
	_ramp_series = "curved lights"
	_ramp_start()
	_phase.text = "straight lights switched off for this measurement"


func _ramp_start() -> void:
	_phase.position = Vector2(40, 490)
	_graph.visible = true
	_hide_insets()
	_graph.series[_ramp_series].pts = PackedVector2Array()
	_cur_idx = -1
	_gpu_sum = 0.0
	_gpu_n = 0


func _s_ramp_tick(_f: float, t: float) -> void:
	var idx := clampi(int((t - 0.5) / HOLD), 0, SAMPLE_SET.size() - 1)
	if t < 0.5:
		return
	if idx != _cur_idx:
		if _cur_idx >= 0 and _gpu_n > 0:
			_graph.push(_ramp_series, float(_cur_idx), _gpu_sum / float(_gpu_n))
		_cur_idx = idx
		_gpu_sum = 0.0
		_gpu_n = 0
		set_samples(SAMPLE_SET[idx])
	var in_hold := (t - 0.5) - float(idx) * HOLD
	if in_hold > SETTLE:
		_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
		_gpu_n += 1
	if t >= 0.5 + HOLD * SAMPLE_SET.size() - 0.05 and _gpu_n > 0 and _graph.series[_ramp_series].pts.size() < SAMPLE_SET.size():
		_graph.push(_ramp_series, float(_cur_idx), _gpu_sum / float(_gpu_n))
		_gpu_n = 0
	_graph.cursor = float(idx)


func _s_look() -> void:
	_phase.position = Vector2(670, 490)
	_enable(false, true)
	_graph.visible = true
	_flash = -1
	_phase.text = ""
	_hide_insets()


func _s_look_tick(_f: float, t: float) -> void:
	var st := int(t / 2.5) % 2
	if st != _flash:
		_flash = st
		set_samples(32 if st == 1 else 1)
		_phase.text = "AFTER: shadow_samples 32" if st == 1 else "BEFORE: shadow_samples 1"
	# Capture each state once, late in its window, for the side-by-side zoom.
	var into := fmod(t, 2.5)
	if into > 2.0 and into < 2.4:
		var i := st
		if not _insets[i].visible:
			var img := frame_image()
			zoom_inset(_insets[i], img, _curved[0].global_position + Vector2(-10, 50), Vector2i(48, 40), 3.0)
			_insets[i].visible = true
			_inset_lbls[i].text = "shadow_samples %d (3x)" % (32 if i == 1 else 1)
			_inset_lbls[i].visible = true


func _s_summary() -> void:
	_phase.position = Vector2(40, 490)
	_enable(true, true)
	set_samples(8)
	_phase.text = ""


# --- Mock inspector and the hidden slider -------------------------------------------------

class Inspector extends Node2D:
	var demo
	var shown_ray: PackedStringArray = []
	var shown_sto: PackedStringArray = []
	const AREA := Rect2(1290, 70, 610, 470)

	func setup() -> void:
		var probe := LitLineLight2D.new()
		probe.shadow_enabled = true
		probe.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.RAYMARCHED
		shown_ray = _shadow_props(probe)
		probe.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.STOCHASTIC
		shown_sto = _shadow_props(probe)
		probe.free()

	## Editor-visible properties in the light's shadow groups, as the inspector lists them.
	static func _shadow_props(l: Object) -> PackedStringArray:
		var out := PackedStringArray()
		var in_shadow := false
		for p in l.get_property_list():
			if p.usage & PROPERTY_USAGE_GROUP:
				in_shadow = String(p.name).to_lower().contains("shadow")
				continue
			if p.usage & PROPERTY_USAGE_CATEGORY:
				in_shadow = false
				continue
			if in_shadow and p.usage & PROPERTY_USAGE_EDITOR:
				out.append(p.name)
		return out

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(AREA, Color(0.13, 0.14, 0.17))
		draw_rect(AREA, Color(0.35, 0.36, 0.42), false, 1.0)
		draw_string(font, AREA.position + Vector2(14, 28), "Inspector: LitLineLight2D, Shadow groups", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.95, 0.95, 1))
		var cols := [["shadow_algorithm = Raymarched", shown_ray, AREA.position + Vector2(14, 66)],
				["shadow_algorithm = Stochastic", shown_sto, AREA.position + Vector2(314, 66)]]
		for c in cols:
			var p: Vector2 = c[2]
			draw_string(font, p, c[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 0.84, 0.25))
			var yy := p.y + 30
			for name in c[1]:
				var hit: bool = name == "shadow_samples"
				draw_string(font, Vector2(p.x + 6, yy), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
						Color(0.36, 0.9, 0.45) if hit else Color(0.82, 0.82, 0.88))
				yy += 22
			if not c[1].has("shadow_samples"):
				draw_string(font, Vector2(p.x + 6, yy + 6), "(no shadow_samples)", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1.0, 0.4, 0.35))
		var by := AREA.end.y - 74
		draw_line(Vector2(AREA.position.x + 10, by - 18), Vector2(AREA.end.x - 10, by - 18), Color(0.3, 0.3, 0.36), 1.0)
		draw_string(font, Vector2(AREA.position.x + 14, by + 4), "hidden on Raymarched, but a curved light marches", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.45, 0.4))
		draw_string(font, Vector2(AREA.position.x + 14, by + 28), "shadow_samples = %d full rays per pixel" % demo._samples, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1.0, 0.45, 0.4))


class HiddenSlider extends Node2D:
	var demo
	const AREA := Rect2(700, 600, 480, 40)

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_string(font, AREA.position + Vector2(0, -12), "shadow_samples (the value the inspector won't show)", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.9, 0.9, 0.95))
		draw_rect(Rect2(AREA.position + Vector2(0, 16), Vector2(AREA.size.x, 8)), Color(0.25, 0.25, 0.3))
		var f := (log(float(demo._samples)) / log(2.0)) / 5.0
		draw_rect(Rect2(AREA.position + Vector2(0, 16), Vector2(AREA.size.x * f, 8)), Color(1.0, 0.45, 0.4))
		draw_circle(AREA.position + Vector2(AREA.size.x * f, 20), 11.0, Color(1, 0.84, 0.25))
		for k in 6:
			var x := AREA.position.x + AREA.size.x * float(k) / 5.0
			draw_string(font, Vector2(x - 8, AREA.end.y + 18), str(1 << k), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.7, 0.75))
		draw_string(font, AREA.position + Vector2(AREA.size.x + 20, 28), str(demo._samples), HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(1, 0.84, 0.25))
