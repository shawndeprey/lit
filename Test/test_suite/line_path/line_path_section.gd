extends LitSuiteSection

## LitLineLight2D bent by a Path2D child against the rendered frame: a 2-point path
## renders as the straight light pixel for pixel, and off the node (packed as its
## segment) as a collinear 3-point path, its cookie still on the node; a V path lights its bisector brighter
## than one arm alone and dimmer than two separate lights, with no crease along it and
## no hot spot at the bend; a ring (closed 4-point curve) lights as a true circle
## (beam edge within a pixel of the circle, even around, no crease across the arc
## joints, the whole ring lighting its inside); ring and S-curve shadows (umbra behind
## a box outside the ring, inside lit, all three algorithms, shadow_length, the closed
## seam); the node API (closed, length greyed by the child, warnings), packing (flags
## bit 23, path row, arc count, shading chord count), the mirror, culling by the chain's
## bounds, the luminance mirror, camera zoom invariance, a non-uniform node scale (an
## ellipse) and normal-mapped receivers (no seam across a V's bisector, a ring's center
## lit from all around, a tilted face beside a 2-point path identical to the straight
## light).
##
## Numeric expectations come from _ref: the shader's line integral summed over 0.25 px
## elements of the path, albedo x ambient + energy x integral x diffuse_scale().

const AMBIENT := 0.1
const TOL := 0.03
const ALGO := LitShaderLibrary.ShadowAlgorithm
const KAPPA := 0.5522847498

# A: geometry. A ring of radius 120 centered on CA.
const CA := Vector2(350, 305)
const RA := 120.0
# B: shadows. A ring of radius 100 centered on CB, a box below it and one left of it.
const CB := Vector2(1040, 250)
const RB := 100.0
const P_UM := Vector2(1040, 440)     # umbra below the lower box
const P_LEFT := Vector2(860, 250)    # umbra left of the left box
const P_REF := Vector2(880, 440)     # lit, beside the lower box's shadow
const P_PEN := Vector2(1112, 440)    # the lower box's shadow edge
const P_SEAM := Vector2(1111, 179)   # on the ring at 315 degrees: the closing arc
# C: API and the luminance exhibit.
const CC := Vector2(350, 800)
const RC := 80.0
# D: an S-curve from CD, a box above its first stretch and one below its last.
const CD := Vector2(800, 700)
const P_S1 := Vector2(870, 610)      # umbra above the first box
const P_S2 := Vector2(1180, 1000)    # umbra below the second box
const P_S_REF := Vector2(1050, 700)  # lit, inside the S
const CE := Vector2(1250, 650)       # the ellipse (a ring under scale 2, 1)
const V_APEX := Vector2(1000, 1000)  # a 90 degree V opening up-left, arms of 240
const P_BIS := Vector2(880, 880)     # on the V's bisector, 120 px from each arm
const CR := Vector2(780, 700)        # the ring for the tilted-face checks

var _props: Node2D
var _floor_a: LitSprite2D
var _ring_b: LitLineLight2D
var _cam: Camera2D


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_props = group("Props")
	label("curved line light: a 2-point path is the straight light; a ring is a true circle (edge, evenness, joints)",
			Vector2(24, 74))
	label("ring shadows: umbra outside, lit inside, three algorithms, shadow_length, the closed seam", Vector2(704, 74))
	label("API (closed, length greyed by the Path2D child, warnings), packing, culling, luminance", Vector2(24, 544))
	label("S-curve shadows follow the curve, zoom invariance, a ring under a non-uniform scale", Vector2(704, 544))
	_floor_a = floor_receiver(Rect2(20, 90, 660, 430))
	floor_receiver(Rect2(700, 90, 680, 430))
	floor_receiver(Rect2(20, 560, 660, 480))
	floor_receiver(Rect2(700, 560, 680, 480))
	await frames(2)
	await _straight_equivalence()
	await _additive()
	await _ring_geometry()
	await _ring_shadows()
	await _api()
	await _luminance()
	await _s_curve()
	await _camera()
	await _scale()
	await _normals()


func line_light(pos: Vector2, p_range: float, energy: float, height: float,
		parent: Node = null) -> LitLineLight2D:
	var l := LitLineLight2D.new()
	l.position = pos
	l.range = p_range
	l.energy = energy
	l.height = height
	(parent if parent != null else self).add_child(l)
	return l


## A Path2D child carrying `points` ([position, in, out] triples).
func path_child(light: LitLineLight2D, points: Array) -> Path2D:
	var p := Path2D.new()
	var c := Curve2D.new()
	for pt in points:
		c.add_point(pt[0], pt[1], pt[2])
	p.curve = c
	light.add_child(p)
	return p


## A 4-point Bezier circle of radius r around the light, closed by the light.
func ring_child(light: LitLineLight2D, r: float) -> Path2D:
	var k := KAPPA * r
	light.closed = true
	return path_child(light, [
		[Vector2(r, 0), Vector2(0, -k), Vector2(0, k)],
		[Vector2(0, r), Vector2(k, 0), Vector2(-k, 0)],
		[Vector2(-r, 0), Vector2(0, k), Vector2(0, -k)],
		[Vector2(0, -r), Vector2(-k, 0), Vector2(k, 0)],
	])


