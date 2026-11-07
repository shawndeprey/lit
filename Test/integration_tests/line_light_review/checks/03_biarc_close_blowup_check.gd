extends "res://Test/integration_tests/line_light_review/checks/review_section.gd"

## Issue 3: close_mode BIARC can produce an enormous loop, which coarsens every shadow.
##
## LinePath.biarc() (line_path.gd) uses the equal-distance biarc: with k = 1 - t0.t1,
## dl = (sqrt(vt^2 + 2k|v|^2) - vt) / 2k. When the path's end tangents are nearly
## parallel and point away from the gap (vt = v.(t0+t1) < 0), dl grows like |vt| / k:
## 200 px gap, tangents 1 deg apart -> the joint lands ~11,800 px away. The only guard is
## |bulge| <= 1e4, but both bulges stay near -1 (two half circles), so it never trips.
## The loop is lit like any other part of the light, and its bounds go everywhere:
## path_rect() never culls, and world_sdf.gd merges the light's path_rect_in() into the
## world-SDF window (shadow-casting lights), doubling the SDF texel until the window
## covers it - so every shadow in the scene gets coarser, and small occluders vanish.
## SYMMETRIC (the default) is protected by its size penalty; STRAIGHT is the reference.
##
## Exhibit: an open S-curve (gap 200 px between its ends, tangents pointing away from the
## gap) on a shadow-casting line light, top left. Bottom right, unrelated to it, a point
## light with Raymarched shadows behind a 40 px box and an 8 px pillar. The run steps
## close_mode / tangent separation and records the light's bounds, the world-SDF texel,
## and the point light's shadows. The minimap (top right) draws the fitted closed chain.

const LIGHT_POS := Vector2(420, 330)
const GAP := 200.0
const BASE_DEG := 120.0
const PT_POS := Vector2(900, 760)
const BOX_POS := Vector2(900, 670)       # 40x40 box above the point light
const PILLAR_POS := Vector2(1010, 760)   # 8 px wide pillar to its right
const BEHIND_BOX := Vector2(900, 590)
const BEHIND_PILLAR := Vector2(1090, 760)
const MINIMAP := Rect2(1000, 90, 360, 360)

