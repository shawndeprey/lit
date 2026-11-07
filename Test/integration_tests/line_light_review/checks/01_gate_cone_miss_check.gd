extends "res://Test/integration_tests/line_light_review/checks/review_section.gd"

## Issue 1: soft shadows can be wrong near the ends of a straight line light.
##
## Cone Traced and Stochastic shadows of a straight LitLineLight2D first run one "gate"
## cone march and return early when it says fully lit (c >= 1) or fully dark (c <= 0)
## (lit_shadow_stoch.gdshaderinc, lit_shadow_stoch()). The gate is a cone toward the
## middle of the window (the part of the tube within range of the pixel) with half-width
## tangent src / maxd, src = source_radius + |window half-vector x march dir|
## (lit_shade.gdshaderinc, the `src += abs(line_seg ...)` line). That is the window's
## angular half-extent only when the window is centred on the pixel's perpendicular
## foot. Under a tube's end the window runs off to one side, so the near (brightest)
## end lies far outside the gate and the strata aimed at it are never consulted.
##
## Exhibit (both rows): a 512 px tube, the probe P 40 px below its right end, 32 shadow
## samples, source_radius 1, range 560 (the window is the whole tube). The overlay shows
## the gate wedge (yellow) and the 32 stratum rays (grey inside the gate, red outside).
##   Row 1: the straight LitLineLight2D under test.
##   Row 2: the same tube bent by 3 px (a Path2D child), which takes the curved shadow
##          path (lit_shadow_path) with its hull-based gate: the reference.
## Blocker A sits beside the near end, outside the gate, cutting several red rays:
##   correct: P loses some light. Bug: P is exactly as bright as with no blocker.
## Blocker B fills the gate on its axis while the red rays to the near end stay clear:
##   correct: P keeps some light (Lit's own equal-weight strata give ~0.2 here). Bug: the
##   gate's "fully dark" early-out fires on most pixels around P, so the penumbra is
##   speckled pure black among pixels where the strata did run.

const TUBE_LEN := 512.0
const DROP := 40.0
const RANGE := 560.0
const SAMPLES := 32
const SOURCE_R := 1.0
const ENERGY := 0.3
const ROWS := [170.0, 650.0]
const CX := 600.0