## Diffuse at `p` on a face with normal `n` (the flat floor by default) under a tube
## along the polyline `pts` (world px, a loop when `closed`), as the shader shades it
## (lit_shade): the point light's falloff from the tube's surface times the tube's mean
## cosine, max(n.u, 0) / |u|^2 summed over 0.25 px elements of every piece (an open
## tube's two ends slid toward `p` by the half width past them, every piece shrunk
## across its width elsewhere) over the angle an endless straight tube would subtend
## at the nearest point, lifted to the nearest point's cosine where it falls short under
## the body and out to a half width past its surface. The beam is `p`'s coverage by the tube's body
## and the glow scales the halo.
func _ref(p: Vector2, pts: PackedVector2Array, closed: bool, p_range: float, energy: float, falloff: float,
		height: float, half_w := 0.0, glow := 1.0, n := Vector3(0, 0, 1)) -> float:
	var m := pts.size() - 1
	var d_body := INF
	var q := p
	var total := 0.0
	for k in m:
		var sd := _seg_dist(p, pts[k], pts[k + 1])
		if sd < d_body:
			d_body = sd
			q = _seg_point(p, pts[k], pts[k + 1])
		total += pts[k].distance_to(pts[k + 1])
	var reach := p_range - half_w
	var s := maxf(d_body - half_w, 0.0)
	if s > reach:
		return AMBIENT
	var beam := clampf(minf(d_body + 0.5, half_w) - maxf(d_body - 0.5, -half_w), 0.0, 1.0)
	var acc := 0.0
	for k in m:
		var a := pts[k]
		var ab := pts[k + 1] - a
		var len := ab.length()
		if len < 1e-6:
			continue
		var t := ab / len
		var lf := (p - a).dot(t)
		var v := a + t * lf - p
		if (lf <= 0.0 and k == 0 and not closed) or (lf >= len and k == m - 1 and not closed):
			var pq := p - (a if lf <= 0.0 else pts[k + 1])
			var shift := pq * minf(half_w / maxf(pq.length(), 1e-6), 1.0)
			var along := shift.dot(t)
			lf -= along
			v += shift - t * along
		else:
			var dperp := v.length()
			v *= maxf(dperp - half_w, 0.0) / maxf(dperp, 1e-6)
		var cnt := maxi(int(ceil(len / 0.25)), 1)
		var sum := 0.0
		for j in cnt:
			var l := -lf + (float(j) + 0.5) * len / float(cnt)
			var u := Vector3(v.x + t.x * l, v.y + t.y * l, height)
			sum += maxf(n.dot(u), 0.0) / u.length_squared()
		acc += sum * len / float(cnt)
	var slant := sqrt(s * s + height * height)
	var cosine := acc / (2.0 * atan2(total, 2.0 * slant))
	if half_w > 0.0:
		var tl := (q - p) * (s / maxf(d_body, 1e-6))
		var near := maxf(n.dot(Vector3(tl.x, tl.y, height)) / slant, 0.0)
		cosine += maxf(near - cosine, 0.0) * (1.0 - smoothstep(0.0, half_w, s))
	var c := energy * pow(1.0 - s / reach, falloff) * cosine * lerpf(glow, 1.0, beam)
	return minf(AMBIENT + (c * diffuse_scale() if c >= 0.004 else 0.0), 1.0)


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	return _seg_point(p, a, b).distance_to(p)