var _line: LitLineLight2D
var _path: Path2D
var _map: Node2D


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	floor_receiver(Rect2(40, 60, 1340, 1000))
	_map = group("Minimap")
	_line = line_light(LIGHT_POS, 0.0, 60.0, 0.7, 40.0)
	_line.shadow_enabled = true
	_line.shadow_algorithm = ALGO.RAYMARCHED
	_path = Path2D.new()
	_path.curve = _curve(1.0)
	_line.add_child(_path)
	_line.closed = true
	var pt := point_light(PT_POS, 300.0, 0.9, Color.WHITE, 60.0)
	pt.shadow_enabled = true
	pt.shadow_algorithm = ALGO.RAYMARCHED
	var props := group("Occluders")
	occluder(BOX_POS, Vector2(40, 40), props)
	occluder(PILLAR_POS, Vector2(8, 60), props)
	label("S-curve, 200 px gap; close_mode steps STRAIGHT -> SYMMETRIC -> BIARC", LIGHT_POS + Vector2(-360, -250), 13)
	label("unrelated point light: 40 px box (above) and 8 px pillar (right)", PT_POS + Vector2(-300, 230), 13)
	label("minimap: the closed chain, whole extent", MINIMAP.position + Vector2(0, -18), 12)
	var a := LIGHT_POS + Vector2(-GAP * 0.5, 0)
	var off_curve := a + Vector2.from_angle(deg_to_rad(BASE_DEG)) * 200.0   # along the end tangent, past the curve

	var c := "biarc_close"
	var rows := []
	for step in [["STRAIGHT", LitLineLight2D.CloseMode.STRAIGHT, 1.0],
			["SYMMETRIC", LitLineLight2D.CloseMode.SYMMETRIC, 1.0],
			["BIARC 10 deg", LitLineLight2D.CloseMode.BIARC, 10.0],
			["BIARC 1 deg", LitLineLight2D.CloseMode.BIARC, 1.0],
			["BIARC 0.1 deg", LitLineLight2D.CloseMode.BIARC, 0.1]]:
		_path.curve = _curve(step[2])
		_line.close_mode = step[1]
		_line.is_curved()   # refit now
		var img := await settle_capture(8)
		var r := _line.path_rect()
		var row := {"name": step[0], "rect": r, "texel": _sdf_texel(), "img": img,
				"off_curve": lum(img, off_curve), "box": light_share_pt(img, BEHIND_BOX),
				"pillar": light_share_pt(img, BEHIND_PILLAR)}
		rows.append(row)
		say("SUITE INFO %-13s path_rect %6.0f x %6.0f px   world-SDF texel %6.2f px   floor 200 px past the curve's end %.3f   behind box %.3f   behind pillar %.3f" % [
				step[0], r.size.x, r.size.y, row.texel, row.off_curve, row.box, row.pillar])
	var ref: Dictionary = rows[0]
	var ref_size := maxf(ref.rect.size.x, ref.rect.size.y)
	check_lt(c, "(reference) STRAIGHT close: bounds stay near the 200 px path", ref_size, 600.0)
	check_lt(c, "(reference) SYMMETRIC close: bounds stay near the path", maxf(rows[1].rect.size.x, rows[1].rect.size.y), 600.0)
	for i in [2, 3, 4]:
		var row: Dictionary = rows[i]
		var size := maxf(row.rect.size.x, row.rect.size.y)
		check_lt(c, "%s: the close of a 200 px gap stays under 2000 px" % row.name, size, 2000.0)
	var cs := "scene_shadows"
	check_lt(cs, "(reference) STRAIGHT: the 8 px pillar shadows the floor behind it", ref.pillar, 0.2)
	check_lt(cs, "(reference) STRAIGHT: the 40 px box shadows the floor behind it", ref.box, 0.2)
	for i in [3, 4]:
		var row: Dictionary = rows[i]
		check_approx(cs, "%s: the world-SDF texel is unchanged by a line light's close mode" % row.name,
				ref.texel, row.texel, 0.01)
		check_lt(cs, "%s: the 8 px pillar still shadows the floor behind it" % row.name, row.pillar, 0.2)
		check_lt(cs, "%s: the 40 px box still shadows the floor behind it" % row.name, row.box, 0.2)
	check_approx("lit_area", "(reference) STRAIGHT: the floor 200 px past the curve's end is unlit", AMBIENT, ref.off_curve, 0.02)
	check_approx("lit_area", "BIARC 1 deg: the floor 200 px past the curve's end is unlit", AMBIENT, rows[3].off_curve, 0.02)

	# The joint, straight from the math (no node involved).
	var t_end := Vector2.from_angle(deg_to_rad(BASE_DEG))
	for sep in [10.0, 1.0, 0.1]:
		var bi: Array = LitLineLight2D.LinePathScript.biarc(Vector2(-GAP * 0.5, 0), t_end, Vector2(GAP * 0.5, 0),
				Vector2.from_angle(deg_to_rad(BASE_DEG + sep)))
		say("SUITE INFO LinePath.biarc, 200 px gap, tangents %.1f deg apart: joint at (%.0f, %.0f), bulges %.3f / %.3f" % [
				sep, bi[0].x, bi[0].y, bi[1], bi[2]])

	var worst: Dictionary = rows[4]
	repro("3 BIARC blow-up", maxf(rows[3].rect.size.x, rows[3].rect.size.y) > 2000.0,
			"path_rect STRAIGHT %.0f px, BIARC 10 deg %.0f, 1 deg %.0f, 0.1 deg %.0f; world-SDF texel %.2f -> %.2f -> %.2f px; behind the 8 px pillar %.2f -> %.2f -> %.2f (light share)" % [
			ref_size, maxf(rows[2].rect.size.x, rows[2].rect.size.y), maxf(rows[3].rect.size.x, rows[3].rect.size.y),
			maxf(worst.rect.size.x, worst.rect.size.y), ref.texel, rows[3].texel, worst.texel,
			ref.pillar, rows[3].pillar, worst.pillar])

	# Showcase: BIARC 1 deg live (its two arcs run off screen down-left), insets of the
	# point light's shadows under STRAIGHT and BIARC 0.1 deg, and the minimap.
	_path.curve = _curve(1.0)
	_line.close_mode = LitLineLight2D.CloseMode.BIARC
	_line.is_curved()
	_draw_minimap()
	_inset(ref.img, "STRAIGHT close: point light shadows", Vector2(1000, 520))
	_inset(worst.img, "BIARC 0.1 deg: same shadows, SDF texel %.0f px" % worst.texel, Vector2(1000, 790))
	await frames(6)


