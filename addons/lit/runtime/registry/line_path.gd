extends RefCounted

## Arc chain of a curved line light: a Path2D curve fitted with biarcs, in the curve's local space.

const MAX_ARCS := 32
const TOLERANCE := 0.1
const MAX_DEPTH := 6
const STRAIGHT := 1e-6
const COS_JOINT := 0.99985  # 1 degree


class Chain:
	var points := PackedVector2Array()   # arc_count + 1; a closed chain repeats its first point last
	var bulges := PackedFloat32Array()   # tan(sweep / 4) per arc, 0 = straight
	var apexes := PackedVector2Array()
	var lengths := PackedFloat32Array()
	var stretches := PackedInt32Array()  # first arc of each stretch between two path points, then arc_count
	var bends := PackedByteArray()  # 1 per stretch whose handles pull it off the line between its points
	var truncated := false

	func arc_count() -> int:
		return bulges.size()


## Fit `curve` under `xf` within TOLERANCE where MAX_ARCS allows, else within the loosest
## tolerance that fits, else the first MAX_ARCS arcs (truncated).
static func fit(curve: Curve2D, closed: bool, xf := Transform2D()) -> Chain:
	var chain := Chain.new()
	if curve == null or curve.point_count < 2:
		return chain
	var segs: Array[PackedVector2Array] = []
	for i in curve.point_count - 1:
		segs.append(_bezier(curve, i, i + 1, xf))
	var tol := TOLERANCE
	var pts := PackedVector2Array()
	var bul := PackedFloat32Array()
	var starts := PackedInt32Array()
	var bends := PackedByteArray()
	for s in segs:
		bends.append(0 if _straight(s) else 1)
	for attempt in 9:
		pts = PackedVector2Array([segs[0][0]])
		bul = PackedFloat32Array()
		starts = PackedInt32Array([0])
		for s in segs:
			_fit_bezier(s, tol, pts, bul, 0)
			starts.append(bul.size())
		if closed:
			_close(segs, pts, bul)
			starts.append(bul.size())
		if bul.size() <= MAX_ARCS:
			break
		tol *= 2.0
	if bul.size() > MAX_ARCS:
		chain.truncated = true
		bul.resize(MAX_ARCS)
		pts.resize(MAX_ARCS + 1)
		for i in starts.size():
			starts[i] = mini(starts[i], MAX_ARCS)
	chain.points = pts
	chain.stretches = starts
	if closed:
		var sag := 0.0
		for k in range(starts[starts.size() - 2], starts[starts.size() - 1]):
			sag = maxf(sag, absf(bul[k]) * pts[k].distance_to(pts[k + 1]))
		bends.append(1 if sag >= 0.2 * TOLERANCE else 0)
	chain.bends = bends
	chain.bulges = bul
	for k in bul.size():
		chain.apexes.append(apex(pts[k], pts[k + 1], bul[k]))
		chain.lengths.append(arc_length(pts[k], pts[k + 1], bul[k]))
	return chain


static func _bezier(curve: Curve2D, i: int, j: int, xf: Transform2D) -> PackedVector2Array:
	var a := xf * curve.get_point_position(i)
	var d := xf * curve.get_point_position(j)
	return PackedVector2Array([a, a + xf.basis_xform(curve.get_point_out(i)),
			d + xf.basis_xform(curve.get_point_in(j)), d])


