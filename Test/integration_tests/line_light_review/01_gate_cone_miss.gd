extends "res://Test/integration_tests/line_light_review/demo_base.gd"

## Walkthrough of issue 1: soft shadows of a STRAIGHT line light can be wrong near its
## ends (Cone Traced / Stochastic). See checks/01_gate_cone_miss_check.gd for the
## automated version and the code references.

const TUBE_L := 1050.0
const END_X := 1150.0
const DROP := 80.0
const RANGE := 1120.0
const SAMPLES := 32
const SOURCE_R := 1.0
const ENERGY := 0.25
const PANELS := [Rect2(20, 64, 1880, 396), Rect2(20, 468, 1880, 396)]
const ORBIT := 55.0
const BLK_R := 14.0
const A_ANGLE := 237.0
const B_DIST := 150.0
const SWEEP_FROM := 268.0
const SWEEP_TO := 182.0

var _lights: Array[LitLineLight2D] = []
var _p: Array[Vector2] = []
var _mid: Array[Vector2] = []
var _occ: Array[LightOccluder2D] = []
var _blk_fill: Array[Polygon2D] = []
var _blk_line: Array[Line2D] = []
var _rays: Array = [[], []]
var _wedge_fill: Polygon2D
var _wedge_edges: Array[Line2D] = []
var _q_ring: Line2D
var _readouts: Array[Label] = []
var _states: Array[Label] = []
var _counter: Label
var _open := [0.0, 0.0]
var _graph: Graph
var _insets: Array[Sprite2D] = []
var _inset_lbls: Array[Label] = []
var _inset_rings: Array[Line2D] = []
var _inset_state := 0
var _ov: Node2D
var _before := [1.0, 1.0]
var _sample_tick := 0
var _gate_w := 0.0
var _b_r := 0.0


func demo_title() -> String:
	return "Issue 1 - Straight line light: soft shadows go wrong near the tube's ends"