## Open cubic S-curve from (+GAP/2, 0) to (-GAP/2, 0) in light-local space. It leaves its
## start along BASE_DEG + sep and arrives at its end along BASE_DEG, both pointing away
## from the gap between its ends.
func _curve(sep_deg: float) -> Curve2D:
	var k := 120.0
	var curve := Curve2D.new()
	curve.add_point(Vector2(GAP * 0.5, 0), Vector2.ZERO, Vector2.from_angle(deg_to_rad(BASE_DEG + sep_deg)) * k)
	curve.add_point(Vector2(-GAP * 0.5, 0), -Vector2.from_angle(deg_to_rad(BASE_DEG)) * k, Vector2.ZERO)
	return curve


func _sdf_texel() -> float:
	var mgr := get_node_or_null("/root/LitManager")
	if mgr == null:
		return -1.0
	return float(mgr._registry._world_sdf._wsdf_texel)


## Light share relative to the point light's own contribution: (lum - ambient) over the
## unshadowed level at the probe's mirror image through the light (nothing occludes it).
func light_share_pt(img: Image, p: Vector2) -> float:
	var mirror := PT_POS - (p - PT_POS)
	var open := lum(img, mirror, 1) - AMBIENT
	return (lum(img, p, 1) - AMBIENT) / maxf(open, 0.001)


func _draw_minimap() -> void:
	var chain = _line.path_chain()
	var inv := _line.path_fit_xf().affine_inverse()
	var pts := PackedVector2Array()
	for i in chain.bulges.size():
		for k in 24:
			pts.append(inv * LitLineLight2D.LinePathScript.arc_point(chain.points[i], chain.points[i + 1], chain.bulges[i], float(k) / 24.0))
	pts.append(inv * chain.points[chain.points.size() - 1])
	var bb := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bb = bb.expand(p)
	var s := minf(MINIMAP.size.x / maxf(bb.size.x, 1.0), MINIMAP.size.y / maxf(bb.size.y, 1.0)) * 0.9
	var mapped := PackedVector2Array()
	for p in pts:
		mapped.append(MINIMAP.get_center() + (p - bb.get_center()) * s)
	overlay_line(PackedVector2Array([MINIMAP.position, MINIMAP.position + Vector2(MINIMAP.size.x, 0),
			MINIMAP.end, MINIMAP.position + Vector2(0, MINIMAP.size.y), MINIMAP.position]), Color(0.5, 0.5, 0.55), 1.0, _map)
	overlay_line(mapped, Color(1.0, 0.8, 0.2), 2.0, _map)
	# The authored 200 px S-curve, to scale: the small knot at the loop's start.
	label("BIARC 1 deg: loop %.0f x %.0f px (the authored curve is the knot)" % [bb.size.x, bb.size.y],
			MINIMAP.position + Vector2(0, MINIMAP.size.y + 4), 12, Color(0.85, 0.85, 0.9), _map)


func _inset(img: Image, title: String, at: Vector2) -> void:
	var c := to_px(PT_POS + Vector2(60, -60), img)
	var crop := img.get_region(Rect2i(int(c.x) - 180, int(c.y) - 120, 360, 240))
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(crop)
	spr.centered = false
	spr.position = at
	spr.scale = Vector2(0.9, 0.9)
	spr.z_index = 40
	add_child(spr)
	label(title, at + Vector2(0, -18), 12)
