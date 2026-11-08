@tool
extends RefCounted

## Starter paths for LitLineLight2D's "Add Path" button: Path2D curves one unit wide,
## centered on the light and scaled to its length. Curves are built from circular arcs,
## which the light shades as one arc each. The closed shapes repeat their first point
## last, so the Path2D gizmo draws the whole loop, and light with `closed` on.

const CATEGORIES := [
	["Curves", ["Gentle Curve", "S Curve", "Arch", "Wave", "Garland", "Spiral"]],
	["Lines", ["Corner", "Frame", "Zigzag"]],
	["Shapes", ["Circle", "Capsule", "Rounded Rectangle", "Square", "Triangle", "Hexagon", "Star", "Heart"]],
]

static func names() -> PackedStringArray:
	var out := PackedStringArray()
	for cat in CATEGORIES:
		out.append_array(cat[1])
	return out

static func is_closed(shape: String) -> bool:
	return shape in CATEGORIES[2][1]

## A Path2D named after `shape`, its curve `size` px wide.
static func make_path(shape: String, size: float) -> Path2D:
	var path := Path2D.new()
	path.name = shape.replace(" ", "")
	path.curve = curve(shape, size)
	return path

static func curve(shape: String, size: float) -> Curve2D:
	var pts := points(shape)
	var unit := Curve2D.new()
	for p in pts:
		unit.add_point(p[0], p[1], p[2])
	var box := Rect2()
	if not pts.is_empty():
		var t := unit.tessellate()
		box = Rect2(t[0], Vector2.ZERO)
		for q in t:
			box = box.expand(q)
	var c := Curve2D.new()
	for p in pts:
		c.add_point((p[0] - box.get_center()) * size, p[1] * size, p[2] * size)
	return c

## [position, in, out] triples, one unit wide.
static func points(shape: String) -> Array:
	match shape:
		"Gentle Curve":
			return _bow(Vector2(-0.5, 0), Vector2(0.5, 0), 0.12)
		"S Curve":
			return _join([_bow(Vector2(-0.5, 0), Vector2.ZERO, -0.18), _bow(Vector2.ZERO, Vector2(0.5, 0), 0.18)])
		"Arch":
			return _bow(Vector2(-0.5, 0), Vector2(0.5, 0), -0.5)
		"Wave":
			var parts := []
			for i in 4:
				parts.append(_bow(Vector2(-0.5 + i * 0.25, 0), Vector2(-0.25 + i * 0.25, 0), -0.08 if i % 2 == 0 else 0.08))
			return _join(parts)
		"Garland":
			var parts := []
			for i in 3:
				parts.append(_bow(Vector2(-0.5 + i / 3.0, 0), Vector2(-0.5 + (i + 1) / 3.0, 0), 0.1))
			return _join(parts)
		"Spiral":
			# Semicircles growing by d, their centers alternating between 0 and d.
			var d := 1.0 / 7.0
			var parts := []
			for i in 4:
				parts.append(_arc(Vector2(d * (i % 2), 0), d * (0.5 + i), PI * (i % 2), PI))
			return _join(parts)
		"Corner":
			return _polyline([Vector2(-0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)])
		"Frame":
			return _polyline([Vector2(-0.5, 0.5), Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5)])
		"Zigzag":
			var pts := []
			for i in 7:
				pts.append(Vector2(-0.5 + i / 6.0, 0.1 if i % 2 else -0.1))
			return _polyline(pts)
		"Circle":
			return _arc(Vector2.ZERO, 0.5, 0.0, TAU)
		"Capsule":
			return _rounded_rect(0.5, 0.2, 0.2)
		"Rounded Rectangle":
			return _rounded_rect(0.5, 0.3, 0.12)
		"Square":
			return _polygon([Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)])
		"Triangle":
			var h := sqrt(3.0) / 4.0
			return _polygon([Vector2(0, -h), Vector2(0.5, h), Vector2(-0.5, h)])
		"Hexagon":
			var pts := []
			for i in 6:
				pts.append(Vector2.from_angle(i * PI / 3.0) * 0.5)
			return _polygon(pts)
		"Star":
			var pts := []
			var r := 0.5 / cos(PI / 10.0)
			for i in 10:
				pts.append(Vector2.from_angle(-PI / 2.0 + i * PI / 5.0) * (r if i % 2 == 0 else r * 0.382))
			return _polygon(pts)
		"Heart":
			# Two overlapping lobes from the notch, each running into a straight side
			# tangent to it down to the tip.
			var r := 0.28
			var c := Vector2(-0.22, 0)
			var notch := Vector2(0, -sqrt(r * r - c.x * c.x))
			var tip := Vector2(0, 0.62)
			var a0 := (notch - c).angle()
			var a1 := (tip - c).angle() + acos(r / c.distance_to(tip)) - TAU
			var lobe := _arc(c, r, a0, a1 - a0)
			var mirror := []
			for i in range(lobe.size() - 1, -1, -1):
				var p: Array = lobe[i]
				mirror.append([Vector2(-p[0].x, p[0].y), Vector2(-p[2].x, p[2].y), Vector2(-p[1].x, p[1].y)])
			return _join([lobe, _polyline([lobe[-1][0], tip, mirror[0][0]]), mirror])
	return []

