extends "res://Test/integration_tests/line_light_review/demo_base.gd"

## Walkthrough of issue 3: close_mode BIARC blows up when the path's end directions are
## nearly parallel and point away from the gap, and the huge loop coarsens every shadow in
## the scene. See checks/03_biarc_close_blowup_check.gd for the automated version.

const GAP := 200.0
const BASE_DEG := 120.0
const SEP_FROM := 40.0
const SEP_TO := 0.1
const PANEL_A := Rect2(20, 64, 610, 420)
const PANEL_B := Rect2(650, 64, 610, 420)
const PANEL_C := Rect2(20, 500, 1240, 364)
const PT_POS := Vector2(640, 682)
## [offset from the light, size, label, label offset]: each caster's thickness along the
## light direction is what the shadow map has to resolve.
const CASTERS := [[Vector2(110, 0), Vector2(8, 60), "8 px thick", Vector2(-40, -62)],
		[Vector2(0, 110), Vector2(60, 16), "16 px thick", Vector2(40, -10)],
		[Vector2(-110, 0), Vector2(32, 60), "32 px thick", Vector2(-50, -62)],
		[Vector2(0, -110), Vector2(60, 64), "64 px thick", Vector2(40, -10)]]

var _lights: Array[LitLineLight2D] = []
var _curve: Curve2D
var _arrows: Array[Line2D] = []
var _gap_line: Line2D
var _sep_lbl: Label
var _size_lbls: Array[Label] = []
var _texel_lbl: Label
var _phase_lbl: Label
var _graph: Graph
var _map: LoopMap
var _sep := SEP_FROM
var _sample_tick := 0
var _flash_state := -1


func demo_title() -> String:
	return "Issue 3 - BIARC close: a 200 px gap can close with a 117,000 px loop"


