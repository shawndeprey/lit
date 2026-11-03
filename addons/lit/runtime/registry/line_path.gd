extends RefCounted

## Arc chain of a curved line light: a Path2D curve fitted with biarcs, in the curve's local space.

const ROW_ARCS := 32  # a chain this long packs in one path row; a longer one packs as a PathTree
const TREE_LEAF := 4
const TREE_OPEN := 2.0  # a node this many radii away stands for its chords (the shader's LIT_PATH_TREE_OPEN)
const TOLERANCE := 0.1
const MAX_DEPTH := 6
const STRAIGHT := 1e-6
const COS_JOINT := 0.99985  # 1 degree
const CLOSE_BIARC := 1  # LitLineLight2D.CloseMode
const CLOSE_STRAIGHT := 2
const CLOSE_SYMMETRIC := 3
const CLOSE_CURVATURE_ARC := 4
const CLOSE_SOFT_ARC := 5
const LineClose := preload("res://addons/lit/runtime/registry/line_close.gd")


class Chain:
	var points := PackedVector2Array()   # arc_count + 1; a closed chain repeats its first point last
	var bulges := PackedFloat32Array()   # tan(sweep / 4) per arc, 0 = straight
	var apexes := PackedVector2Array()
	var lengths := PackedFloat32Array()
	var stretches := PackedInt32Array()  # first arc of each stretch between two path points, then arc_count
	var bends := PackedByteArray()  # 1 per stretch whose handles pull it off the line between its points

	func arc_count() -> int:
		return bulges.size()


## A chain longer than ROW_ARCS as shading items and a binary tree over them (the shader's
## Barnes-Hut walk, light_packer.gd _pack_tree). Each item is the piece of one arc between
## two shading cuts, the arcs cut as shade_chords cuts each run of up to ROW_ARCS of them;
## each node holds a contiguous item range, in preorder.
class PathTree:
	var points := PackedVector2Array()   # items + 1, in path order
	var bulges := PackedFloat32Array()   # per item
	var lo := PackedInt32Array()         # per node: its first item
	var hi := PackedInt32Array()         # its end item
	var skip := PackedInt32Array()       # the node after its subtree
	var leaf := PackedByteArray()


## A PathTree's items and nodes under a transform: per item its bulge and the radius of a
## disc about its chord's middle holding it; per node its circle (center the chords'
## length-weighted centroid), chord length, second moment about the center (xx, xy, yy),
## direction moment (xx, xy of the length-weighted mean of t t^T) and box of its arcs.
class PathTreeSpace:
	var tree: PathTree
	var points := PackedVector2Array()
	var bulges := PackedFloat32Array()
	var discs := PackedFloat32Array()
	var centers := PackedVector2Array()
	var radii := PackedFloat32Array()
	var lengths := PackedFloat32Array()
	var moments := PackedFloat32Array()  # 5 per node: Q xx, xy, yy, S xx, xy
	var boxes := PackedVector4Array()  # per node: min xy, max xy of its arcs' discs


## Fit `curve` under `xf` within TOLERANCE. `cache` maps each Bezier stretch (its four
## points under `xf`) to its arcs from the last fit; it is refilled with this fit's, so an
## edit refits only the stretches it moved. `close_mode` (a CLOSE_ constant) shapes the
## closing stretch.
static func fit(curve: Curve2D, closed: bool, xf := Transform2D(), cache := {},
		close_mode := CLOSE_SYMMETRIC) -> Chain:
	var chain := Chain.new()
	if curve == null or curve.point_count < 2:
		return chain
	var segs: Array[PackedVector2Array] = []
	for i in curve.point_count - 1:
		segs.append(_bezier(curve, i, i + 1, xf))
	var pts := PackedVector2Array([segs[0][0]])
	var bul := PackedFloat32Array()
	var starts := PackedInt32Array([0])
	var bends := PackedByteArray()
	var old := cache.duplicate()
	cache.clear()
	for s in segs:
		bends.append(0 if _straight(s) else 1)
		var arcs: Array = old.get(s, [])
		if arcs.is_empty():
			var sp := PackedVector2Array([s[0]])
			var sb := PackedFloat32Array()
			_fit_bezier(s, TOLERANCE, sp, sb, 0)
			arcs = [sp.slice(1), sb]
		cache[s] = arcs
		pts.append_array(arcs[0])
		bul.append_array(arcs[1])
		starts.append(bul.size())
	if closed:
		_close(segs, pts, bul, close_mode)
		starts.append(bul.size())
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