var _lights: Array[LitLineLight2D] = []
var _probes: Array[Vector2] = []
var _blk_a: Array[LightOccluder2D] = []
var _blk_b: Array[LightOccluder2D] = []
var _holder: Node2D
var _overlay: Node2D
var _shots := {}   # Cone Traced captures for the insets: open | a | b


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_holder = group("Blockers")
	_overlay = group("Overlay")
	_overlay.visible = false   # hidden while measuring: the probes read the floor, not the lines
	for row in ROWS.size():
		var y0: float = ROWS[row]
		var fl := floor_receiver(Rect2(40, y0 - 110, 1340, 430))
		fl.receiver_mask = 1 << row
		var l := line_light(Vector2(CX, y0), TUBE_LEN, RANGE, ENERGY, 100.0)
		l.light_mask = 1 << row
		l.shadow_enabled = true
		l.shadow_samples = SAMPLES
		l.source_radius = SOURCE_R
		l.shadow_jitter = 0.0
		if row == 1:
			var path := Path2D.new()
			var curve := Curve2D.new()
			# Cubic with both handles 4 px up: the middle sags 3 px away from P.
			curve.add_point(Vector2(-TUBE_LEN * 0.5, 0), Vector2.ZERO, Vector2(TUBE_LEN / 3.0, -4.0))
			curve.add_point(Vector2(TUBE_LEN * 0.5, 0), Vector2(-TUBE_LEN / 3.0, -4.0), Vector2.ZERO)
			path.curve = curve
			l.add_child(path)
		_lights.append(l)
		var p := Vector2(CX + TUBE_LEN * 0.5, y0 + DROP)
		_probes.append(p)
		label("row %d: %s" % [row + 1, "STRAIGHT line light (under test)" if row == 0
				else "same tube bent 3 px via Path2D (reference: curved shadow path)"],
				Vector2(52, y0 - 100), 14)
		_draw_analysis(p, Vector2(CX, y0))
	await frames(4)

	var geo := _geometry(_probes[0], Vector2(CX, ROWS[0]))
	var a_pos: Vector2 = geo.a_pos
	var b_pos: Vector2 = geo.b_pos
	say("SUITE INFO gate half-angle %.1f deg; strata outside the gate: %d of %d; blocker A cuts %d rays (%d inside the gate, touches gate wedge: %s); blocker B cuts %d rays, leaves %d outside-gate rays clear, fills the gate: %s" % [
			rad_to_deg(atan(geo.w)), geo.outside, SAMPLES, geo.a_cut, geo.a_cut_in, str(geo.a_touches),
			geo.b_cut, geo.b_clear_out, str(geo.b_fills)])
	var c0 := "geometry"
	check_gt(c0, "(reference) blocker A cuts stratum rays to the tube's near end", float(geo.a_cut), 0.0)
	check(c0, "(reference) blocker A stays out of the gate wedge", false, geo.a_touches)
	check_gt(c0, "(reference) blocker B leaves outside-gate stratum rays clear", float(geo.b_clear_out), 0.0)

	var any_bug := false
	var detail := ""
	for algo in [ALGO.CONE_TRACED, ALGO.STOCHASTIC]:
		var an: String = ["Raymarched", "Cone Traced", "Stochastic"][algo]
		for l in _lights:
			l.shadow_algorithm = algo
		_clear_blockers()
		var open := await settle_capture()
		for row in ROWS.size():
			var off := Vector2(0, ROWS[row] - ROWS[0])
			_blk_a.append(disc_occluder(a_pos + off, geo.a_r, _holder))
		var img_a := await settle_capture()
		_clear_blockers()
		for row in ROWS.size():
			var off := Vector2(0, ROWS[row] - ROWS[0])
			_blk_b.append(disc_occluder(b_pos + off, geo.b_r, _holder))
		var img_b := await settle_capture()
		_clear_blockers()
		if algo == ALGO.CONE_TRACED:
			_shots = {"open": open, "a": img_a, "b": img_b}

		var c := "gate_%s" % an.to_lower().replace(" ", "_")
		var sa := light_share(img_a, open, _probes[0])
		var sa_ref := light_share(img_a, open, _probes[1])
		var bw := _black_and_spread(img_b, open, _probes[0])
		var bw_ref := _black_and_spread(img_b, open, _probes[1])
		say("SUITE INFO %s: P open lum straight %.3f / bent %.3f; light share at P with blocker A: straight %.3f, bent %.3f; blocker B, 9x9 px around P: straight %d%% black (lit pixels avg %.2f), bent %d%% black (avg %.2f)" % [
				an, lum(open, _probes[0], 1), lum(open, _probes[1], 1), sa, sa_ref,
				roundi(bw.black * 100.0), bw.lit_mean, roundi(bw_ref.black * 100.0), bw_ref.lit_mean])
		check_lt(c, "(reference) bent tube, blocker A: P loses light", sa_ref, 0.97)
		check_lt(c, "straight tube, blocker A beside the near end: P loses light", sa, 0.97)
		check_lt(c, "(reference) bent tube, blocker B: no pixel around P goes black", bw_ref.black, 0.01)
		check_lt(c, "straight tube, blocker B on the gate axis: no pixel around P goes black (its near-end strata are clear)",
				bw.black, 0.01)
		var bug: bool = sa >= 0.995 or bw.black >= 0.05
		any_bug = any_bug or bug
		detail += "%s: blocker A share %.3f (bent ref %.3f); blocker B %d%% of pixels black, the rest %.2f (bent ref %d%% black, %.2f)%s" % [
				an, sa, sa_ref, roundi(bw.black * 100.0), bw.lit_mean, roundi(bw_ref.black * 100.0), bw_ref.lit_mean, "; "]

	repro("1 gate cone miss", any_bug, detail.trim_suffix("; "))
	_overlay.visible = true
	for row in ROWS.size():
		var x := 60.0
		for key in ["open", "a", "b"]:
			_inset(_shots[key], _probes[row], Vector2(x, ROWS[row] + 92.0),
					{"open": "no blocker", "a": "blocker A (beside the near end)", "b": "blocker B (on the gate axis)"}[key])
			x += 380.0
	# Leave blocker A in place on Cone Traced for eyeballing.
	for l in _lights:
		l.shadow_algorithm = ALGO.CONE_TRACED
	for row in ROWS.size():
		_blk_a.append(disc_occluder(a_pos + Vector2(0, ROWS[row] - ROWS[0]), geo.a_r, _holder))
	await frames(4)


## A 2x magnified crop of `img` around `p` (Cone Traced captures), with P marked.
func _inset(img: Image, p: Vector2, at: Vector2, title: String) -> void:
	var c := to_px(p, img)
	var region := Rect2i(int(c.x) - 150, int(c.y) - 50, 180, 75)
	var crop := img.get_region(region)
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(crop)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.centered = false
	spr.scale = Vector2(2, 2)
	spr.position = at
	spr.z_index = 40
	add_child(spr)
	overlay_circle(at + Vector2(150, 50) * 2.0, 7.0, Color(0.2, 1.0, 0.4), 1.5)
	overlay_line(PackedVector2Array([at, at + Vector2(360, 0), at + Vector2(360, 150), at + Vector2(0, 150), at]),
			Color(0.5, 0.5, 0.55), 1.0)
	label(title + "  (2x, P circled)", at + Vector2(0, -18), 12)