func build() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	# Occluders live in their own group: as siblings of the floors, the floors would own
	# them and Lit would exclude them from the floors' shadows.
	var blockers := group("Blockers")
	_ov = group("Overlays")   # everything drawn over the floor near P, hidden for the zoom captures
	_ov.z_index = 50          # above the floors (created after this group)
	for i in 2:
		var rect: Rect2 = PANELS[i]
		var fl := floor_receiver(rect)
		fl.receiver_mask = 1 << i
		var tube_y := rect.position.y + 130.0
		var c := Vector2(END_X - TUBE_L * 0.5, tube_y)
		_mid.append(c)
		var l := line_light(c, TUBE_L, RANGE, ENERGY, 100.0)
		l.light_mask = 1 << i
		l.shadow_enabled = true
		l.shadow_algorithm = ALGO.CONE_TRACED
		l.shadow_samples = SAMPLES
		l.source_radius = SOURCE_R
		l.shadow_jitter = 0.0
		if i == 1:
			var path := Path2D.new()
			var curve := Curve2D.new()
			curve.add_point(Vector2(-TUBE_L * 0.5, 0), Vector2.ZERO, Vector2(TUBE_L / 3.0, -4.0))
			curve.add_point(Vector2(TUBE_L * 0.5, 0), Vector2(-TUBE_L / 3.0, -4.0), Vector2.ZERO)
			path.curve = curve
			l.add_child(path)
		_lights.append(l)
		var p := Vector2(END_X, tube_y + DROP)
		_p.append(p)
		if i == 0:
			panel(rect, "actual", "a straight LitLineLight2D, 1050 px long (Cone Traced shadows)")
		else:
			panel(rect, "expected", "the same tube bent by 3 px with a Path2D child (Lit's curved-path shadows)")
		overlay_line(PackedVector2Array([Vector2(100, tube_y), Vector2(END_X, tube_y)]), Color(1, 1, 1, 0.25), 1.0, _ov)
		label("tube", Vector2(110, tube_y - 22), 14, C_DIM, _ov)
		overlay_circle(p, 7.0, Color(0.2, 1.0, 0.4), 2.0, _ov)
		label("P", p + Vector2(-26, 4), 18, Color(0.2, 1.0, 0.4), _ov)
		_readouts.append(readout(p + Vector2(-440, 22), 22, C_ACTUAL if i == 0 else C_EXPECTED, _ov))
		_states.append(readout(Vector2(560, rect.position.y + 300), 26, C_NOTE))
		var holder := group("Rays%d" % i, _ov)
		for k in SAMPLES:
			_rays[i].append(overlay_line(PackedVector2Array([p, p]), Color(0.7, 0.7, 0.7, 0.5), 1.0, holder))
		_occ.append(disc_occluder(Vector2(-9000, -9000), BLK_R, blockers))
		_blk_fill.append(overlay_poly(circle_points(Vector2.ZERO, BLK_R), Color(0.35, 0.35, 0.4), _ov))
		_blk_line.append(overlay_line(circle_points(Vector2.ZERO, BLK_R), Color(0.9, 0.9, 0.95), 1.5, _ov))
		_blk_line[i].closed = true
	_wedge_fill = overlay_poly(PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]), Color(1, 0.85, 0.1, 0.12), _ov)
	for s in 2:
		_wedge_edges.append(overlay_line(PackedVector2Array([Vector2.ZERO, Vector2.ZERO]), Color(1, 0.88, 0.15, 0.95), 2.0, _ov))
	_q_ring = overlay_circle(Vector2.ZERO, 9.0, Color(1, 1, 1), 2.0, _ov)
	_counter = readout(Vector2(140, PANELS[0].position.y + 300), 24, C_ACTUAL)
	var gate := _gate(_p[0])
	_gate_w = gate.w
	_b_r = _gate_w * B_DIST * 1.3

	_graph = graph(Rect2(1340, 150, 520, 560))
	_graph.title = "light at P while the blocker circles P"
	_graph.x_min = 0.0
	_graph.x_max = SWEEP_FROM - SWEEP_TO
	_graph.y_min = 0.0
	_graph.y_max = 1.1
	_graph.y_ticks = [[0.0, "0%"], [0.5, "50%"], [1.0, "100%"]]
	_graph.x_ticks = [[0.0, "above"], [(SWEEP_FROM - SWEEP_TO) * 0.5, "diagonal"], [SWEEP_FROM - SWEEP_TO, "level"]]
	_graph.x_label = "blocker position: from above P  ->  level with P (left)"
	_graph.add_series("straight tube (bug)", C_ACTUAL)
	_graph.add_series("bent tube (expected)", C_EXPECTED)
	_graph.bands = _sweep_bands(gate)
	for i in 2:
		var spr := Sprite2D.new()
		spr.position = Vector2(1340, 110 + i * 404)
		spr.visible = false
		_ui.add_child(spr)
		_insets.append(spr)
		var il := _ui_label("", spr.position + Vector2(0, -26), 18, C_ACTUAL if i == 0 else C_EXPECTED)
		il.visible = false
		_inset_lbls.append(il)
		# P sits at crop (84, 50) of the 128 x 80 crop centred on P + (-20, -10), drawn 4x.
		var ring := Line2D.new()
		ring.points = circle_points(spr.position + Vector2(84, 50) * 4.0, 14.0)
		ring.closed = true
		ring.width = 2.0
		ring.default_color = Color(0.2, 1.0, 0.4)
		ring.visible = false
		_ui.add_child(ring)
		_inset_rings.append(ring)

	add_step("Two nearly identical line lights",
			"Two %s tubes, 1050 px long. The tube itself is invisible - you see its light on the floor (the faint line marks it). %s: an ordinary straight line light. %s: the same tube bent by just 3 px with a Path2D child - practically the same light, but its shadows go through Lit's curved-path code, which handles this case correctly. Both use %s shadows. Watch the pixel %s just below the right end of each tube." % [
			code("LitLineLight2D"), r("TOP"), g("BOTTOM"), code("Cone Traced"), y("P")],
			8.0, _s_setup, _s_setup_tick)
	add_step("How Lit computes a soft line shadow",
			"For a soft shadow, Lit splits the tube into 32 pieces and traces a narrow cone from P toward each one (grey lines); P's brightness is the share of cones that get through. First it takes a %s: one wide %s aimed at the %s of the tube. If the gate is completely clear, P is declared %s and the 32 cones are skipped; if it is completely blocked, P is declared %s." % [
			y("shortcut"), y("\"gate\" cone (yellow)"), y("middle"), y("fully lit"), y("fully dark")],
			12.0, _s_rays, _s_rays_tick)
	add_step("The flaw: the gate misses the near end",
			"The gate always points at the %s and is only as wide as the tube looks %s. Watch the white ring slide from under the middle of the tube to P: at first the gate covers every ray, but near the end the rays to the %s part of the tube - the closest, brightest part - fall outside it and turn %s. At P, 8 of the 32 rays are outside the gate: the shortcut cannot see anything that blocks them." % [
			y("middle of the tube"), y("from straight on"), y("nearest"), r("red")],
			12.0, _s_flaw, _s_flaw_tick)
	add_step("BEFORE / AFTER: a blocker beside the near end",
			"%s: nothing between P and the tubes - both read 100%%. %s: a small occluder (grey disc) appears beside the near end of each tube, blocking several %s rays (they now stop at the disc). %s P loses about a quarter of its light - correct. %s P stays at %s: the gate is clear, so the red rays the blocker cuts are never traced." % [
			y("BEFORE"), y("AFTER"), r("red"), g("BOTTOM (expected):"), r("TOP (bug):"), r("100%")],
			14.0, _s_blockA, _s_blockA_tick)
	add_step("Slow motion: the blocker circles P",
			"The blocker moves slowly around P, from straight above it to level with it. %s: P darkens smoothly whenever the blocker crosses rays to the tube. %s: P stays at exactly 100%% while the blocker crosses the %s (red band in the graph), and only reacts once the blocker touches the %s (yellow band) - then it drops all at once, ending in %s while the bent tube keeps about three quarters of its light." % [
			g("GREEN, bent tube (expected)"), r("RED, straight tube (bug)"), r("red rays"), y("yellow gate"), r("pure black")],
			18.0, _s_sweep, _s_sweep_tick)
	add_step("The opposite failure: false black",
			"%s: no blocker. %s: the blocker sits on the gate's axis, just big enough to fill the yellow gate, while every %s ray to the near end stays clear. The shortcut declares P %s. %s P sits in a hard-edged black patch with ragged, speckled edges, where it should be partly lit. %s a smooth partial shadow. (4x zoom on the right.)" % [
			y("BEFORE"), y("AFTER"), r("red"), y("fully dark"), r("TOP (bug):"), g("BOTTOM (expected):")],
			14.0, _s_blockB, _s_blockB_tick)
	add_step("Summary",
			"The gate's width, %s (lit_shade.gdshaderinc, ~line 682), assumes the in-range part of the tube is centred on the point straight across from P. Near a tube's end it isn't, so the early-out in %s (lit_shadow_stoch.gdshaderinc ~118-137) returns %s or %s without tracing the rays it can't see. Affects %s line lights with %s or %s shadows. A fix: aim and size the gate from the window's two endpoints, or reuse the curved path's hull gate." % [
			code("src = source_radius + |window half-vector x march dir|"), code("lit_shadow_stoch()"), y("fully lit"), y("fully dark"),
			y("straight"), code("Cone Traced"), code("Stochastic")],
			10.0, _s_summary, _s_summary_tick)