## True when `curve` is two points with a straight line between them under `xf`.
static func straight_pair(curve: Curve2D, xf := Transform2D()) -> bool:
	return curve != null and curve.point_count == 2 and _straight(_bezier(curve, 0, 1, xf))


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


static func _close(segs: Array[PackedVector2Array], pts: PackedVector2Array, bul: PackedFloat32Array,
		mode: int) -> void:
	var a := pts[pts.size() - 1]
	var d := pts[0]
	if a.distance_squared_to(d) < 1e-6:
		return
	var ta := _tangent(segs[segs.size() - 1], 1.0)
	var td := _tangent(segs[0], 0.0)
	if mode >= CLOSE_SYMMETRIC:
		LineClose.close(pts, bul, ta, td, mode)
		return
	var bulge := 0.0
	if mode == CLOSE_BIARC:
		var bi := biarc(a, ta, d, td)
		var b1: float = bi[1]
		var b2: float = bi[2]
		if is_finite(b1) and is_finite(b2) and absf(b1) <= 1e4 and absf(b2) <= 1e4:
			pts.append(bi[0])
			bul.append(b1)
			bulge = b2
	pts.append(d)
	bul.append(bulge)


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
	var counts := _chord_counts(chain, 0, arcs, n)
	out.append(chain.points[0])
	for k in arcs:
		for j in counts[k]:
			out.append(arc_point(chain.points[k], chain.points[k + 1], chain.bulges[k], float(j + 1) / float(counts[k])))
	return out


## Shading chords per arc of `a0`..`a1` (see shade_chords).
static func _chord_counts(chain: Chain, a0: int, a1: int, n: int) -> PackedInt32Array:
	var arcs := a1 - a0
	var lens := PackedFloat32Array()
	lens.resize(arcs)
	var curved_len := 0.0
	var straight := 0
	for k in arcs:
		if absf(chain.bulges[a0 + k]) < 1e-3:
			straight += 1
			lens[k] = -1.0
		else:
			lens[k] = chain.lengths[a0 + k]
			curved_len += lens[k]
	var counts := _apportion(lens, curved_len, maxi(n - straight, arcs - straight))
	for k in arcs:
		if lens[k] < 0.0:
			counts[k] = 1
	return counts


## `budget` pieces shared by the entries of `lens` (negative: left out, 0 pieces) by
## length, at least one each: floors of the shares, then one more to the largest
## fractions (ties to the first), then one fewer from the largest counts (ties to the
## first) while over, as one piece at a time would deal them.
static func _apportion(lens: PackedFloat32Array, total: float, budget: int) -> PackedInt32Array:
	var count := lens.size()
	var pieces := PackedInt32Array()
	pieces.resize(count)
	var rem := PackedFloat32Array()
	rem.resize(count)
	var left := budget
	var order := []
	for g in count:
		if lens[g] < 0.0:
			continue
		var share := float(budget) * lens[g] / maxf(total, 1e-6)
		pieces[g] = maxi(int(floor(share)), 1)
		rem[g] = share - floor(share)
		left -= pieces[g]
		order.append(g)
	if left > 0:
		order.sort_custom(func(x: int, y: int) -> bool: return rem[x] > rem[y] or (rem[x] == rem[y] and x < y))
		for g in mini(left, order.size()):
			pieces[order[g]] += 1
	elif left < 0:
		order.sort_custom(func(x: int, y: int) -> bool: return pieces[x] > pieces[y] or (pieces[x] == pieces[y] and x < y))
		var level := []
		var i := 0
		while left < 0:
			var top: int = pieces[order[i]] if i < order.size() else 0
			while i < order.size() and pieces[order[i]] == top:
				level.append(order[i])
				i += 1
			level.sort()
			var floor_to: int = pieces[order[i]] if i < order.size() else 0
			while left < 0 and top > floor_to:
				for g in level:
					pieces[g] -= 1
					left += 1
					if left == 0:
						break
				top -= 1
	return pieces


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
	var pieces := _apportion(lens, curved_len, maxi(n, curved))
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