## Over the 9x9 pixels around `p`: the fraction whose light share is black (< 0.03),
## and the mean share of the rest.
func _black_and_spread(img: Image, open: Image, p: Vector2) -> Dictionary:
	var c := to_px(p, img)
	var black := 0
	var lit_sum := 0.0
	var lit_n := 0
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var q := Vector2i(int(c.x) + dx, int(c.y) + dy)
			var lo := img_lum(open, q) - AMBIENT
			if lo <= 0.005:
				continue
			var sh := (img_lum(img, q) - AMBIENT) / lo
			if sh < 0.03:
				black += 1
			else:
				lit_sum += sh
				lit_n += 1
	return {"black": float(black) / 81.0, "lit_mean": lit_sum / maxf(float(lit_n), 1.0)}


static func img_lum(img: Image, q: Vector2i) -> float:
	var col := img.get_pixelv(q)
	return 0.299 * col.r + 0.587 * col.g + 0.114 * col.b


func _clear_blockers() -> void:
	for o in _blk_a + _blk_b:
		o.queue_free()
	_blk_a.clear()
	_blk_b.clear()


## The shader's gate and strata for P under a straight tube centred on c, plus the two
## blocker placements and what each cuts.
func _geometry(p: Vector2, c: Vector2) -> Dictionary:
	var seg := Vector2(TUBE_LEN * 0.5, 0.0)
	var to_mid := c - p
	var maxd := to_mid.length()
	var dir := to_mid / maxd
	var w := (absf(seg.cross(dir)) + SOURCE_R) / maxd
	var half := atan(w)
	var strata: Array[Vector2] = []
	var inside: Array[bool] = []
	var outside := 0
	for i in SAMPLES:
		var u := ((float(i) + 0.5) / float(SAMPLES)) * 2.0 - 1.0
		var s := c + seg * u
		strata.append(s)
		var ins := absf(dir.angle_to(s - p)) <= half
		inside.append(ins)
		outside += 0 if ins else 1
	# A: beside the near end, well outside the gate.
	var a_r := 8.0
	var a_pos := p + Vector2.from_angle(deg_to_rad(237.0)) * 24.0
	# B: on the gate axis, wide enough that its interior spans the wedge there.
	var b_t := 80.0
	var b_r := w * b_t * 1.3
	var b_pos := p + dir * b_t
	var a_cut := 0
	var a_cut_in := 0
	var b_cut := 0
	var b_clear_out := 0
	for i in SAMPLES:
		var a_hit := _seg_disc(p, strata[i], a_pos, a_r)
		var b_hit := _seg_disc(p, strata[i], b_pos, b_r)
		a_cut += int(a_hit)
		a_cut_in += int(a_hit and inside[i])
		b_cut += int(b_hit)
		b_clear_out += int(not b_hit and not inside[i])
	return {"w": w, "outside": outside, "a_pos": a_pos, "a_r": a_r, "b_pos": b_pos, "b_r": b_r,
			"a_cut": a_cut, "a_cut_in": a_cut_in, "a_touches": _disc_in_wedge(p, dir, w, maxd, a_pos, a_r),
			"b_cut": b_cut, "b_clear_out": b_clear_out,
			"b_fills": (b_pos - p).length() * w <= b_r}


static func _seg_disc(a: Vector2, b: Vector2, c: Vector2, r: float) -> bool:
	var ab := b - a
	var t := clampf((c - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return (a + ab * t).distance_to(c) < r


## True if the disc reaches the gate cone (half-width w*t along dir from p, out to maxd).
static func _disc_in_wedge(p: Vector2, dir: Vector2, w: float, maxd: float, c: Vector2, r: float) -> bool:
	for k in 400:
		var t := maxd * float(k) / 399.0
		if (p + dir * t).distance_to(c) - r < w * t:
			return true
	return false


func _draw_analysis(p: Vector2, c: Vector2) -> void:
	var seg := Vector2(TUBE_LEN * 0.5, 0.0)
	var to_mid := c - p
	var maxd := to_mid.length()
	var dir := to_mid / maxd
	var w := (absf(seg.cross(dir)) + SOURCE_R) / maxd
	var half := atan(w)
	for i in SAMPLES:
		var u := ((float(i) + 0.5) / float(SAMPLES)) * 2.0 - 1.0
		var s := c + seg * u
		var ins := absf(dir.angle_to(s - p)) <= half
		overlay_line(PackedVector2Array([p + (s - p).normalized() * 6.0, s]),
				Color(0.6, 0.6, 0.6, 0.35) if ins else Color(1.0, 0.25, 0.2, 0.7), 1.0, _overlay)
	for sgn in [-1.0, 1.0]:
		overlay_line(PackedVector2Array([p + dir.rotated(half * sgn) * 6.0, p + dir.rotated(half * sgn) * maxd]),
				Color(1.0, 0.9, 0.1, 0.9), 1.5, _overlay)
	overlay_circle(p, 5.0, Color(0.2, 1.0, 0.4), 1.5, _overlay)
	label("P", p + Vector2(7, 2), 12, Color(0.2, 1.0, 0.4), _overlay)
	label("yellow: gate cone   red: stratum rays outside it   grey: inside", p + Vector2(-480, 60), 12, Color(0.85, 0.85, 0.9), _overlay)