static func _fit_bezier(b: PackedVector2Array, tol: float, pts: PackedVector2Array,
		bul: PackedFloat32Array, depth: int) -> void:
	var a := b[0]
	var d := b[3]
	if a.distance_squared_to(d) < 1e-8:
		if depth >= MAX_DEPTH or (b[1].distance_squared_to(a) < 1e-8 and b[2].distance_squared_to(d) < 1e-8):
			return
		var loop := _split(b)
		_fit_bezier(loop[0], tol, pts, bul, depth + 1)
		_fit_bezier(loop[1], tol, pts, bul, depth + 1)
		return
	var t0 := _tangent(b, 0.0)
	var t1 := _tangent(b, 1.0)
	var single := bulge_from_tangent(a, d, t0)
	if end_tangent(a, d, single).dot(t1) >= COS_JOINT \
			and _deviation(b, PackedVector2Array([a, d]), PackedFloat32Array([single])) <= tol:
		pts.append(d)
		bul.append(single)
		return
	var bi := biarc(a, t0, d, t1)
	var j: Vector2 = bi[0]
	if depth >= MAX_DEPTH or _deviation(b, PackedVector2Array([a, j, d]), PackedFloat32Array([bi[1], bi[2]])) <= tol:
		pts.append(j)
		bul.append(bi[1])
		pts.append(d)
		bul.append(bi[2])
		return
	var halves := _split(b)
	_fit_bezier(halves[0], tol, pts, bul, depth + 1)
	_fit_bezier(halves[1], tol, pts, bul, depth + 1)


## True when the Bezier's handles stay within a tenth of TOLERANCE of the line between its ends.
static func _straight(b: PackedVector2Array) -> bool:
	var d := b[3] - b[0]
	var l := d.length()
	if l < 1e-6:
		return b[1].distance_to(b[0]) < 1e-6 and b[2].distance_to(b[3]) < 1e-6
	var n := Vector2(-d.y, d.x) / l
	return absf(n.dot(b[1] - b[0])) <= 0.1 * TOLERANCE and absf(n.dot(b[2] - b[0])) <= 0.1 * TOLERANCE


static func _close(segs: Array[PackedVector2Array], pts: PackedVector2Array, bul: PackedFloat32Array) -> void:
	var a := pts[pts.size() - 1]
	var d := pts[0]
	if a.distance_squared_to(d) < 1e-6:
		return
	var bi := biarc(a, _tangent(segs[segs.size() - 1], 1.0), d, _tangent(segs[0], 0.0))
	pts.append(bi[0])
	bul.append(bi[1])
	pts.append(d)
	bul.append(bi[2])


static func _split(b: PackedVector2Array) -> Array[PackedVector2Array]:
	var p01 := b[0].lerp(b[1], 0.5)
	var p12 := b[1].lerp(b[2], 0.5)
	var p23 := b[2].lerp(b[3], 0.5)
	var p012 := p01.lerp(p12, 0.5)
	var p123 := p12.lerp(p23, 0.5)
	var m := p012.lerp(p123, 0.5)
	return [PackedVector2Array([b[0], p01, p012, m]), PackedVector2Array([m, p123, p23, b[3]])]


static func _point(b: PackedVector2Array, t: float) -> Vector2:
	var u := 1.0 - t
	return b[0] * (u * u * u) + b[1] * (3.0 * u * u * t) + b[2] * (3.0 * u * t * t) + b[3] * (t * t * t)


static func _tangent(b: PackedVector2Array, t: float) -> Vector2:
	var u := 1.0 - t
	var v := (b[1] - b[0]) * (u * u) + (b[2] - b[1]) * (2.0 * u * t) + (b[3] - b[2]) * (t * t)
	if v.length_squared() < 1e-10:
		v = _point(b, minf(t + 0.01, 1.0)) - _point(b, maxf(t - 0.01, 0.0))
	if v.length_squared() < 1e-10:
		v = b[3] - b[0]
	return v.normalized() if v.length_squared() > 0.0 else Vector2.RIGHT


static func _deviation(b: PackedVector2Array, pts: PackedVector2Array, bul: PackedFloat32Array) -> float:
	var worst := 0.0
	for k in range(1, 12):
		var p := _point(b, float(k) / 12.0)
		var best := INF
		for i in bul.size():
			best = minf(best, p.distance_to(nearest_on_arc(pts[i], pts[i + 1], bul[i], p)))
		worst = maxf(worst, best)
	return worst