## The chain's PathTree: its arcs in runs of up to ROW_ARCS (near-equal runs), each run cut
## into items as shade_chords cuts a chain of ROW_ARCS shading chords.
static func tree(chain: Chain) -> PathTree:
	var t := PathTree.new()
	var arcs := chain.arc_count()
	if arcs == 0:
		return t
	t.points.append(chain.points[0])
	var groups := ceili(float(arcs) / float(ROW_ARCS))
	for g in groups:
		@warning_ignore("integer_division")
		var a0 := arcs * g / groups
		@warning_ignore("integer_division")
		var a1 := arcs * (g + 1) / groups
		var counts := _chord_counts(chain, a0, a1, ROW_ARCS)
		for k in range(a0, a1):
			var m := counts[k - a0]
			var sub := tan(atan(chain.bulges[k]) / float(m))
			for j in m:
				t.points.append(chain.points[k + 1] if j == m - 1
						else arc_point(chain.points[k], chain.points[k + 1], chain.bulges[k], float(j + 1) / float(m)))
				t.bulges.append(sub)
	var n := t.bulges.size()
	var lows := PackedVector2Array()
	var highs := PackedVector2Array()
	lows.resize(n)
	highs.resize(n)
	for k in n:
		var a := t.points[k]
		var b := t.points[k + 1]
		var r := Vector2.ONE * (0.5 * a.distance_to(b) * maxf(absf(t.bulges[k]), 1.0))
		lows[k] = (a + b) * 0.5 - r
		highs[k] = (a + b) * 0.5 + r
	_tree_node(t, lows, highs, 0, n)
	return t


static func _tree_node(t: PathTree, lows: PackedVector2Array, highs: PackedVector2Array, lo: int, hi: int) -> void:
	var j := t.lo.size()
	t.lo.append(lo)
	t.hi.append(hi)
	t.skip.append(0)
	t.leaf.append(1 if hi - lo <= TREE_LEAF else 0)
	if hi - lo > TREE_LEAF:
		var k := _tree_split(lows, highs, lo, hi)
		_tree_node(t, lows, highs, lo, k)
		_tree_node(t, lows, highs, k, hi)
	t.skip[j] = t.lo.size()


## The cut of `lo`..`hi` into two contiguous ranges that minimizes the sum over both of
## their box's half diagonal times their item count, each keeping at least an eighth.
static func _tree_split(lows: PackedVector2Array, highs: PackedVector2Array, lo: int, hi: int) -> int:
	var m := hi - lo
	var keep := maxi(m >> 3, 1)
	var suffix := PackedFloat32Array()
	suffix.resize(m)
	var l := lows[hi - 1]
	var h := highs[hi - 1]
	for k in range(m - 1, 0, -1):
		l = l.min(lows[lo + k])
		h = h.max(highs[lo + k])
		suffix[k] = 0.5 * l.distance_to(h) * float(m - k)
	l = lows[lo]
	h = highs[lo]
	var best := lo + (m >> 1)
	var best_cost := INF
	for k in range(1, m):
		if k >= keep and m - k >= keep:
			var cost := 0.5 * l.distance_to(h) * float(k) + suffix[k]
			if cost < best_cost:
				best_cost = cost
				best = lo + k
		l = l.min(lows[lo + k])
		h = h.max(highs[lo + k])
	return best


