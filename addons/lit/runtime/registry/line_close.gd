extends RefCounted

## The closing stretch of a closed line light path for the Symmetric, Curvature Arc and Soft Arc
## close modes (line_path.gd _close), in the chain's fit space.

const LinePath := preload("res://addons/lit/runtime/registry/line_path.gd")

# Symmetric's weights, fitted to hand-picked closes of line_light_closing_test.tscn's paths.
const SIZE_LIMIT := 0.55
const SIZE_POWER := 8.0
const CORNER_WEIGHT := 2.0
const INFLECTION_WEIGHT := 1.0
const SYMMETRY_BONUS := 16.0
const SYMMETRY_TOLERANCE := 0.005
const REPEAT_TOLERANCE := 0.0005
const REPEAT_SHARE := 0.6
const REPEAT_STARTS := 48
const REPEAT_KEEP := 2
const FAMILY_STEPS := 10
const SAMPLES := 256
const PROBES := 48
const ARC_SAMPLES := 8


## Appends the closing arcs after `pts`' last point, ending on its first.
static func close(pts: PackedVector2Array, bul: PackedFloat32Array, ta: Vector2, td: Vector2, mode: int) -> void:
	var c := Closer.new(pts, bul, ta, td)
	var out: Array
	if mode == LinePath.CLOSE_CURVATURE_ARC:
		out = c.member(0.0)
	elif mode == LinePath.CLOSE_SOFT_ARC:
		out = c.member(0.5)
	else:
		out = c.symmetric()
	if out.is_empty():
		out = [PackedVector2Array([c.d]), PackedFloat32Array([0.0])]
	pts.append_array(out[0])
	bul.append_array(out[1])