# --- Geometry -----------------------------------------------------------------------------

## The shader's gate for a pixel at q under the straight tube (window = whole tube here).
func _gate(q: Vector2) -> Dictionary:
	var c: Vector2 = _mid[0]
	var seg := Vector2(TUBE_L * 0.5, 0.0)
	var to_mid := c - q
	var maxd := to_mid.length()
	var dir := to_mid / maxd
	var w := (absf(seg.cross(dir)) + SOURCE_R) / maxd
	return {"dir": dir, "w": w, "half": atan(w), "maxd": maxd}


func _strata(row: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for k in SAMPLES:
		var u := ((float(k) + 0.5) / float(SAMPLES)) * 2.0 - 1.0
		out.append(_mid[row] + Vector2(TUBE_L * 0.5 * u, 0.0))
	return out


## Draws the stratum rays of panel `row` from q. color_gate: red outside the gate.
## blk: the blocker centre (rays stop where they hit it), or null.
func _draw_rays(row: int, q: Vector2, show: bool, color_gate: bool, blk = null, blk_r := BLK_R, count := SAMPLES) -> int:
	var gate := _gate(q - Vector2(0, _mid[row].y - _mid[0].y))
	var outside := 0
	var pts := _strata(row)
	for k in SAMPLES:
		var ln: Line2D = _rays[row][k]
		ln.visible = show and k >= SAMPLES - count
		var s: Vector2 = pts[k]
		var d := (s - q).normalized()
		var out: bool = absf(gate.dir.angle_to(d)) > gate.half
		outside += int(out)
		var end := s
		if blk != null:
			var hit := _ray_disc(q, s, blk, blk_r)
			if hit >= 0.0:
				end = q + (s - q) * hit
		ln.points = PackedVector2Array([q + d * 9.0, end])
		ln.default_color = Color(1.0, 0.28, 0.22, 0.9) if out and color_gate else Color(0.75, 0.75, 0.78, 0.45)
		ln.width = 1.6 if out and color_gate else 1.0
	return outside


func _show_wedge(q: Vector2, show: bool) -> void:
	var gate := _gate(q)
	_wedge_fill.visible = show
	for e in _wedge_edges:
		e.visible = show
	if not show:
		return
	var a: Vector2 = q + gate.dir.rotated(gate.half) * gate.maxd
	var b: Vector2 = q + gate.dir.rotated(-gate.half) * gate.maxd
	_wedge_fill.polygon = PackedVector2Array([q, a, b])
	_wedge_edges[0].points = PackedVector2Array([q + gate.dir.rotated(gate.half) * 9.0, a])
	_wedge_edges[1].points = PackedVector2Array([q + gate.dir.rotated(-gate.half) * 9.0, b])


static func _ray_disc(a: Vector2, b: Vector2, c: Vector2, rad: float) -> float:
	var d := b - a
	var f := a - c
	var qa := d.dot(d)
	var qb := 2.0 * f.dot(d)
	var qc := f.dot(f) - rad * rad
	var disc := qb * qb - 4.0 * qa * qc
	if disc < 0.0:
		return -1.0
	var t := (-qb - sqrt(disc)) / (2.0 * qa)
	return t if t >= 0.0 and t <= 1.0 else -1.0


## Blocker at `pos` relative to each panel's P (null hides it).
func _place_blocker(offset, rad := BLK_R) -> void:
	for i in 2:
		if offset == null:
			_occ[i].position = Vector2(-9000, -9000)
			_blk_fill[i].visible = false
			_blk_line[i].visible = false
			continue
		var pos: Vector2 = _p[i] + offset
		_occ[i].position = pos
		_occ[i].scale = Vector2.ONE * (rad / BLK_R)
		_blk_fill[i].position = pos
		_blk_fill[i].scale = Vector2.ONE * (rad / BLK_R)
		_blk_line[i].position = pos
		_blk_line[i].scale = Vector2.ONE * (rad / BLK_R)
		_blk_fill[i].visible = true
		_blk_line[i].visible = true


func _orbit(angle_deg: float) -> Vector2:
	return Vector2.from_angle(deg_to_rad(angle_deg)) * ORBIT


## Graph bands: where the blocker touches the gate, and where it crosses red rays.
func _sweep_bands(gate: Dictionary) -> Array:
	var axis := rad_to_deg(gate.dir.angle())
	axis = fposmod(axis, 360.0)
	var br := rad_to_deg(asin(BLK_R / ORBIT))
	var g_lo := axis - rad_to_deg(gate.half) - br
	var g_hi := axis + rad_to_deg(gate.half) + br
	var red_lo := 999.0
	var red_hi := -999.0
	var pts := _strata(0)
	for step in 361:
		var ang := SWEEP_TO + (SWEEP_FROM - SWEEP_TO) * float(step) / 360.0
		var c: Vector2 = _p[0] + _orbit(ang)
		for k in SAMPLES:
			var d: Vector2 = (pts[k] - _p[0]).normalized()
			if absf(gate.dir.angle_to(d)) > gate.half and _ray_disc(_p[0], pts[k], c, BLK_R) >= 0.0:
				red_lo = minf(red_lo, ang)
				red_hi = maxf(red_hi, ang)
	var bands := []
	if red_hi > red_lo:
		bands.append([SWEEP_FROM - red_hi, SWEEP_FROM - maxf(red_lo, g_hi), Color(1, 0.3, 0.25, 0.16), "crosses red rays"])
	bands.append([SWEEP_FROM - minf(g_hi, SWEEP_FROM), SWEEP_FROM - maxf(g_lo, SWEEP_TO), Color(1, 0.85, 0.1, 0.18), "touches the gate"])
	return bands


func _share(row: int) -> float:
	var img := frame_image()
	return clampf((lum(img, _p[row], 1) - AMBIENT) / maxf(_open[row] - AMBIENT, 0.001), 0.0, 1.5)


func _update_readouts() -> void:
	for i in 2:
		_readouts[i].text = "light at P: %d%%" % roundi(_share(i) * 100.0)


## Before the change: remember the level. After: show "BEFORE x% -> AFTER y%".
func _before_after_readouts(after: bool) -> void:
	for i in 2:
		var v := _share(i)
		if not after:
			_before[i] = v
			_readouts[i].text = "BEFORE  %d%%" % roundi(v * 100.0)
		else:
			_readouts[i].text = "BEFORE %d%%  ->  AFTER %d%%" % [roundi(_before[i] * 100.0), roundi(v * 100.0)]


func _base_state() -> void:
	_place_blocker(null)
	_show_wedge(_p[0], false)
	for i in 2:
		_draw_rays(i, _p[i], false, false)
		_states[i].text = ""
	_q_ring.visible = false
	_counter.text = ""
	_graph.visible = false
	for s in _insets:
		s.visible = false
	for l in _inset_lbls:
		l.visible = false
	for ring in _inset_rings:
		ring.visible = false


# --- Steps --------------------------------------------------------------------------------

func _s_setup() -> void:
	_base_state()


func _s_setup_tick(_f: float, t: float) -> void:
	if t > 0.5:
		var img := frame_image()
		for i in 2:
			_open[i] = lum(img, _p[i], 1)
			_readouts[i].text = "light at P: 100%"


func _s_rays() -> void:
	_base_state()


func _s_rays_tick(f: float, _t: float) -> void:
	var n := clampi(int(f / 0.55 * SAMPLES), 0, SAMPLES)
	for i in 2:
		_draw_rays(i, _p[i], true, false, null, BLK_R, n)
	_show_wedge(_p[0], f > 0.6)
	if f > 0.6:
		_states[0].text = "yellow = the gate cone"


func _s_flaw() -> void:
	_base_state()
	_q_ring.visible = true


func _s_flaw_tick(f: float, _t: float) -> void:
	var e := smoothstep(0.05, 0.85, f)
	var q := Vector2(lerpf(_mid[0].x, END_X, e), _p[0].y)
	_q_ring.position = q
	_show_wedge(q, true)
	var outside := _draw_rays(0, q, true, true)
	_draw_rays(1, _p[1], false, false)
	_counter.text = "rays outside the gate: %d / %d" % [outside, SAMPLES]


func _s_blockA() -> void:
	_base_state()
	_show_wedge(_p[0], true)


func _s_blockA_tick(f: float, _t: float) -> void:
	var after := f >= 0.3
	_place_blocker(_orbit(A_ANGLE) if after else null)
	for i in 2:
		_draw_rays(i, _p[i], true, i == 0, _p[i] + _orbit(A_ANGLE) if after else null)
		_states[i].text = "AFTER: blocker added" if after else "BEFORE: no blocker"
	_before_after_readouts(after)


func _s_sweep() -> void:
	_base_state()
	_show_wedge(_p[0], true)
	_graph.visible = true
	_graph.clear_points()
	_sample_tick = 0


func _s_sweep_tick(f: float, _t: float) -> void:
	var ang := lerpf(SWEEP_FROM, SWEEP_TO, f)
	_place_blocker(_orbit(ang))
	for i in 2:
		_draw_rays(i, _p[i], true, i == 0, _p[i] + _orbit(ang))
	_update_readouts()
	_sample_tick += 1
	if _sample_tick % 2 == 0 and f > 0.01:
		_graph.push("straight tube (bug)", SWEEP_FROM - ang, _share(0))
		_graph.push("bent tube (expected)", SWEEP_FROM - ang, _share(1))
	_graph.cursor = SWEEP_FROM - ang


func _s_blockB() -> void:
	_base_state()
	_show_wedge(_p[0], true)
	_inset_state = 0
	_ov.visible = true


func _s_blockB_tick(f: float, _t: float) -> void:
	var after := f >= 0.25
	var gate := _gate(_p[0])
	var off: Vector2 = gate.dir * B_DIST
	_place_blocker(off if after else null, _b_r)
	for i in 2:
		_draw_rays(i, _p[i], true, i == 0, _p[i] + off if after else null, _b_r)
		_states[i].text = "AFTER: blocker on the gate's axis" if after else "BEFORE: no blocker"
	if _inset_state != 1:
		_before_after_readouts(after)
	# Zoom captures: hide the overlays for one frame, read that frame back, show them again.
	if after and f >= 0.5 and _inset_state == 0:
		_ov.visible = false
		_inset_state = 1
	elif _inset_state == 1:
		var img := frame_image()
		_ov.visible = true
		_inset_state = 2
		for i in 2:
			zoom_inset(_insets[i], img, _p[i] + Vector2(-20, -10), Vector2i(64, 40), 4.0)
			_insets[i].visible = true
			_inset_lbls[i].text = "4x zoom, P circled (no overlays) - %s" % ("straight (bug)" if i == 0 else "bent (expected)")
			_inset_lbls[i].visible = true
			_inset_rings[i].visible = true


func _s_summary() -> void:
	_base_state()
	_show_wedge(_p[0], true)


func _s_summary_tick(_f: float, _t: float) -> void:
	_place_blocker(_orbit(A_ANGLE))
	for i in 2:
		_draw_rays(i, _p[i], true, i == 0, _p[i] + _orbit(A_ANGLE))
	_update_readouts()