static func _seg_point(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-12:
		return a
	return a + ab * clampf((p - a).dot(ab) / l2, 0.0, 1.0)


## A ring of radius `r` around `c` from `from_deg` to `to_deg` as a polygon far finer
## than the light's chords; `sx` stretches it along x.
static func _ring_pts(c: Vector2, r: float, from_deg := 0.0, to_deg := 360.0, sx := 1.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	var steps := int(round((to_deg - from_deg) * 2.0))
	for k in steps + 1:
		var a := deg_to_rad(from_deg + (to_deg - from_deg) * float(k) / float(steps))
		out.append(c + Vector2(cos(a) * r * sx, sin(a) * r))
	return out


# --- A: a 2-point path is the straight light -----------------------------------------------------

func _straight_equivalence() -> void:
	var c := "path_straight"
	var l := line_light(CA, 150.0, 0.5, 100.0)
	l.length = 200.0
	l.width = 6.0
	l.glow = 0.5
	var face := tilted_box(CA + Vector2(0, 60), 40, 0.0, -0.6)
	await frames(2)
	var straight := await capture()
	var p := path_child(l, [[Vector2(-100, 0), Vector2.ZERO, Vector2.ZERO], [Vector2(100, 0), Vector2.ZERO, Vector2.ZERO]])
	await frames(2)
	check_true(c, "a Path2D child with 2 points makes the light curved", l.is_curved())
	check(c, "a straight 2-point path fits as one arc", 1, l.path_chain().arc_count())
	var img := await capture()
	var area := Rect2(40, 110, 620, 390)
	check_lt(c, "the 2-point path renders as the straight light (mean abs diff)", image_diff(straight, img, area, 2), 0.002)
	for pt in [CA, CA + Vector2(80, 0), CA + Vector2(100, 0), CA + Vector2(0, 60), CA + Vector2(170, 40), CA + Vector2(-120, -30)]:
		check_approx(c, "probe %s matches" % pt, lum(straight, pt), lum(img, pt), 0.005)
	check_gt(c, "the face tilted across the tube is lit", lum(straight, CA + Vector2(0, 60)), AMBIENT, 0.05)
	check_approx(c, "and reads as under the straight light", lum(straight, CA + Vector2(0, 60)), lum(img, CA + Vector2(0, 60)), 0.01)
	p.queue_free()
	await frames(2)
	check_true(c, "removing the Path2D child returns the light to its segment", not l.is_curved())
	img = await capture()
	check_lt(c, "and the render returns to the straight capture", image_diff(straight, img, area, 2), 0.002)
	# A one-arc straight path packs as its segment; a collinear 3-point path stays curved.
	var reg = get_node("/root/LitManager")._registry
	var packer = reg._light_packer
	var two := [[Vector2(-40, 0), Vector2.ZERO, Vector2.ZERO], [Vector2(160, 0), Vector2.ZERO, Vector2.ZERO]]
	var three := [two[0], [Vector2(60, 0), Vector2.ZERO, Vector2.ZERO], two[1]]
	var half_tex := tex_fn(64, 64, func(x: int, _y: int) -> Color:
		return Color.WHITE if x < 32 else Color.TRANSPARENT)
	for cfg in [[null, Vector2.ZERO], [half_tex, Vector2.ZERO], [half_tex, Vector2(40, 10)]]:
		l.texture = cfg[0]
		l.texture_offset = cfg[1]
		var tag: String = "no cookie" if cfg[0] == null else "cookie, texture_offset %s" % cfg[1]
		p = path_child(l, three)
		await frames(3)
		check(c, "%s: the collinear 3-point path fits as two arcs" % tag, 2, l.path_chain().arc_count())
		var ref := await capture()
		p.free()
		p = path_child(l, two)
		await frames(3)
		img = await capture()
		check_lt(c, "%s: the off-node 2-point path renders as the 3-point path (mean abs diff)" % tag,
				image_diff(ref, img, area, 2), 0.002)
		if cfg[0] != null:
			check_approx(c, "%s: the cookie stays on the node" % tag, lum(ref, CA + Vector2(-15, 0)), lum(img, CA + Vector2(-15, 0)), 0.01)
		var row: int = reg._ctx.visible.find(l)
		check_true(c, "%s: packed this frame" % tag, row >= 0)
		if row >= 0 and cfg[0] == null:
			var o: int = row * packer._tpl * 4
			var cx: Transform2D = reg._ctx.canvas_xform
			var mid: Vector2 = (cx * (CA + Vector2(60, 0))) / reg._ctx.vp_size
			check(c, "packed straight: flags bit 23 clear", 0, (int(round(packer._pack_buf[o + 1])) >> 23) & 1)
			check_approx(c, "texel 4.x = the segment's half vector", cx.basis_xform(Vector2(100, 0)).x, packer._pack_buf[o + 16], 0.01)
			check_approx(c, "texel 1.x = the segment's midpoint", mid.x, packer._pack_buf[o + 4], 1e-5)
		p.free()
	l.texture = null
	l.texture_offset = Vector2.ZERO
	for rot in [0.37, 1.1, 2.5]:
		l.rotation = rot
		p = path_child(l, two)
		await frames(1)
		check_true(c, "rotated %.2f: the 2-point path still fits straight" % rot, l.path_straight())
		p.free()
	l.rotation = 0.0
	l.queue_free()
	face.queue_free()
	await frames(1)


# --- A: a V path adds up on its bisector ---------------------------------------------------------------

## A right-angle V with 200 px arms under one light against two straight tubes on its
## arms: the bisector sees both arms, so it is brighter than one arm alone lights it,
## yet the bend is one tube, not two lights piled up, so it stays dimmer than the two
## straight lights and has no hot spot at the apex; there is no crease along it.
func _additive() -> void:
	var c := "path_additive"
	var apex := Vector2(450, 420)
	var pts := PackedVector2Array([Vector2(250, 420), apex, Vector2(450, 220)])
	var bis := Vector2(-1, -1).normalized()
	var s1 := line_light(Vector2(350, 420), 200.0, 0.8, 30.0)
	s1.length = 200.0
	var s2 := line_light(Vector2(450, 320), 200.0, 0.8, 30.0)
	s2.length = 200.0
	s2.rotation = PI / 2.0
	await frames(2)
	var two := await capture()
	s1.queue_free()
	s2.queue_free()
	var v := line_light(apex, 200.0, 0.8, 30.0)
	path_child(v, [[Vector2(-200, 0), Vector2.ZERO, Vector2.ZERO], [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO],
			[Vector2(0, -200), Vector2.ZERO, Vector2.ZERO]])
	await frames(2)
	var img := await capture()
	check_approx(c, "at the apex the bend reads as the model (one tube, no hot spot)", _ref(apex, pts, false, 200.0, 0.8, 1.0, 30.0),
			lum(img, apex), TOL)
	check_lt(c, "and dimmer than the two straight lights piled up there", lum(img, apex), lum(two, apex), 0.03)
	for t in [40.0, 80.0, 120.0, 160.0]:
		var p: Vector2 = apex + bis * t
		check_approx(c, "on the bisector %d px from the apex: both arms add up (the model)" % int(t),
				_ref(p, pts, false, 200.0, 0.8, 1.0, 30.0), lum(img, p), TOL)
		check_gt(c, "and %d px out it is brighter than one arm alone lights it" % int(t), lum(img, p),
				_ref(p, pts.slice(0, 2), false, 200.0, 0.8, 1.0, 30.0), 0.02)
		check_lt(c, "and %d px out dimmer than the two straight lights there" % int(t), lum(img, p), lum(two, p), 0.02)
	var base := apex + bis * 80.0
	check_gt(c, "80 px from the apex the bisector is far brighter than one arm alone lights it", lum(img, base),
			_ref(base, pts.slice(0, 2), false, 200.0, 0.8, 1.0, 30.0), 0.1)
	var across := Vector2(1, -1).normalized()
	var curve := lum(img, base + across * 12.0, 1) + lum(img, base - across * 12.0, 1) - 2.0 * lum(img, base, 1)
	var model := _ref(base + across * 12.0, pts, false, 200.0, 0.8, 1.0, 30.0) + _ref(base - across * 12.0, pts, false, 200.0, 0.8, 1.0, 30.0) \
			- 2.0 * _ref(base, pts, false, 200.0, 0.8, 1.0, 30.0)
	check_approx(c, "across the bisector the render bends as the model's smooth valley does, no crease (second difference, 12 px step)",
			model, curve, 0.01)
	v.queue_free()
	await frames(1)


# --- A: ring geometry --------------------------------------------------------------------------------

func _ring_geometry() -> void:
	var c := "path_ring"
	var l := line_light(CA, 150.0, 0.5, 100.0)
	l.width = 20.0
	l.glow = 0.5
	ring_child(l, RA)
	await frames(2)
	check_true(c, "the ring fits in at most 8 arcs", l.path_chain().arc_count() <= 8)
	var img := await capture()
	var ring := _ring_pts(CA, RA)
	var on := _ref(CA + Vector2(RA, 0), ring, true, 150.0, 0.5, 1.0, 100.0, 10.0, 0.5)
	var out60 := _ref(CA + Vector2(RA + 60.0, 0), ring, true, 150.0, 0.5, 1.0, 100.0, 10.0, 0.5)
	for k in 8:
		var dir := Vector2.from_angle(k * PI / 4.0)
		check_approx(c, "on the beam at %d deg" % (k * 45), on, lum(img, CA + dir * RA, 2), TOL)
	var ring_vals: Array[float] = []
	for k in 16:
		var dir := Vector2.from_angle(k * PI / 8.0)
		ring_vals.append(lum(img, CA + dir * (RA + 60.0)))
	check_approx(c, "60 px outside the ring reads the ring's integral 50 px past its surface", out60, ring_vals[0], TOL)
	check_lt(c, "the glow 60 px outside is even around the ring (max - min)", ring_vals.max() - ring_vals.min(), 0.01)
	check_approx(c, "60 px inside the ring: the whole ring lights it", _ref(CA + Vector2(60, 0), ring, true, 150.0, 0.5, 1.0, 100.0, 10.0, 0.5),
			lum(img, CA + Vector2(60, 0)), TOL)
	check_gt(c, "and it reads brighter than 60 px outside (the far side adds up)", lum(img, CA + Vector2(60, 0)), ring_vals[0], 0.05)
	check_approx(c, "the ring's center: every part of the ring, 120 px away", _ref(CA, ring, true, 150.0, 0.5, 1.0, 100.0, 10.0, 0.5), lum(img, CA), TOL)
	check_approx(c, "290 px out (beyond range): ambient", AMBIENT, lum(img, CA + Vector2(290, 0)), TOL)
	# The beam edge (half width 10) sits on the circle of radius 130 along every ray.
	var worst := 0.0
	for k in 8:
		var dir := Vector2.from_angle(k * PI / 4.0 + PI / 8.0)
		var edge := -1.0
		for r in range(124, 138):
			if lum(img, CA + dir * float(r), 0) < on - 0.1:
				edge = float(r)
				break
		worst = maxf(worst, absf(edge - 130.5))
	check_lt(c, "the beam edge lies within 1.5 px of the true circle on 8 rays", worst, 1.5)
	# No crease across the arc joints: the glow along a circle 40 px out is smooth
	# through the closing arc (315 deg) and the first point (0 deg).
	var step := 0.0
	for start in [300.0, 350.0]:
		var prev := -1.0
		for i in 16:
			var dir := Vector2.from_angle(deg_to_rad(start + i * 2.0))
			var v := lum(img, CA + dir * (RA + 40.0), 1)
			if prev >= 0.0:
				step = maxf(step, absf(v - prev))
			prev = v
		check_lt(c, "no crease in the glow across the joint near %d deg" % int(start + 15.0), step, 0.01)
	l.name = "RingA"


# --- B: ring shadows -------------------------------------------------------------------------------

func _ring_shadows() -> void:
	var c := "path_shadows"
	_ring_b = line_light(CB, 250.0, 0.8, 300.0)
	_ring_b.falloff = 0.3
	_ring_b.source_radius = 2.0
	_ring_b.shadow_samples = 16
	ring_child(_ring_b, RB)
	var below := occluder(Vector2(1040, 400), Vector2(120, 20), _props)
	var left := occluder(Vector2(900, 250), Vector2(20, 120), _props)
	await frames(3)
	var img := await capture()
	check_gt(c, "shadows off: below the box is lit", lum(img, P_UM), AMBIENT, 0.25)
	_ring_b.shadow_enabled = true
	await frames(2)
	img = await capture()
	check_approx(c, "Cone Traced: umbra below the box outside the ring", AMBIENT, lum(img, P_UM), 0.06)
	check_approx(c, "Cone Traced: umbra left of the left box", AMBIENT, lum(img, P_LEFT), 0.06)
	check_gt(c, "beside the shadow: lit", lum(img, P_REF), AMBIENT, 0.2)
	var cone_pen := lum(img, P_PEN)
	# The whole ring lights its inside: at energy 0.8 the floor saturates there, so the
	# interior reads against the model at energy 0.4.
	var ringb := _ring_pts(CB, RB)
	_ring_b.energy = 0.4
	await frames(2)
	img = await capture()
	check_approx(c, "inside the ring: the center reads the ring's integral, unshadowed", _ref(CB, ringb, true, 250.0, 0.4, 0.3, 300.0),
			lum(img, CB), TOL)
	check_approx(c, "inside the ring: 60 px toward the left box, unshadowed", _ref(CB + Vector2(-60, 0), ringb, true, 250.0, 0.4, 0.3, 300.0),
			lum(img, CB + Vector2(-60, 0)), TOL)
	_ring_b.energy = 0.8
	await frames(2)
	_ring_b.shadow_algorithm = ALGO.STOCHASTIC
	await frames(2)
	img = await capture()
	check_approx(c, "Stochastic: umbra below the box", AMBIENT, lum(img, P_UM), 0.06)
	check_approx(c, "Stochastic matches Cone Traced at the shadow edge", cone_pen, lum(img, P_PEN), 0.04)
	_ring_b.shadow_algorithm = ALGO.RAYMARCHED
	await frames(2)
	img = await capture()
	check_approx(c, "Raymarched: umbra below the box (its march goes to the nearest point)", AMBIENT, lum(img, P_UM), 0.06)
	check_gt(c, "Raymarched: inside the ring lit", lum(img, CB), AMBIENT, 0.3)
	for algo in [ALGO.CONE_TRACED, ALGO.RAYMARCHED]:
		var an: String = ["Raymarched", "Cone Traced", "Stochastic"][algo]
		_ring_b.shadow_algorithm = algo
		_ring_b.shadow_length = 0.08
		await frames(2)
		img = await capture()
		check_gt(c, "%s shadow_length 0.08: the box is beyond the capped march, lit" % an, lum(img, P_UM), AMBIENT, 0.25)
		_ring_b.shadow_length = 1.0
		await frames(2)
		img = await capture()
		check_approx(c, "%s shadow_length 1: umbra back" % an, AMBIENT, lum(img, P_UM), 0.06)
	below.visible = false
	left.visible = false
	await frames(2)
	img = await capture()
	check_gt(c, "hidden boxes cast nothing", lum(img, P_UM), AMBIENT, 0.25)
	var on := lum(img, P_SEAM, 1)
	check_approx(c, "closed: the seam at 315 deg is on the ring", _ref(P_SEAM, ringb, true, 250.0, 0.8, 0.3, 300.0), on, TOL)
	_ring_b.closed = false
	await frames(2)
	img = await capture()
	var open := _ring_pts(CB, RB, 0.0, 270.0)
	check_approx(c, "open: the seam at 315 deg sits in the gap, lit by the open ring's taper", _ref(P_SEAM, open, false, 250.0, 0.8, 0.3, 300.0),
			lum(img, P_SEAM, 1), TOL)
	check_lt(c, "open: the gap is dimmer than the closed ring there", lum(img, P_SEAM, 1), on, 0.02)
	check_approx(c, "open: the first point stays on the ring", _ref(CB + Vector2(RB, 0), open, false, 250.0, 0.8, 0.3, 300.0),
			lum(img, CB + Vector2(RB, 0), 1), TOL)
	_ring_b.closed = true
	below.visible = true
	left.visible = true
	await frames(2)


# --- C: API, packing, mirror, culling ----------------------------------------------------------------

func _api() -> void:
	var c := "path_api"
	var reg = get_node("/root/LitManager")._registry
	var l := line_light(CC, 100.0, 0.5, 100.0)
	check(c, "fresh closed false", false, l.closed)
	check_true(c, "fresh light is not curved", not l.is_curved())
	check_true(c, "length is editable without a Path2D child", not _read_only(l, "length"))
	check_true(c, "closed is greyed without a Path2D child", _read_only(l, "closed"))
	check(c, "no configuration warning without a child", 0, l._get_configuration_warnings().size())
	var one := path_child(l, [[Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]])
	check_true(c, "a 1-point path leaves the light straight", not l.is_curved())
	check(c, "and carries a configuration warning", 1, l._get_configuration_warnings().size())
	check_true(c, "length greys out as soon as a Path2D child exists", _read_only(l, "length"))
	check_true(c, "closed becomes editable", not _read_only(l, "closed"))
	one.free()
	await frames(1)
	check_true(c, "removing the child restores length", not _read_only(l, "length"))
	var zig: Array = []
	for i in 40:
		zig.append([Vector2(i * 30.0, (i % 2) * 40.0), Vector2(-10, 10), Vector2(10, -10)])
	var big := path_child(l, zig)
	check_true(c, "a 40-point zigzag is curved", l.is_curved())
	check(c, "and truncates to 32 arcs", 32, l.path_chain().arc_count())
	check_true(c, "with the truncation warning", l._get_configuration_warnings().size() == 1
			and "32" in l._get_configuration_warnings()[0])
	big.free()
	ring_child(l, RC)
	await frames(2)
	check(c, "the ring carries no warning", 0, l._get_configuration_warnings().size())
	var arcs: int = l.path_chain().arc_count()
	var cache = reg._light_cache
	var i: int = cache._index.get(l.get_instance_id(), -1)
	check_true(c, "the light cache mirrors the light", i >= 0)
	if i >= 0:
		check_true(c, "the mirror flags it curved", cache._flags[i] & cache.F_PATH != 0)
		check_approx(c, "the mirror holds the chain's light-local bounds (min x)", -RC, cache._prects[i * 4], 0.5)
		check_approx(c, "the mirror holds the chain's light-local bounds (max y)", RC, cache._prects[i * 4 + 3], 0.5)
	var row: int = reg._ctx.visible.find(l)
	check_true(c, "packed this frame", row >= 0)
	if row >= 0:
		var packer = reg._light_packer
		var o: int = row * packer._tpl * 4
		var flags := int(round(packer._pack_buf[o + 1]))
		check(c, "packed type bits = 3 (line)", 3, (flags >> 20) & 3)
		check(c, "flags bit 23 marks the curve", 1, (flags >> 23) & 1)
		check(c, "texel 4.y = the arc count", arcs, int(round(packer._pack_buf[o + 17])))
		var prow := int(round(packer._pack_buf[o + 16]))
		check_true(c, "texel 4.x = a path row under the rows packed", prow >= 0 and prow < packer._path_rows)
		check_true(c, "path rows this frame = the curved lights on screen (3)", packer._path_rows == 3)
		var pb: int = prow * packer.PATH_W * 4
		check_approx(c, "path row texel 0: the bounding circle sits on the node (x)", CC.x, packer._path_buf[pb], 0.5)
		check_approx(c, "path row texel 0: its radius is the chain box's half diagonal", RC * sqrt(2.0), packer._path_buf[pb + 2], 0.5)
		check_approx(c, "path row texel 1: the first arc point is the curve's first point (x)", CC.x + RC, packer._path_buf[pb + 4], 0.5)
		var chord_len := Vector2(packer._path_buf[pb + 4 * packer.PATH_SHADOW + 2], packer._path_buf[pb + 4 * packer.PATH_SHADOW + 3]).length() * 2.0
		check_approx(c, "the first shadow chord spans 1/8 of the ring (8 samples)", 2.0 * RC * sin(PI / 8.0), chord_len, 1.0)
		check(c, "path row texel 0.w: the ring's arcs share all 32 shading chords", 32, int(round(packer._path_buf[pb + 3])))
		l.rotation = PI / 2.0
		await frames(1)
		check_approx(c, "rotated 90: the first arc point turns to +y", CC.y + RC, packer._path_buf[pb + 5], 0.5)
		check(c, "rotation keeps the arc count (no refit)", arcs, int(round(packer._pack_buf[o + 17])))
		l.rotation = 0.0
		await frames(1)
	l.name = "RingC"

	# Culling: a ring whose node is off screen but whose chain reaches the view packs;
	# moved out of reach it is culled.
	var far := line_light(Vector2(-250, 800), 40.0, 0.6, 100.0)
	ring_child(far, 300.0)
	await frames(2)
	var img := await capture()
	check_true(c, "off-screen node, on-screen chain: not culled", reg._ctx.visible.has(far))
	check_gt(c, "the on-screen part of the ring lights the floor", lum(img, Vector2(50, 800)), AMBIENT, 0.3)
	far.position = Vector2(-600, 800)
	await frames(2)
	img = await capture()
	check_true(c, "chain 260 px off screen (range 40): culled", not reg._ctx.visible.has(far))
	check_approx(c, "culled: the floor is ambient", AMBIENT, lum(img, Vector2(50, 800)), TOL)
	far.queue_free()
	await frames(1)


func _read_only(obj: Object, prop: String) -> bool:
	for p in obj.get_property_list():
		if p.name == prop:
			return p.usage & PROPERTY_USAGE_READ_ONLY != 0
	return false


# --- C: luminance mirror -------------------------------------------------------------------------

func _luminance() -> void:
	var c := "path_luminance"
	var mgr := get_node("/root/LitManager")
	var l := get_node("RingC") as LitLineLight2D
	var img := await capture()
	var pts := {"on the ring": CC + Vector2(RC, 0), "40 px inside": CC + Vector2(0, RC - 40.0),
			"50 px outside": CC + Vector2(-RC - 50.0, 0), "on the closing arc": CC + Vector2.from_angle(deg_to_rad(315.0)) * RC,
			"at the center": CC, "beyond range": CC + Vector2(RC + 120.0, 0)}
	for desc in pts:
		var p: Vector2 = pts[desc]
		check_approx(c, "sample_luminance %s matches the render" % desc, lum(img, p), mgr.sample_luminance(p), TOL)
	l.shadow_enabled = true
	l.shadow_algorithm = ALGO.RAYMARCHED
	l.shadow_hardness = 1.0
	var post := occluder(CC + Vector2(0, RC + 30.0), Vector2(60, 10), _props)
	await frames(3)
	img = await capture()
	var behind := CC + Vector2(0, RC + 55.0)
	check_approx(c, "behind the post: rendered umbra", AMBIENT, lum(img, behind), 0.06)
	check_approx(c, "behind the post: sampled umbra", lum(img, behind), mgr.sample_luminance(behind), 0.06)
	var clear := CC + Vector2(60, RC + 55.0)
	check_gt(c, "beside the post: rendered mostly lit (the far chords see the post)", lum(img, clear), AMBIENT, 0.05)
	check_approx(c, "beside the post: sampled lit", lum(img, clear), mgr.sample_luminance(clear), TOL)
	post.queue_free()
	l.shadow_enabled = false
	await frames(1)


# --- D: S-curve shadows ---------------------------------------------------------------------------

func _s_curve() -> void:
	var c := "path_s_curve"
	var l := line_light(CD, 200.0, 0.8, 300.0)
	l.name = "SCurve"
	l.falloff = 0.3
	l.source_radius = 2.0
	l.shadow_samples = 16
	path_child(l, [
		[Vector2(0, 0), Vector2.ZERO, Vector2(150, 0)],
		[Vector2(200, 100), Vector2(-60, -60), Vector2(60, 60)],
		[Vector2(400, 200), Vector2(-150, 0), Vector2.ZERO],
	])
	occluder(Vector2(870, 660), Vector2(240, 16), _props).name = "BoxS1"
	occluder(Vector2(1160, 950), Vector2(240, 16), _props).name = "BoxS2"
	await frames(3)
	var img := await capture()
	check_gt(c, "the curve lights its start", lum(img, CD + Vector2(20, 0)), AMBIENT, 0.3)
	check_gt(c, "the curve lights its middle", lum(img, CD + Vector2(200, 100)), AMBIENT, 0.3)
	check_gt(c, "the curve lights its end", lum(img, CD + Vector2(380, 200)), AMBIENT, 0.3)
	check_gt(c, "shadows off: above the first box is lit", lum(img, P_S1), AMBIENT, 0.2)
	l.shadow_enabled = true
	await frames(2)
	img = await capture()
	check_approx(c, "Cone Traced: umbra above the first stretch's box", AMBIENT, lum(img, P_S1), 0.06)
	check_approx(c, "Cone Traced: umbra below the last stretch's box", AMBIENT, lum(img, P_S2), 0.06)
	check_gt(c, "inside the S, past both boxes: lit", lum(img, P_S_REF), AMBIENT, 0.2)
	l.shadow_algorithm = ALGO.STOCHASTIC
	await frames(2)
	img = await capture()
	check_approx(c, "Stochastic: umbra above the first box", AMBIENT, lum(img, P_S1), 0.06)
	l.shadow_algorithm = ALGO.RAYMARCHED
	await frames(2)
	img = await capture()
	check_approx(c, "Raymarched: umbra above the first box", AMBIENT, lum(img, P_S1), 0.06)
	l.shadow_algorithm = ALGO.CONE_TRACED
	await frames(2)


# --- D: camera zoom invariance ----------------------------------------------------------------------

func _camera() -> void:
	var c := "path_camera"
	var img := await capture()
	var base := {"umbra above the first box": lum(img, P_S1), "umbra below the second box": lum(img, P_S2),
			"lit inside the S": lum(img, P_S_REF), "on the curve": lum(img, CD + Vector2(200, 100))}
	_cam = Camera2D.new()
	_cam.position = Vector2(1000, 760)
	add_child(_cam)
	_cam.make_current()
	_cam.zoom = Vector2(2, 2)
	await frames(3)
	img = await capture()
	for k in base:
		check_approx(c, "zoom 2: %s reads as without a camera" % k, base[k], lum(img, _probe_pt(k)), TOL)
	_cam.zoom = Vector2(0.5, 0.5)
	await frames(3)
	img = await capture()
	for k in base:
		check_approx(c, "zoom 0.5: %s reads as without a camera" % k, base[k], lum(img, _probe_pt(k)), TOL)
	_cam.enabled = false
	await frames(2)
	get_viewport().canvas_transform = Transform2D()
	await frames(2)
	img = await capture()
	check_approx(c, "camera off: the umbra reads as before", base["umbra above the first box"], lum(img, P_S1), TOL)


func _probe_pt(k: String) -> Vector2:
	match k:
		"umbra above the first box": return P_S1
		"umbra below the second box": return P_S2
		"on the curve": return CD + Vector2(200, 100)
	return P_S_REF


# --- D: a ring under a non-uniform node scale is an ellipse ----------------------------------------------

func _scale() -> void:
	var c := "path_scale"
	get_node("SCurve").queue_free()
	for n in ["BoxS1", "BoxS2"]:
		_props.get_node(n).queue_free()
	await frames(1)
	var l := line_light(CE, 60.0, 0.5, 100.0)
	l.width = 4.0
	l.glow = 0.5
	ring_child(l, 50.0)
	l.scale = Vector2(2.0, 1.0)
	await frames(2)
	var img := await capture()
	var ellipse := _ring_pts(CE, 50.0, 0.0, 360.0, 2.0)
	for pt in [Vector2(100, 0), Vector2(0, 50), Vector2(70.7, 35.4)]:
		check_approx(c, "scale (2, 1): the beam passes %s from the node" % pt, _ref(CE + pt, ellipse, true, 120.0, 0.5, 1.0, 100.0, 4.0, 0.5),
				lum(img, CE + pt, 1), TOL)
	check_lt(c, "scale (2, 1): the circle's 45 deg point is off the beam", lum(img, CE + Vector2(35.4, 35.4), 1), lum(img, CE + Vector2(70.7, 35.4), 1), 0.05)
	l.scale = Vector2.ONE
	await frames(2)
	img = await capture()
	check_approx(c, "scale 1: the circle's 45 deg point is back on the beam",
			_ref(CE + Vector2(35.4, 35.4), _ring_pts(CE, 50.0), true, 60.0, 0.5, 1.0, 100.0, 2.0, 0.5), lum(img, CE + Vector2(35.4, 35.4), 1), TOL)


# --- D: normal-mapped receivers --------------------------------------------------------------------

## A white receiver box whose normal map tilts every texel toward (nx, ny), specular off.
## A child of the section, so it draws over the floors (Props draws under them).
func tilted_box(pos: Vector2, size: int, nx: float, ny := 0.0) -> LitSprite2D:
	var s := box_receiver(pos, Vector2(size, size), Color.WHITE, null, tex_normal(size, nx, ny))
	s.specular_strength = 0.0
	return s


## The light's direction on a tilted face is continuous across the path's medial axis,
## where the nearest point jumps: the bisector of a V and the center of a ring.
func _normals() -> void:
	var c := "path_normals"
	# The faces respond to their normal maps: a point light 80 px to the right of a
	# right-facing face reads N.L of the tilt.
	var pl := point_light(Vector2(1100, 950), 200.0, 0.6, Color.WHITE, 60.0)
	pl.falloff = 0.0
	var probe := tilted_box(Vector2(1020, 950), 40, 0.6)
	await frames(2)
	var n := Vector3(0.6, 0.0, 1.0).normalized()
	check_approx(c, "a right-facing face, point light 80 px right: N.L of the tilt",
			AMBIENT + maxf(n.dot(Vector3(80, 0, 60).normalized()), 0.0) * 0.6 * diffuse_scale(), lum(await capture(), Vector2(1020, 950), 1), 0.04)
	pl.queue_free()
	probe.queue_free()
	await frames(1)
	var v := line_light(V_APEX, 300.0, 1.0, 60.0)
	path_child(v, [[Vector2(-240, 0), Vector2.ZERO, Vector2.ZERO], [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO],
			[Vector2(0, -240), Vector2.ZERO, Vector2.ZERO]])
	var face := tilted_box(P_BIS, 100, 0.6)
	await frames(2)
	var img := await capture()
	var across := Vector2(1, -1).normalized()
	var prev := -1.0
	var step := 0.0
	var lo := 1.0
	for i in 41:
		var val := lum(img, P_BIS + across * float(i - 20) * 2.0, 1)
		if prev >= 0.0:
			step = maxf(step, absf(val - prev))
		prev = val
		lo = minf(lo, val)
	check_lt(c, "a face tilted toward one arm: no step across the V's bisector (max change per 2 px)", step, 0.02)
	check_gt(c, "both arms light it on either side of the bisector", lo, AMBIENT, 0.05)
	check_approx(c, "the flat floor beside it reads the V's integral",
			_ref(P_BIS + Vector2(-80, 0), PackedVector2Array([V_APEX + Vector2(-240, 0), V_APEX, V_APEX + Vector2(0, -240)]), false,
					300.0, 1.0, 1.0, 60.0), lum(img, P_BIS + Vector2(-80, 0)), TOL)
	# The luminance mirror follows the integral: get_luminance() on normal-mapped sprites
	# under the V matches their rendered mean.
	var white := tex_sized(Vector2(64, 64))
	var dome := lit_sprite(white, Vector2(900, 760), 2.0, tex_fn(64, 64, func(x, y):
		return LitSuiteSection.normal_color(((x + 0.5) / 32.0 - 1.0) / 0.6, -((y + 0.5) / 32.0 - 1.0) / 0.6)))
	dome.specular_strength = 0.0
	var tilt := lit_sprite(white, Vector2(900, 640), 2.0, tex_normal(8, -0.8, 0.8))
	tilt.specular_strength = 0.0
	await frames(2)
	img = await capture()
	check_approx(c, "a dome under the V: get_luminance() matches the rendered mean",
			mean_lum(img, Rect2(838, 698, 124, 124)), dome.get_luminance(), 0.015)
	check_approx(c, "a tilted sprite under the V: get_luminance() matches the rendered mean",
			mean_lum(img, Rect2(838, 578, 124, 124)), tilt.get_luminance(), 0.015)
	v.queue_free()
	face.queue_free()
	dome.queue_free()
	tilt.queue_free()
	await frames(1)
	var ring := line_light(CR, 300.0, 1.0, 60.0)
	ring_child(ring, 80.0)
	var side := tilted_box(CR, 40, 0.6)
	await frames(2)
	img = await capture()
	var plus: Array[float] = []
	for k in 8:
		plus.append(lum(img, CR + Vector2.from_angle(k * PI / 4.0) * 12.0, 1))
	var center := lum(img, CR, 1)
	check_gt(c, "a face at the ring's center is lit (every side of the ring reaches it)", center, AMBIENT, 0.05)
	var ring80 := _ring_pts(CR, 80.0)
	check_approx(c, "and reads the ring's integral on that face", _ref(CR, ring80, true, 300.0, 1.0, 1.0, 60.0, 0.0, 1.0, Vector3(0.6, 0.0, 1.0).normalized()),
			center, 0.04)
	var tilt_n := Vector3(0.6, 0.0, 1.0).normalized()
	check_approx(c, "12 px toward the side it faces it reads the ring's integral there", _ref(CR + Vector2(12, 0), ring80, true, 300.0, 1.0, 1.0, 60.0, 0.0, 1.0, tilt_n),
			plus[0], 0.04)
	check_approx(c, "and 12 px away from it (the ring around it lights it from the side it faces)",
			_ref(CR - Vector2(12, 0), ring80, true, 300.0, 1.0, 1.0, 60.0, 0.0, 1.0, tilt_n), plus[4], 0.04)
	check_approx(c, "the flat floor beside the ring reads its integral (40 px outside)",
			_ref(CR + Vector2(-120, 0), ring80, true, 300.0, 1.0, 1.0, 60.0), lum(img, CR + Vector2(-120, 0)), TOL)
	side.texture = canvas_tex(tex_sized(Vector2(40, 40)), tex_normal(40, -0.6))
	await frames(2)
	img = await capture()
	check_approx(c, "the opposite tilt reads the same at the center (lit from all around)", center, lum(img, CR, 1), 0.01)
	var mirror := 0.0
	for k in 8:
		mirror = maxf(mirror, absf(plus[k] - lum(img, CR + Vector2.from_angle(k * PI / 4.0 + PI) * 12.0, 1)))
	check_lt(c, "and mirrors it around the center (the ring has no preferred side)", mirror, 0.015)


func _exit_tree() -> void:
	if _cam != null and is_instance_valid(_cam):
		_cam.enabled = false
	get_viewport().canvas_transform = Transform2D()
	super()