## Two arcs from `a` (tangent `t0`) to `d` (tangent `t1`) sharing a tangent at their
## joint: [joint, bulge 1, bulge 2].
static func biarc(a: Vector2, t0: Vector2, d: Vector2, t1: Vector2) -> Array:
	var v := d - a
	var k := 1.0 - t0.dot(t1)
	var j: Vector2
	if k < 1e-6:
		j = a + v * 0.5
	else:
		var vt := v.dot(t0 + t1)
		var dl := (sqrt(vt * vt + 2.0 * k * v.length_squared()) - vt) / (2.0 * k)
		j = (a + t0 * dl + d - t1 * dl) * 0.5
	return [j, bulge_from_tangent(a, j, t0), -tan(0.5 * (d - j).normalized().angle_to(t1))]


## Bulge of the arc from `a` to `b` leaving `a` along `t`.
static func bulge_from_tangent(a: Vector2, b: Vector2, t: Vector2) -> float:
	return tan(0.5 * (b - a).normalized().angle_to(t))


## Bulge of the arc from `a` to `b` through `x` (exact when `x` is its apex).
static func bulge_through(a: Vector2, b: Vector2, x: Vector2) -> float:
	var h := (b - a) * 0.5
	var l2 := h.length_squared()
	if l2 < 1e-10:
		return 0.0
	return (x - a - h).dot(Vector2(-h.y, h.x)) / l2


static func start_tangent(a: Vector2, b: Vector2, bulge: float) -> Vector2:
	return (b - a).normalized().rotated(2.0 * atan(bulge))


static func end_tangent(a: Vector2, b: Vector2, bulge: float) -> Vector2:
	return (b - a).normalized().rotated(-2.0 * atan(bulge))


static func apex(a: Vector2, b: Vector2, bulge: float) -> Vector2:
	var h := (b - a) * 0.5
	return a + h + Vector2(-h.y, h.x) * bulge


static func arc_length(a: Vector2, b: Vector2, bulge: float) -> float:
	var l := a.distance_to(b)
	if absf(bulge) < STRAIGHT:
		return l
	return l * (1.0 + bulge * bulge) * absf(atan(bulge)) / absf(bulge)


## [center, radius]; the arc's angle runs from `a` by -4 atan(bulge).
static func arc_circle(a: Vector2, b: Vector2, bulge: float) -> Array:
	var h := (b - a) * 0.5
	var l := h.length()
	var n := Vector2(-h.y, h.x) / l
	return [a + h - n * (l * (1.0 - bulge * bulge) / (2.0 * bulge)), l * (1.0 + bulge * bulge) / (2.0 * absf(bulge))]


## The point a fraction `f` of the way along the arc.
static func arc_point(a: Vector2, b: Vector2, bulge: float, f: float) -> Vector2:
	if absf(bulge) < STRAIGHT:
		return a.lerp(b, f)
	# Along the chord, never through the center: a near-straight arc's center is too far for float32.
	var half := 2.0 * atan(bulge)
	var s := sin(half)
	var k := f if absf(s) < 1e-12 else sin(f * half) / s
	return a + (b - a).rotated((1.0 - f) * half) * k


## The point of the arc nearest `p` (the shader's lit_path_nearest, per arc).
static func nearest_on_arc(a: Vector2, b: Vector2, bulge: float, p: Vector2) -> Vector2:
	var ab := b - a
	var l2 := ab.length_squared()
	if absf(bulge) < 1e-3 or l2 < 1e-8:
		return a + ab * clampf((p - a).dot(ab) / maxf(l2, 1e-8), 0.0, 1.0)
	var cr := arc_circle(a, b, bulge)
	var c: Vector2 = cr[0]
	var v := p - c
	var vl := v.length()
	var vh := v / maxf(vl, 1e-6)
	var mid := Vector2(-ab.y, ab.x).normalized() * signf(bulge)
	if vh.dot(mid) >= (1.0 - bulge * bulge) / (1.0 + bulge * bulge):
		return c + vh * cr[1]
	return a if p.distance_squared_to(a) < p.distance_squared_to(b) else b


