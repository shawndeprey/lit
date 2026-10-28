extends LitSuiteSection

## LitLineLight2D bent by a Path2D child against the rendered frame: a 2-point path
## renders as the straight light pixel for pixel; a ring (closed 4-point curve) lights
## as a true circle (beam edge within a pixel of the circle, even around, no crease across
## the arc joints, nearest-point shading inside and out); ring and S-curve shadows (umbra
## behind a box outside the ring, inside lit, all three algorithms, shadow_length, the
## closed seam); the node API (closed, length greyed by the child, warnings), packing
## (flags bit 23, path row, arc count), the mirror, culling by the chain's bounds, the
## luminance mirror, camera zoom invariance, a non-uniform node scale (an ellipse) and
## normal-mapped receivers (no seam across a V's bisector, a ring's center lit evenly
## from all around, a tilted face beside a 2-point path identical to the straight light).
##
## Numeric expectations are the receiver shader's diffuse term on a flat white receiver
## with d the distance past the tube's surface: albedo x ambient + energy x glow_term x
## (height / sqrt(d^2 + height^2)) x (1 - d / (range - half width))^falloff x diffuse_scale().

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


## Diffuse at distance d from the tube's center line on a flat white receiver.
func _exp(d: float, half_w: float, p_range: float, energy: float, glow: float, falloff: float,
		height: float) -> float:
	var surf := maxf(d - half_w, 0.0)
	var reach := p_range - half_w
	if surf > reach:
		return AMBIENT
	var beam := clampf(minf(d + 0.5, half_w) - maxf(d - 0.5, -half_w), 0.0, 1.0)
	var atten := pow(clampf(1.0 - surf / reach, 0.0, 1.0), falloff)
	var ndotl := height / sqrt(surf * surf + height * height)
	var c := energy * lerpf(glow, 1.0, beam) * ndotl * atten
	return AMBIENT + (c * diffuse_scale() if c >= 0.004 else 0.0)


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
	l.queue_free()
	face.queue_free()
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
	var on := _exp(0.0, 10.0, 150.0, 0.5, 0.5, 1.0, 100.0)
	var out60 := _exp(60.0, 10.0, 150.0, 0.5, 0.5, 1.0, 100.0)
	for k in 8:
		var dir := Vector2.from_angle(k * PI / 4.0)
		check_approx(c, "on the beam at %d deg" % (k * 45), on, lum(img, CA + dir * RA, 2), TOL)
	var ring_vals: Array[float] = []
	for k in 16:
		var dir := Vector2.from_angle(k * PI / 8.0)
		ring_vals.append(lum(img, CA + dir * (RA + 60.0)))
	check_approx(c, "60 px outside the ring reads the point-light value at 50 px past the surface", out60, ring_vals[0], TOL)
	check_lt(c, "the glow 60 px outside is even around the ring (max - min)", ring_vals.max() - ring_vals.min(), 0.01)
	check_approx(c, "60 px inside the ring reads the same (nearest-point shading)", out60, lum(img, CA + Vector2(60, 0)), TOL)
	check_approx(c, "the ring's center is 120 px from the tube", _exp(RA, 10.0, 150.0, 0.5, 0.5, 1.0, 100.0), lum(img, CA), TOL)
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
	check_approx(c, "inside the ring: the center reads the 100 px value, unshadowed", _exp(RB, 0.0, 250.0, 0.8, 1.0, 0.3, 300.0),
			lum(img, CB), TOL)
	check_approx(c, "inside the ring: 60 px toward the left box reads the 40 px value", _exp(40.0, 0.0, 250.0, 0.8, 1.0, 0.3, 300.0),
			lum(img, CB + Vector2(-60, 0)), TOL)
	var cone_pen := lum(img, P_PEN)
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
	check_approx(c, "closed: the seam at 315 deg is on the ring", AMBIENT + 0.8 * diffuse_scale(), on, TOL)
	_ring_b.closed = false
	await frames(2)
	img = await capture()
	check_approx(c, "open: the seam reads the distance to the nearer end (76 px)", _exp(2.0 * RB * sin(PI / 8.0), 0.0, 250.0, 0.8, 1.0, 0.3, 300.0),
			lum(img, P_SEAM, 1), TOL)
	check_approx(c, "open: the first point stays on the ring", AMBIENT + 0.8 * diffuse_scale(), lum(img, CB + Vector2(RB, 0), 1), TOL)
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
	var on := _exp(0.0, 4.0, 120.0, 0.5, 0.5, 1.0, 100.0)
	check_approx(c, "scale (2, 1): the beam passes 100 px right of the node", on, lum(img, CE + Vector2(100, 0), 1), TOL)
	check_approx(c, "scale (2, 1): and 50 px below it", on, lum(img, CE + Vector2(0, 50), 1), TOL)
	check_approx(c, "scale (2, 1): and through the ellipse's 45 deg point", on, lum(img, CE + Vector2(70.7, 35.4), 1), TOL)
	check_lt(c, "scale (2, 1): the circle's 45 deg point is off the beam", lum(img, CE + Vector2(35.4, 35.4), 1), on - 0.1)
	l.scale = Vector2.ONE
	await frames(2)
	img = await capture()
	check_approx(c, "scale 1: the circle's 45 deg point is back on the beam", on, lum(img, CE + Vector2(35.4, 35.4), 1), TOL)


# --- D: normal-mapped receivers --------------------------------------------------------------------

## A white receiver box whose normal map tilts every texel toward (nx, ny), specular off.
## A child of the section, so it draws over the floors (Props draws under them).
func tilted_box(pos: Vector2, size: int, nx: float, ny := 0.0) -> LitSprite2D:
	var s := box_receiver(pos, Vector2(size, size), Color.WHITE, null, tex_normal(size, nx, ny))
	s.specular_strength = 0.0
	return s


## Diffuse at the center of a ring of radius r on a face with normal n: the mean clamped
## cosine over the ring (the shading chords' midpoints sit at r cos(pi / 32)), scaled to
## the nearest point's slant.
func _ring_face(r: float, height: float, p_range: float, energy: float, n: Vector3) -> float:
	var rc := r * cos(PI / 32.0)
	var acc := 0.0
	for k in 360:
		var a := deg_to_rad(float(k))
		acc += maxf(n.x * rc * cos(a) + n.y * rc * sin(a) + n.z * height, 0.0)
	var ndotl := acc / 360.0 / sqrt(r * r + height * height)
	return AMBIENT + energy * (1.0 - r / p_range) * ndotl * diffuse_scale()


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
	check_approx(c, "the flat floor beside it keeps the distance-field value (120 px from the nearer arm)",
			_exp(120.0, 0.0, 300.0, 1.0, 1.0, 1.0, 60.0), lum(img, P_BIS + Vector2(-80, 0)), TOL)
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
	check_approx(c, "and reads the ring's mean clamped cosine", _ring_face(80.0, 60.0, 300.0, 1.0, Vector3(0.6, 0.0, 1.0).normalized()),
			center, 0.04)
	check_gt(c, "12 px toward the side it faces it reads brighter than 12 px away from it", plus[0], plus[4], 0.01)
	check_approx(c, "the flat floor beside the ring keeps the distance-field value (40 px outside)",
			_exp(40.0, 0.0, 300.0, 1.0, 1.0, 1.0, 60.0), lum(img, CR + Vector2(-120, 0)), TOL)
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