## A circular arc around `c` of radius `r` from angle `a0` through `sweep`, as Bezier
## pieces of at most 90 degrees.
static func _arc(c: Vector2, r: float, a0: float, sweep: float) -> Array:
	var n := maxi(ceili(absf(sweep) / (PI / 2.0) - 1e-6), 1)
	var step := sweep / n
	var h := 4.0 / 3.0 * tan(step / 4.0) * r
	var out := []
	for i in n + 1:
		var a := a0 + step * i
		var t := Vector2(-sin(a), cos(a)) * h
		out.append([c + Vector2.from_angle(a) * r, -t if i > 0 else Vector2.ZERO, t if i < n else Vector2.ZERO])
	return out

## The circular arc from `a` to `b` whose middle sits `sag` off the chord, toward the
## chord's right (down for a left-to-right chord).
static func _bow(a: Vector2, b: Vector2, sag: float) -> Array:
	var half := a.distance_to(b) / 2.0
	var n := (b - a).normalized().orthogonal() * -signf(sag)
	var s := absf(sag)
	var r := (half * half + s * s) / (2.0 * s)
	var c := (a + b) / 2.0 + n * (s - r)
	var a0 := (a - c).angle()
	var sweep := wrapf((b - c).angle() - a0, -PI, PI)
	if (c + Vector2.from_angle(a0 + sweep / 2.0) * r).distance_to((a + b) / 2.0 + n * s) > 1e-4:
		sweep -= signf(sweep) * TAU
	return _arc(c, r, a0, sweep)

## Point lists joined end to start: coincident points merge, keeping the first one's in
## handle and the last nonzero out handle.
static func _join(parts: Array) -> Array:
	var out := []
	for part in parts:
		for p in part:
			if not out.is_empty() and out[-1][0].distance_to(p[0]) < 1e-6:
				out[-1] = [out[-1][0], out[-1][1], p[2] if p[2] != Vector2.ZERO else out[-1][2]]
			else:
				out.append(p)
	return out

static func _polyline(pts: Array) -> Array:
	var out := []
	for p in pts:
		out.append([p, Vector2.ZERO, Vector2.ZERO])
	return out

static func _polygon(pts: Array) -> Array:
	return _join([_polyline(pts), _polyline([pts[0]])])

## A rectangle of half extents (hw, hh) with corner radius r, from the start of its top edge.
static func _rounded_rect(hw: float, hh: float, r: float) -> Array:
	var x := hw - r
	var y := hh - r
	return _join([
		_polyline([Vector2(-x, -hh), Vector2(x, -hh)]), _arc(Vector2(x, -y), r, -PI / 2.0, PI / 2.0),
		_polyline([Vector2(hw, -y), Vector2(hw, y)]), _arc(Vector2(x, y), r, 0.0, PI / 2.0),
		_polyline([Vector2(x, hh), Vector2(-x, hh)]), _arc(Vector2(-x, y), r, PI / 2.0, PI / 2.0),
		_polyline([Vector2(-hw, y), Vector2(-hw, -y)]), _arc(Vector2(-x, -y), r, PI, PI / 2.0),
	])