static func nearest(chain: Chain, p: Vector2) -> Vector2:
	var best := INF
	var q := chain.points[0] if chain.points.size() > 0 else Vector2.ZERO
	for k in chain.bulges.size():
		var cq := nearest_on_arc(chain.points[k], chain.points[k + 1], chain.bulges[k], p)
		var d2 := p.distance_squared_to(cq)
		if d2 < best:
			best = d2
			q = cq
	return q


## Exact bounds of the chain (arc extremes included).
static func bounds(chain: Chain) -> Rect2:
	if chain.points.is_empty():
		return Rect2()
	var r := Rect2(chain.points[0], Vector2.ZERO)
	for k in chain.bulges.size():
		var a := chain.points[k]
		var b := chain.points[k + 1]
		r = r.expand(b)
		var bulge := chain.bulges[k]
		if absf(bulge) < STRAIGHT:
			continue
		var cr := arc_circle(a, b, bulge)
		var c: Vector2 = cr[0]
		var mid := Vector2(a.y - b.y, b.x - a.x).normalized() * signf(bulge)
		var cos_phi := (1.0 - bulge * bulge) / (1.0 + bulge * bulge)
		for dir in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			if dir.dot(mid) >= cos_phi:
				r = r.expand(c + dir * cr[1])
	return r