class Closer:
	var pts: PackedVector2Array
	var bul: PackedFloat32Array
	var a: Vector2
	var d: Vector2
	var ta: Vector2
	var td: Vector2
	var gap := 0.0
	var size := 1.0
	var cum := PackedFloat32Array([0.0])
	var total := 0.0
	var dense := PackedVector2Array()
	var kap := PackedFloat32Array()
	var probes := PackedVector2Array()
	var cell := 1.0
	var grid := {}
	var rho := 0.0
	var sa := Vector2.RIGHT
	var ed := Vector2.RIGHT
	var base := 0.0

	func _init(p_pts: PackedVector2Array, p_bul: PackedFloat32Array, p_ta: Vector2, p_td: Vector2) -> void:
		pts = p_pts
		bul = p_bul
		ta = p_ta
		td = p_td
		a = pts[pts.size() - 1]
		d = pts[0]
		gap = a.distance_to(d)
		var smooth := 0.0
		var corners := 0.0
		for k in bul.size():
			cum.append(cum[k] + LinePath.arc_length(pts[k], pts[k + 1], bul[k]))
			if absf(4.0 * atan(bul[k])) >= 1e-3:
				smooth += -4.0 * atan(bul[k])
			if k > 0:
				corners += absf(LinePath.end_tangent(pts[k - 1], pts[k], bul[k - 1]).angle_to(
						LinePath.start_tangent(pts[k], pts[k + 1], bul[k])))
		total = maxf(cum[cum.size() - 1], 1e-6)
		rho = corners / maxf(corners + absf(smooth), 1e-9)
		for k in SAMPLES + 1:
			dense.append(at(total * k / SAMPLES))
			var j := _arc_at(total * k / SAMPLES)
			kap.append(absf(4.0 * atan(bul[j])) / maxf(cum[j + 1] - cum[j], 1e-6))
		var box := Rect2(dense[0], Vector2.ZERO)
		for p in dense:
			box = box.expand(p)
		size = maxf(maxf(box.size.x, box.size.y), 1e-6)
		cell = size / 24.0
		for k in SAMPLES:
			var c0 := _cell(dense[k])
			var c1 := _cell(dense[k + 1])
			for x in range(mini(c0.x, c1.x), maxi(c0.x, c1.x) + 1):
				for y in range(mini(c0.y, c1.y), maxi(c0.y, c1.y) + 1):
					var key := Vector2i(x, y)
					if not grid.has(key):
						grid[key] = []
					grid[key].append(k)
		for k in PROBES:
			probes.append(dense[k * SAMPLES / PROBES])
		var x := minf(absf(smooth / total) * gap * 0.5, 1.0)
		base = tan(-signf(smooth) * 2.0 * asin(x) / 4.0)
		sa = LinePath.start_tangent(a, d, base)
		ed = LinePath.end_tangent(a, d, base)

	func at(s: float) -> Vector2:
		var lo := 0
		var hi := cum.size() - 1
		while hi - lo > 1:
			var m := (lo + hi) >> 1
			if cum[m] <= s:
				lo = m
			else:
				hi = m
		var l := cum[lo + 1] - cum[lo]
		var f := clampf((s - cum[lo]) / l, 0.0, 1.0) if l > 0.0 else 0.0
		return LinePath.arc_point(pts[lo], pts[lo + 1], bul[lo], f)

	func _cell(p: Vector2) -> Vector2i:
		return Vector2i(floori(p.x / cell), floori(p.y / cell))

	## Distance from `p` to the drawn path or the polyline `extra` (bounded by `box`), capped
	## near two cells.
	func dist(p: Vector2, extra: PackedVector2Array, box: Rect2) -> float:
		var best2 := 4.0 * cell * cell
		var ks := PackedInt32Array()
		var d2s := PackedFloat32Array()
		var c := _cell(p)
		for x in range(c.x - 1, c.x + 2):
			for y in range(c.y - 1, c.y + 2):
				var segs = grid.get(Vector2i(x, y))
				if segs == null:
					continue
				for k in segs:
					var d2 := p.distance_squared_to(dense[k])
					ks.append(k)
					d2s.append(d2)
					best2 = minf(best2, d2)
		var best := sqrt(best2)
		var reach := (best + total / SAMPLES) * (best + total / SAMPLES)
		for i in ks.size():
			if d2s[i] > reach:
				continue
			var k := ks[i]
			if k > 0:
				best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, dense[k - 1], dense[k])))
			best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, dense[k], dense[k + 1])))
		if extra.size() > 1 and box.grow(best).has_point(p):
			for k in extra.size() - 1:
				best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, extra[k], extra[k + 1])))
		return best

	## Mean distance, over the shape's size, from the closed shape moved by `xf` to itself, the
	## closing polyline `poly` sampled as densely as `probe` samples the path; past `limit` it
	## stops early and returns INF.
	func error(xf: Transform2D, poly: PackedVector2Array, probe: PackedVector2Array, limit := INF) -> float:
		var spacing := total / probe.size()
		var own := PackedVector2Array()
		var acc := spacing * 0.5
		for k in poly.size() - 1:
			acc += poly[k].distance_to(poly[k + 1])
			while acc >= spacing:
				own.append(poly[k + 1])
				acc -= spacing
		var n := float(probe.size() + own.size())
		var cap := limit * n * size
		var box := Rect2(poly[0], Vector2.ZERO) if poly.size() > 0 else Rect2()
		for p in poly:
			box = box.expand(p)
		var e := 0.0
		for p in probe:
			e += dist(xf * p, poly, box)
			if e > cap:
				return INF
		for p in own:
			e += dist(xf * p, poly, box)
			if e > cap:
				return INF
		return e / n / size

	## The closing arcs [points after `a`, bulges] as a polyline from `a`.
	func polyline(out: Array) -> PackedVector2Array:
		var poly := PackedVector2Array([a])
		var p := a
		for k in out[1].size():
			var q: Vector2 = out[0][k]
			for i in range(1, ARC_SAMPLES + 1):
				poly.append(LinePath.arc_point(p, q, out[1][k], float(i) / ARC_SAMPLES))
			p = q
		return poly

	## The close between the curvature arc (`lam` 0) and the biarc (`lam` 1), or [] where the biarc breaks.
	func member(lam: float) -> Array:
		if lam <= 0.0:
			return [PackedVector2Array([d]), PackedFloat32Array([base])]
		var bi := LinePath.biarc(a, sa.rotated(sa.angle_to(ta) * lam), d, ed.rotated(ed.angle_to(td) * lam))
		var b1: float = bi[1]
		var b2: float = bi[2]
		if not is_finite(b1) or not is_finite(b2) or absf(b1) > 1e4 or absf(b2) > 1e4:
			return []
		return [PackedVector2Array([bi[0], d]), PackedFloat32Array([b1, b2])]

	func symmetric() -> Array:
		if gap < 1e-6:
			return []
		var covered := true
		for k in range(1, 16):
			if dist(a.lerp(d, k / 16.0), PackedVector2Array(), Rect2()) > 1e-3 * size:
				covered = false
				break
		if covered:
			return [PackedVector2Array(), PackedFloat32Array()]
		var ad := a - d
		var along := ad.dot(td)
		if ta.dot(td) >= 0.8 and along > 0.0 and absf(ad.cross(td)) < 0.6 * along:
			return [PackedVector2Array([d]), PackedFloat32Array([0.0])]
		var rep := repetition()
		return rep if not rep.is_empty() else family()

	## The best close from curvature arc to biarc: corners and S-bends cost by how smooth the path
	## is, a bulge past SIZE_LIMIT of the shape is ruled out, and each exact symmetry about the gap
	## earns SYMMETRY_BONUS.
	func family() -> Array:
		var best: Array = []
		var best_e := INF
		for i in FAMILY_STEPS + 1:
			var out := member(float(i) / FAMILY_STEPS)
			if out.is_empty():
				continue
			var poly := polyline(out)
			var sag := 0.0
			for p in poly:
				sag = maxf(sag, absf((d - a).cross(p - a)) / gap)
			var bs: PackedFloat32Array = out[1]
			var first := LinePath.start_tangent(a, out[0][0], bs[0])
			var last := LinePath.end_tangent(a if bs.size() == 1 else out[0][0], d, bs[bs.size() - 1])
			var ca := ta.angle_to(first)
			var cd := last.angle_to(td)
			var infl := 0.0
			if bs.size() == 2 and bs[0] * bs[1] < 0.0:
				infl = minf(absf(4.0 * atan(bs[0])), absf(4.0 * atan(bs[1])))
			var e := (1.0 - rho) * (CORNER_WEIGHT * (ca * ca + cd * cd) + INFLECTION_WEIGHT * infl * infl) \
					+ pow(sag / size / SIZE_LIMIT, SIZE_POWER) - SYMMETRY_BONUS * symmetries(poly)
			if e < best_e - 1e-6:
				best_e = e
				best = out
		return best

	## How many of the mirror across the gap's bisector, the mirror along the gap and the half turn
	## about its middle map the closed shape onto itself.
	func symmetries(poly: PackedVector2Array) -> int:
		var m := (a + d) * 0.5
		var u := (d - a) / gap
		var n := Vector2(-u.y, u.x)
		var probe := PackedVector2Array()
		for k in PROBES / 2:
			probe.append(probes[k * 2])
		var count := 0
		for xf in [_mirror(m, n), _mirror(m, u), Transform2D(Vector2(-1, 0), Vector2(0, -1), m * 2.0)]:
			if error(xf, poly, probe, SYMMETRY_TOLERANCE) <= SYMMETRY_TOLERANCE:
				count += 1
		return count

	static func _mirror(m: Vector2, w: Vector2) -> Transform2D:
		var xf := Transform2D(Vector2(2.0 * w.x * w.x - 1.0, 2.0 * w.x * w.y), Vector2(2.0 * w.x * w.y, 2.0 * w.y * w.y - 1.0), Vector2.ZERO)
		xf.origin = m - xf * m
		return xf

	## A piece of the path at most REPEAT_SHARE of it long that a rotation or mirror carries onto
	## the gap while mapping the whole closed shape onto itself, the gentlest-joined of those found,
	## or [].
	func repetition() -> Array:
		var best: Array = []
		var best_c := INF
		var found := 0
		var quick := PackedVector2Array()
		var fine := PackedVector2Array()
		for k in 8:
			quick.append(probes[k * PROBES / 8])
		for k in 24:
			fine.append(probes[k * PROBES / 24])
		var h := total / REPEAT_STARTS
		for i in REPEAT_STARTS:
			var s0 := total * i / REPEAT_STARTS
			var s1 := _chord_end(s0)
			if s1 == INF:
				continue
			for flags in 4:
				var mirror := flags & 1 == 1
				var rev := flags & 2 == 2
				var c := _piece(s0, s1, mirror, rev)
				if error(c[2], c[3], quick, 0.02) > 0.02 or not _twins(c[2], s0, s1):
					continue
				var lo := s0 - h
				var hi := s0 + h
				var g := (sqrt(5.0) - 1.0) * 0.5
				var x1 := hi - g * (hi - lo)
				var x2 := lo + g * (hi - lo)
				var f1 := _piece_error(x1, mirror, rev, fine)
				var f2 := _piece_error(x2, mirror, rev, fine)
				var gave_up := false
				for it in 16:
					if (it == 6 and minf(f1, f2) > 0.004) or (it == 10 and minf(f1, f2) > 0.0015):
						gave_up = true
						break
					if f1 < f2:
						hi = x2
						x2 = x1
						f2 = f1
						x1 = hi - g * (hi - lo)
						f1 = _piece_error(x1, mirror, rev, fine)
					else:
						lo = x1
						x1 = x2
						f1 = f2
						x2 = lo + g * (hi - lo)
						f2 = _piece_error(x2, mirror, rev, fine)
				if gave_up:
					continue
				var sr := (lo + hi) * 0.5
				var j := _arc_at(sr)
				var snap := cum[j] if sr - cum[j] < cum[j + 1] - sr else cum[j + 1]
				if absf(snap - sr) < h and _piece_error(snap, mirror, rev, fine) <= maxf(minf(f1, f2), REPEAT_TOLERANCE * 0.5) + 1e-6:
					sr = snap
				var e1 := _chord_end(sr)
				if e1 == INF:
					continue
				var r := _piece(sr, e1, mirror, rev, true)
				if r.is_empty() or error(r[2], polyline(r), probes, REPEAT_TOLERANCE) > REPEAT_TOLERANCE:
					continue
				var bs: PackedFloat32Array = r[1]
				var n: int = bs.size()
				var first := LinePath.start_tangent(a, r[0][0], bs[0])
				var last := LinePath.end_tangent(a if n == 1 else r[0][n - 2], d, bs[n - 1])
				var cost := pow(ta.angle_to(first), 2.0) + pow(last.angle_to(td), 2.0)
				if cost < best_c:
					best_c = cost
					best = [r[0], r[1]]
				found += 1
			if found >= REPEAT_KEEP or best_c < 1e-4:
				break
		return best

	## Whether `xf` carries the path outside the piece `s0`..`s1` onto stretches of equal curvature,
	## as a symmetry of the closed shape must (a rigid move keeps curvature, and only the piece lands
	## on the gap); two misses are allowed for samples straddling a corner.
	func _twins(xf: Transform2D, s0: float, s1: float) -> bool:
		var step := total / SAMPLES
		var misses := 0
		for i in 16:
			var k := i * SAMPLES / 16
			if k * step > s0 - step and k * step < s1 + step:
				continue
			var y := xf * dense[k]
			var best2 := INF
			var j := -1
			var c := _cell(y)
			for x in range(c.x - 1, c.x + 2):
				for yy in range(c.y - 1, c.y + 2):
					var segs = grid.get(Vector2i(x, yy))
					if segs == null:
						continue
					for m in segs:
						var d2 := y.distance_squared_to(dense[m])
						if d2 < best2:
							best2 = d2
							j = m
			if j < 0 or absf(kap[k] - kap[j]) > 0.03 * maxf(kap[k], kap[j]) + 0.02 / size:
				misses += 1
				if misses > 2:
					return false
		return true

	func _piece_error(s0: float, mirror: bool, rev: bool, probe: PackedVector2Array) -> float:
		if s0 < 0.0 or s0 > total:
			return INF
		var s1 := _chord_end(s0)
		if s1 == INF:
			return INF
		var c := _piece(s0, s1, mirror, rev)
		return error(c[2], c[3], probe)

	## Arc length past `s0` where the chord from `s0` first reaches the gap, within REPEAT_SHARE of
	## the path, or INF.
	func _chord_end(s0: float) -> float:
		var p0 := at(s0)
		var step := total / SAMPLES
		var k := int(ceil(s0 / step + 1e-6))
		var stop := minf(s0 + REPEAT_SHARE * total, total)
		var prev_s := s0
		while k <= SAMPLES and k * step <= stop:
			if dense[k].distance_to(p0) >= gap:
				var lo := prev_s
				var hi := k * step
				if k > 0 and (k - 1) * step > prev_s and dense[k - 1].distance_to(p0) >= gap:
					hi = (k - 1) * step
				for it in 16:
					var m := (lo + hi) * 0.5
					if at(m).distance_to(p0) < gap:
						lo = m
					else:
						hi = m
				return hi
			prev_s = k * step
			k += 2
		return INF

	## The piece from `s0` to `s1` moved onto the gap: [points after `a`, bulges, the move, a
	## polyline of it]; only `exact` builds the arcs ([] when they come out empty).
	func _piece(s0: float, s1: float, mirror: bool, rev: bool, exact := false) -> Array:
		var p0 := at(s0)
		var q := at(s1)
		var from := q - p0
		if mirror:
			from.y = -from.y
		var th := from.angle_to(d - a if not rev else a - d)
		var lin := Transform2D(Vector2(cos(th), sin(th)), Vector2(-sin(th), cos(th)), Vector2.ZERO)
		if mirror:
			lin = lin * Transform2D(Vector2(1, 0), Vector2(0, -1), Vector2.ZERO)
		var xf := Transform2D(lin.x, lin.y, (a if not rev else d) - lin * p0)
		var step := total / SAMPLES
		var poly := PackedVector2Array([xf * p0])
		var k0 := int(ceil(s0 / step + 1e-6))
		var k1 := int(floor(s1 / step - 1e-6))
		var stride := maxi((k1 - k0) / 16, 1)
		for k in range(k0, k1 + 1, stride):
			poly.append(xf * dense[k])
		poly.append(xf * q)
		if not exact:
			return [null, null, xf, poly]
		var ps := PackedVector2Array()
		var bs := PackedFloat32Array()
		var lo_k := _arc_at(s0)
		var hi_k := _arc_at(s1)
		for k in range(lo_k, hi_k + 1):
			var f0 := 0.0 if k > lo_k else (s0 - cum[k]) / maxf(cum[k + 1] - cum[k], 1e-9)
			var f1 := 1.0 if k < hi_k else (s1 - cum[k]) / maxf(cum[k + 1] - cum[k], 1e-9)
			if (f1 - f0) * (cum[k + 1] - cum[k]) < 1e-3:
				continue
			ps.append(xf * LinePath.arc_point(pts[k], pts[k + 1], bul[k], f1))
			bs.append(tan(atan(bul[k]) * (f1 - f0)) * (-1.0 if mirror else 1.0))
		if ps.is_empty():
			return []
		if rev:
			var rp := PackedVector2Array()
			var rb := PackedFloat32Array()
			for k in range(ps.size() - 2, -1, -1):
				rp.append(ps[k])
			rp.append(d)
			for k in range(bs.size() - 1, -1, -1):
				rb.append(-bs[k])
			ps = rp
			bs = rb
		ps[ps.size() - 1] = d
		return [ps, bs, xf, poly]

	func _arc_at(s: float) -> int:
		var lo := 0
		var hi := cum.size() - 1
		while hi - lo > 1:
			var m := (lo + hi) >> 1
			if cum[m] <= s:
				lo = m
			else:
				hi = m
		return lo