func build() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	var occ := group("Occluders")
	var rects := [PANEL_A, PANEL_B, PANEL_C]
	for i in 3:
		var fl := floor_receiver(rects[i])
		fl.receiver_mask = 1 << i
	panel(PANEL_A, "expected", "close_mode SYMMETRIC (the default)")
	panel(PANEL_B, "actual", "close_mode BIARC")
	panel(PANEL_C, "neutral", "SAME SCENE: an unrelated point light and four shadow casters")
	_curve = _make_curve(SEP_FROM)
	for i in 2:
		var rect: Rect2 = [PANEL_A, PANEL_B][i]
		var l := line_light(rect.get_center() + Vector2(0, 20), 0.0, 60.0, 0.75, 40.0)
		l.light_mask = 1 << i
		l.shadow_enabled = true
		l.shadow_algorithm = ALGO.RAYMARCHED
		var path := Path2D.new()
		path.curve = _curve
		l.add_child(path)
		l.closed = true
		l.close_mode = LitLineLight2D.CloseMode.SYMMETRIC if i == 0 else LitLineLight2D.CloseMode.BIARC
		_lights.append(l)
		_size_lbls.append(readout(rect.position + Vector2(16, 380), 20, C_EXPECTED if i == 0 else C_ACTUAL))
		for e in 2:
			_arrows.append(overlay_line(PackedVector2Array([Vector2.ZERO, Vector2.ZERO]), Color(0.4, 0.8, 1.0), 3.0))
	_gap_line = overlay_line(PackedVector2Array([Vector2.ZERO, Vector2.ZERO]), Color(1, 1, 1, 0.5), 1.0)
	_sep_lbl = readout(Vector2(36, 104), 22, Color(0.4, 0.8, 1.0))
	var pt := point_light(PT_POS, 300.0, 0.9, Color.WHITE, 60.0)
	pt.light_mask = 4
	pt.shadow_enabled = true
	pt.shadow_algorithm = ALGO.RAYMARCHED
	for c in CASTERS:
		occluder(PT_POS + c[0], c[1], occ)
		label(c[2], PT_POS + c[0] + c[3], 16, C_NOTE)
	_texel_lbl = readout(Vector2(40, 540), 24, C_NOTE)
	_phase_lbl = readout(Vector2(40, 800), 28, C_NOTE)

	_graph = graph(Rect2(1350, 560, 500, 220))
	_graph.title = "size of the closed path vs end-direction difference"
	_graph.x_min = -log(SEP_FROM) / log(10.0)
	_graph.x_max = -log(SEP_TO) / log(10.0)
	_graph.y_min = 2.0
	_graph.y_max = 5.3
	_graph.x_ticks = [[-log(40.0) / log(10.0), "40 deg"], [-1.0, "10 deg"], [0.0, "1 deg"], [1.0, "0.1 deg"]]
	_graph.y_ticks = [[2.0, "100 px"], [3.0, "1k"], [4.0, "10k"], [5.0, "100k"]]
	_graph.x_label = "end directions differ by (log scale)"
	_graph.add_series("BIARC (bug)", C_ACTUAL)
	_graph.add_series("SYMMETRIC (expected)", C_EXPECTED)
	_map = LoopMap.new()
	_map.demo = self
	_ui.add_child(_map)

	add_step("The setup",
			"Both panels hold the same open %s: an S-curve whose two ends are 200 px apart (white line), each end heading %s from that gap (blue arrows). %s joins the ends. %s closes it with a small smooth piece. %s uses two circular arcs (Bolton's biarc). Right now the end directions differ by 40 deg and both look reasonable. Bottom: an unrelated point light whose four casters (8 to 64 px) cast normal shadows." % [
			code("Path2D"), y("away"), code("closed = true"), g("SYMMETRIC (left, the default)"), r("BIARC (right)")],
			11.0, _s_setup, _s_setup_tick)
	add_step("Slow motion: the end directions become parallel",
			"The curve's start handle turns slowly until the two end directions differ by only %s. %s grows a little. %s's joint point runs away: the loop grows to ~1,400 px at 10 deg, ~11,700 px at 1 deg and ~117,000 px at 0.1 deg (graph, log scale; minimap top right shows the whole loop, the authored curve is the tiny knot). Its two long arcs leave panel B as straight-looking lit lines." % [
			y("0.1 deg"), g("SYMMETRIC"), r("BIARC")],
			20.0, _s_sweep, _s_sweep_tick)
	add_step("Knock-on: every shadow in the scene",
			"Lit sizes its world %s to cover every shadow-casting light's bounds. The BIARC light's bounds are now ~117,000 px, so each shadow-map texel grows from ~2 px to ~%s. The unrelated point light (bottom) can no longer resolve its casters: the 8 px one's shadow %s and the others turn into %s." % [
			y("shadow map (SDF)"), r("69 px"), r("disappears"), r("lumpy, misshapen blobs")],
			12.0, _s_knock, _s_knock_tick)
	add_step("BEFORE / AFTER, back and forth",
			"The end directions flip between %s and %s every 2.5 s. Watch the BIARC panel's lit lines, the texel size and the point light's shadows in the bottom panel come and go. Nothing about the point light or its casters changes - only the closing of a curve elsewhere in the scene." % [
			g("40 deg apart (BEFORE)"), r("0.1 deg apart (AFTER)")],
			15.0, _s_flash, _s_flash_tick)
	add_step("Summary",
			"%s (line_path.gd) uses the equal-distance biarc: %s grows like |vt| / k when k = 1 - t0.t1 -> 0 and the tangents point away from the gap (vt < 0). Its only guard (%s) never trips because both bulges stay near -1. %s then merges the huge %s into the SDF window. A fix: fall back to SOFT_ARC / STRAIGHT (or pick an unequal-distance biarc) when the joint lands farther than a few gap lengths away." % [
			code("LinePath.biarc()"), code("dl = (sqrt(vt^2 + 2k|v|^2) - vt) / 2k"), code("|bulge| <= 1e4"), code("world_sdf.gd:128"), code("path_rect_in()")],
			10.0, _s_summary, _s_summary_tick)


# --- Scene control ------------------------------------------------------------------------

## Open cubic S-curve from (+GAP/2, 0) to (-GAP/2, 0): it leaves its start heading
## BASE_DEG + sep and arrives at its end heading BASE_DEG (both away from the gap).
func _make_curve(sep_deg: float) -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(GAP * 0.5, 0), Vector2.ZERO, Vector2.from_angle(deg_to_rad(BASE_DEG + sep_deg)) * 120.0)
	c.add_point(Vector2(-GAP * 0.5, 0), -Vector2.from_angle(deg_to_rad(BASE_DEG)) * 120.0, Vector2.ZERO)
	return c


func _set_sep(sep: float) -> void:
	_sep = sep
	_curve.set_point_out(0, Vector2.from_angle(deg_to_rad(BASE_DEG + sep)) * 120.0)
	for l in _lights:
		l.is_curved()   # refit now, so the readouts below are current
	for i in 2:
		var o := _lights[i].global_position
		var start := o + Vector2(GAP * 0.5, 0)
		var end := o + Vector2(-GAP * 0.5, 0)
		_arrows[i * 2].points = PackedVector2Array([start, start + Vector2.from_angle(deg_to_rad(BASE_DEG + sep)) * 55.0])
		_arrows[i * 2 + 1].points = PackedVector2Array([end, end + Vector2.from_angle(deg_to_rad(BASE_DEG)) * 55.0])
		var r := _lights[i].path_rect()
		_size_lbls[i].text = "%s: closed path %s x %s px" % ["SYMMETRIC" if i == 0 else "BIARC",
				fmt_px(r.size.x), fmt_px(r.size.y)]
	var o0 := _lights[1].global_position
	_gap_line.points = PackedVector2Array([o0 + Vector2(-GAP * 0.5, 0), o0 + Vector2(GAP * 0.5, 0)])
	_sep_lbl.text = "end directions differ by %s deg" % ("%.1f" % sep if sep >= 1.0 else "%.2f" % sep)
	_map.queue_redraw()