## The tree's items and nodes under `xf` (see PathTreeSpace).
static func tree_space(t: PathTree, xf: Transform2D) -> PathTreeSpace:
	var s := PathTreeSpace.new()
	s.tree = t
	s.points = xf * t.points
	var n := t.bulges.size()
	var sx := xf.x.length_squared()
	var sy := xf.y.length_squared()
	var smax := maxf(sx, sy)
	var similar := smax > 0.0 and absf(sx - sy) <= 1e-5 * smax and absf(xf.x.dot(xf.y)) <= 1e-5 * smax
	var flip := -1.0 if xf.determinant() < 0.0 else 1.0
	s.bulges.resize(n)
	s.discs.resize(n)
	var lens := PackedFloat32Array()
	lens.resize(n)
	for k in n:
		var a := s.points[k]
		var b := s.points[k + 1]
		var bulge := t.bulges[k] * flip if similar \
				else bulge_through(a, b, xf * apex(t.points[k], t.points[k + 1], t.bulges[k]))
		s.bulges[k] = bulge
		var l := a.distance_to(b)
		lens[k] = l
		s.discs[k] = 0.5 * l * maxf(absf(bulge), 1.0) * 1.0001 + 0.001
	var nodes := t.lo.size()
	s.centers.resize(nodes)
	s.radii.resize(nodes)
	s.lengths.resize(nodes)
	s.moments.resize(nodes * 5)
	s.boxes.resize(nodes)
	for j in range(nodes - 1, -1, -1):
		var c := Vector2.ZERO
		var total := 0.0
		var qxx := 0.0
		var qxy := 0.0
		var qyy := 0.0
		var dxx := 0.0
		var dxy := 0.0
		var r := 0.0
		var box := Vector4(INF, INF, -INF, -INF)
		if t.leaf[j] != 0:
			for k in range(t.lo[j], t.hi[j]):
				var mid := (s.points[k] + s.points[k + 1]) * 0.5
				c += mid * lens[k]
				total += lens[k]
				box = Vector4(minf(box.x, mid.x - s.discs[k]), minf(box.y, mid.y - s.discs[k]),
						maxf(box.z, mid.x + s.discs[k]), maxf(box.w, mid.y + s.discs[k]))
			c = c / total if total > 1e-9 else (s.points[t.lo[j]] + s.points[t.hi[j]]) * 0.5
			for k in range(t.lo[j], t.hi[j]):
				var d := (s.points[k] + s.points[k + 1]) * 0.5 - c
				var hv := (s.points[k + 1] - s.points[k]) * 0.5
				var l := lens[k]
				qxx += l * (d.x * d.x + hv.x * hv.x / 3.0)
				qxy += l * (d.x * d.y + hv.x * hv.y / 3.0)
				qyy += l * (d.y * d.y + hv.y * hv.y / 3.0)
				if l > 1e-9:
					dxx += 4.0 * hv.x * hv.x / l
					dxy += 4.0 * hv.x * hv.y / l
				r = maxf(r, d.length() + s.discs[k])
		else:
			for kid in [j + 1, t.skip[j + 1]]:
				c += s.centers[kid] * s.lengths[kid]
				total += s.lengths[kid]
				var kb := s.boxes[kid]
				box = Vector4(minf(box.x, kb.x), minf(box.y, kb.y), maxf(box.z, kb.z), maxf(box.w, kb.w))
			c = c / total if total > 1e-9 else s.centers[j + 1]
			for kid in [j + 1, t.skip[j + 1]]:
				var d: Vector2 = s.centers[kid] - c
				var l: float = s.lengths[kid]
				var o: int = kid * 5
				qxx += s.moments[o] + l * d.x * d.x
				qxy += s.moments[o + 1] + l * d.x * d.y
				qyy += s.moments[o + 2] + l * d.y * d.y
				dxx += s.moments[o + 3] * l
				dxy += s.moments[o + 4] * l
				r = maxf(r, d.length() + s.radii[kid])
		s.centers[j] = c
		s.radii[j] = r
		s.lengths[j] = total
		s.boxes[j] = box
		s.moments[j * 5] = qxx
		s.moments[j * 5 + 1] = qxy
		s.moments[j * 5 + 2] = qyy
		s.moments[j * 5 + 3] = dxx / total if total > 1e-9 else 1.0
		s.moments[j * 5 + 4] = dxy / total if total > 1e-9 else 0.0
	return s