## `n` + 1 points cutting the chain into `n` chords of equal arc length.
static func chords(chain: Chain, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if chain.points.is_empty():
		return out
	var total := 0.0
	for l in chain.lengths:
		total += l
	n = maxi(n, 1)
	if total <= 0.0:
		out.resize(n + 1)
		out.fill(chain.points[0])
		return out
	var arc := 0
	var start := 0.0
	for k in n + 1:
		var s := total * float(k) / float(n)
		while arc < chain.lengths.size() - 1 and s > start + chain.lengths[arc]:
			start += chain.lengths[arc]
			arc += 1
		var f := clampf((s - start) / maxf(chain.lengths[arc], 1e-6), 0.0, 1.0)
		out.append(arc_point(chain.points[arc], chain.points[arc + 1], chain.bulges[arc], f))
	return out


## Fit-space points cutting the chain into at most max(`n`, arcs) shading chords: a
## straight arc is one chord, so a straight path lights as the straight light's single
## chord, and the curved arcs share the rest of `n` by arc length, at least one each.
static func shade_chords(chain: Chain, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var arcs := chain.arc_count()
	if arcs == 0:
		return out
	var curved_len := 0.0
	var straight := 0
	for k in arcs:
		if absf(chain.bulges[k]) < 1e-3:
			straight += 1
		else:
			curved_len += chain.lengths[k]
	var budget := maxi(n - straight, arcs - straight)
	var counts := PackedInt32Array()
	counts.resize(arcs)
	var rem := PackedFloat32Array()
	rem.resize(arcs)
	var left := budget
	for k in arcs:
		if absf(chain.bulges[k]) < 1e-3:
			counts[k] = 1
			rem[k] = -1.0
		else:
			var share := float(budget) * chain.lengths[k] / maxf(curved_len, 1e-6)
			counts[k] = maxi(int(floor(share)), 1)
			rem[k] = share - floor(share)
			left -= counts[k]
	while left > 0:
		var best := -1
		for k in arcs:
			if rem[k] >= 0.0 and (best < 0 or rem[k] > rem[best]):
				best = k
		if best < 0:
			break
		counts[best] += 1
		rem[best] = -1.0
		left -= 1
	while left < 0:
		var most := 0
		for k in arcs:
			if counts[k] > counts[most]:
				most = k
		counts[most] -= 1
		left += 1
	out.append(chain.points[0])
	for k in arcs:
		for j in counts[k]:
			out.append(arc_point(chain.points[k], chain.points[k + 1], chain.bulges[k], float(j + 1) / float(counts[k])))
	return out


## The chain's tessellation groups as [first arc, end arc, bends]: each straight stretch
## alone, and each run of bending stretches meeting without a corner together.
static func runs(chain: Chain) -> Array:
	var out := []
	for s in chain.stretches.size() - 1:
		var a := chain.stretches[s]
		var b := chain.stretches[s + 1]
		if a == b:
			continue
		var bends := chain.bends[s] != 0
		if bends and not out.is_empty() and out[-1][2] and end_tangent(chain.points[a - 1], chain.points[a],
				chain.bulges[a - 1]).dot(start_tangent(chain.points[a], chain.points[a + 1], chain.bulges[a])) >= COS_JOINT:
			out[-1][1] = b
		else:
			out.append([a, b, bends])
	return out


## Vector2i(bending runs, straight stretches) (see runs).
static func run_counts(chain: Chain) -> Vector2i:
	var out := Vector2i.ZERO
	for r in runs(chain):
		if r[2]:
			out.x += 1
		else:
			out.y += 1
	return out


## The chain as straight pieces: each straight stretch one piece, and the bending runs
## sharing max(`n`, their count) pieces by arc length, at least one each, cut at equal arc
## length. Corners and the ends of straight stretches stay exact.
static func tessellated(chain: Chain, n: int) -> Chain:
	var out := Chain.new()
	out.truncated = chain.truncated
	if chain.arc_count() == 0:
		return out
	var groups := runs(chain)
	var count := groups.size()
	var lens := PackedFloat32Array()
	lens.resize(count)
	lens.fill(-1.0)
	var curved := 0
	var curved_len := 0.0
	for g in count:
		if not groups[g][2]:
			continue
		lens[g] = 0.0
		for k in range(groups[g][0], groups[g][1]):
			lens[g] += chain.lengths[k]
		curved += 1
		curved_len += lens[g]
	var budget := maxi(n, curved)
	var pieces := PackedInt32Array()
	pieces.resize(count)
	var rem := PackedFloat32Array()
	rem.resize(count)
	rem.fill(-1.0)
	var left := budget
	for g in count:
		if lens[g] < 0.0:
			continue
		var share := float(budget) * lens[g] / maxf(curved_len, 1e-6)
		pieces[g] = maxi(int(floor(share)), 1)
		rem[g] = share - floor(share)
		left -= pieces[g]
	while left > 0:
		var best := -1
		for g in count:
			if rem[g] >= 0.0 and (best < 0 or rem[g] > rem[best]):
				best = g
		if best < 0:
			break
		pieces[best] += 1
		rem[best] = -1.0
		left -= 1
	while left < 0:
		var most := 0
		for g in count:
			if pieces[g] > pieces[most]:
				most = g
		pieces[most] -= 1
		left += 1
	out.points.append(chain.points[0])
	for g in count:
		var a: int = groups[g][0]
		var b: int = groups[g][1]
		var arc := a
		var start := 0.0
		for j in range(1, pieces[g]):
			var at := lens[g] * float(j) / float(pieces[g])
			while arc < b - 1 and at > start + chain.lengths[arc]:
				start += chain.lengths[arc]
				arc += 1
			var f := clampf((at - start) / maxf(chain.lengths[arc], 1e-6), 0.0, 1.0)
			out.points.append(arc_point(chain.points[arc], chain.points[arc + 1], chain.bulges[arc], f))
		out.points.append(chain.points[b])
	for k in out.points.size() - 1:
		var p := out.points[k]
		var q := out.points[k + 1]
		out.bulges.append(0.0)
		out.apexes.append(apex(p, q, 0.0))
		out.lengths.append(p.distance_to(q))
	return out


## The chain under `xf`: points mapped, each bulge refitted through its mapped apex.
static func transformed(chain: Chain, xf: Transform2D) -> Chain:
	var out := Chain.new()
	out.truncated = chain.truncated
	for p in chain.points:
		out.points.append(xf * p)
	for k in chain.bulges.size():
		var a := out.points[k]
		var b := out.points[k + 1]
		var bulge := bulge_through(a, b, xf * chain.apexes[k])
		out.bulges.append(bulge)
		out.apexes.append(apex(a, b, bulge))
		out.lengths.append(arc_length(a, b, bulge))
	return out