static func fmt_px(v: float) -> String:
	var n := roundi(v)
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _texel() -> float:
	var mgr := get_node_or_null("/root/LitManager")
	return float(mgr._registry._world_sdf._wsdf_texel) if mgr != null else -1.0


func _update_texel() -> void:
	_texel_lbl.text = "world shadow-map texel: %.1f px" % _texel()


# --- Steps --------------------------------------------------------------------------------

func _s_setup() -> void:
	_set_sep(SEP_FROM)
	_graph.visible = false
	_phase_lbl.text = ""


func _s_setup_tick(_f: float, _t: float) -> void:
	_update_texel()


func _s_sweep() -> void:
	_set_sep(SEP_FROM)
	_graph.visible = true
	_graph.clear_points()
	_sample_tick = 0
	_phase_lbl.text = ""


func _s_sweep_tick(f: float, _t: float) -> void:
	var e := smoothstep(0.03, 0.92, f)
	var sep := SEP_FROM * pow(SEP_TO / SEP_FROM, e)
	_sample_tick += 1
	if _sample_tick % 2 == 0 or f >= 1.0:
		_set_sep(sep)
		var x := -log(sep) / log(10.0)
		for i in 2:
			var r := _lights[i].path_rect()
			_graph.push("BIARC (bug)" if i == 1 else "SYMMETRIC (expected)", x, log(maxf(maxf(r.size.x, r.size.y), 1.0)) / log(10.0))
		_graph.cursor = x
	_update_texel()


func _s_knock() -> void:
	_set_sep(SEP_TO)
	_graph.visible = true
	_phase_lbl.text = "AFTER: end directions 0.1 deg apart"


func _s_knock_tick(_f: float, _t: float) -> void:
	_update_texel()


func _s_flash() -> void:
	_flash_state = -1
	_graph.visible = true


func _s_flash_tick(_f: float, t: float) -> void:
	var after := int(t / 2.5) % 2 == 1
	var st := 1 if after else 0
	if st != _flash_state:
		_flash_state = st
		_set_sep(SEP_TO if after else SEP_FROM)
		_phase_lbl.text = "AFTER: 0.1 deg apart" if after else "BEFORE: 40 deg apart"
	_update_texel()


func _s_summary() -> void:
	_set_sep(1.0)
	_phase_lbl.text = "end directions 1 deg apart"


func _s_summary_tick(_f: float, _t: float) -> void:
	_update_texel()


# --- Loop minimap -------------------------------------------------------------------------

class LoopMap extends Node2D:
	var demo
	const AREA := Rect2(1300, 100, 580, 360)

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(AREA.grow(8), Color(0.05, 0.05, 0.07, 0.95))
		draw_string(font, AREA.position + Vector2(0, -12), "BIARC light's closed path, whole extent", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.95, 0.95, 1))
		var l: LitLineLight2D = demo._lights[1]
		var chain = l.path_chain()
		if chain == null:
			return
		var inv := l.global_transform * l.path_fit_xf().affine_inverse()
		var pts := PackedVector2Array()
		for i in chain.bulges.size():
			for k in 24:
				pts.append(inv * LitLineLight2D.LinePathScript.arc_point(chain.points[i], chain.points[i + 1], chain.bulges[i], float(k) / 24.0))
		pts.append(inv * chain.points[chain.points.size() - 1])
		var screen := Rect2(0, 0, 1920, 1080)
		var bb := screen
		for p in pts:
			bb = bb.expand(p)
		var s := minf(AREA.size.x / bb.size.x, AREA.size.y / bb.size.y) * 0.92
		var off := AREA.get_center() - bb.get_center() * s
		var mapped := PackedVector2Array()
		for p in pts:
			mapped.append(off + p * s)
		var scr := Rect2(off + screen.position * s, screen.size * s)
		draw_rect(scr, Color(1, 1, 1, 0.8), false, 1.5)
		draw_string(font, scr.position + Vector2(2, -4), "screen", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.8))
		draw_polyline(mapped, Color(1.0, 0.4, 0.3), 2.0, true)
		draw_string(font, AREA.position + Vector2(0, AREA.size.y + 24),
				"loop %s x %s px   (screen box = 1920 x 1080 for scale)" % [demo.fmt_px(bb.size.x), demo.fmt_px(bb.size.y)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.85, 0.85, 0.9))
