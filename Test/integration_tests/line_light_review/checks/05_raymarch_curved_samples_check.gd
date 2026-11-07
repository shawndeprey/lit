extends "res://Test/integration_tests/line_light_review/checks/review_section.gd"

## Issue 5: a curved LitLineLight2D on RAYMARCHED shadows marches `shadow_samples` full
## hard marches per pixel, while the inspector hides `shadow_samples` on RAYMARCHED and
## the class doc says Raymarched "casts one hard march".
##
## lit_shade.gdshaderinc: a curved line on algorithm 0 calls lit_shadow_path_hard() with
## n = round(t7.y), the light's shadow_samples, and lit_shadow_path_hard()
## (lit_shadow_march.gdshaderinc) runs one full lit_shadow() per shadow chord with no gate.
## LitShaderLibrary.validate_light_property() hides shadow_samples unless the algorithm is
## STOCHASTIC (LitLineLight2D re-shows it for CONE_TRACED only), so on RAYMARCHED the
## setting that sets the cost - default 8 - is invisible and cannot be found.
##
## Exhibit: 12 curved lights (S-curves) over a floor with occluders, Raymarched shadows.
## The run measures GPU frame time at shadow_samples 1, 8 and 32 for the curved lights,
## then for 12 straight lines and 12 point lights at the same spots (controls), and
## captures the curved lights at 1 and 32 to see whether the hidden setting also changes
## the picture.

const GRID_COLS := 4
const GRID_ROWS := 3
const AREA := Rect2(40, 60, 1320, 960)
const RANGE := 150.0
const WARM_FRAMES := 30
const MEASURE_FRAMES := 90
const SAMPLE_SET := [1, 8, 32]

var _curved: Array[LitLineLight2D] = []
var _straight: Array[LitLineLight2D] = []
var _points: Array[LitPointLight2D] = []


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	floor_receiver(AREA)
	var props := group("Occluders")
	var cell := Vector2(AREA.size.x / GRID_COLS, AREA.size.y / GRID_ROWS)
	for r in GRID_ROWS:
		for col in GRID_COLS:
			var c := AREA.position + cell * Vector2(col + 0.5, r + 0.5)
			var cl := line_light(c, 0.0, RANGE, 0.7, 60.0)
			var path := Path2D.new()
			var curve := Curve2D.new()
			curve.add_point(Vector2(-110, 0), Vector2.ZERO, Vector2(60, -90))
			curve.add_point(Vector2(110, 0), Vector2(-60, 90), Vector2.ZERO)
			path.curve = curve
			cl.add_child(path)
			_curved.append(cl)
			var sl := line_light(c, 220.0, RANGE, 0.7, 60.0)
			_straight.append(sl)
			var pl := point_light(c, RANGE, 0.7, Color.WHITE, 60.0)
			_points.append(pl)
			occluder(c + Vector2(-40, 70), Vector2(30, 30), props)
			occluder(c + Vector2(50, -70), Vector2(20, 40), props)
	for l in _curved + _straight:
		l.shadow_enabled = true
		l.shadow_algorithm = ALGO.RAYMARCHED
	for l in _points:
		l.shadow_enabled = true
		l.shadow_algorithm = ALGO.RAYMARCHED

	# Inspector: is shadow_samples shown on a curved RAYMARCHED line light?
	var c0 := "inspector"
	var probe := _curved[0]
	var shown := false
	for prop in probe.get_property_list():
		if prop.name == "shadow_samples":
			shown = prop.usage & PROPERTY_USAGE_EDITOR != 0
	check_true(c0, "(reference) the light is curved", probe.is_curved())
	check_true(c0, "shadow_samples is shown in the inspector on a curved RAYMARCHED line light (it sets the cost)", shown)

	# GPU cost per light kind and sample count.
	var prev_vsync := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var results := {}
	for kind in ["curved", "straight", "point"]:
		_enable_only(kind)
		for n in SAMPLE_SET:
			for l in _curved + _straight:
				l.shadow_samples = n
			for l in _points:
				l.shadow_samples = n
			results["%s_%d" % [kind, n]] = await _gpu_ms(vp)
		say("SUITE INFO %-8s RAYMARCHED GPU ms at shadow_samples 1 / 8 / 32: %.2f / %.2f / %.2f" % [
				kind, results["%s_1" % kind], results["%s_8" % kind], results["%s_32" % kind]])
	var c1 := "gpu_cost"
	var curved_ratio: float = results.curved_32 / maxf(results.curved_1, 0.01)
	var straight_ratio: float = results.straight_32 / maxf(results.straight_1, 0.01)
	var point_ratio: float = results.point_32 / maxf(results.point_1, 0.01)
	check_lt(c1, "(reference) straight lines: shadow_samples 32 costs about what 1 does on RAYMARCHED", straight_ratio, 1.25)
	check_lt(c1, "(reference) point lights: shadow_samples 32 costs about what 1 does on RAYMARCHED", point_ratio, 1.25)
	check_lt(c1, "curved lines: shadow_samples 32 costs about what 1 does on RAYMARCHED (\"one hard march\")", curved_ratio, 1.25)
	check_lt(c1, "curved lines at the default 8 samples cost under 3x a straight line on RAYMARCHED",
			results.curved_8 / maxf(results.straight_8, 0.01), 3.0)

	# Does the hidden setting change the picture too?
	_enable_only("curved")
	for l in _curved:
		l.shadow_samples = 1
	var img1 := await settle_capture(6)
	for l in _curved:
		l.shadow_samples = 32
	var img32 := await settle_capture(6)
	var diff := image_diff(img1, img32, AREA, 2)
	say("SUITE INFO curved RAYMARCHED, shadow_samples 1 vs 32: mean abs pixel difference %.4f" % diff)
	check_lt("look", "curved lines: the hidden shadow_samples does not change a RAYMARCHED shadow's look", diff, 0.002)
	DisplayServer.window_set_vsync_mode(prev_vsync)

	repro("5 raymarched curved samples", not shown and curved_ratio > 1.5,
			"shadow_samples hidden on RAYMARCHED: %s; GPU ms at samples 1/8/32: curved %.2f/%.2f/%.2f (x%.1f), straight %.2f/%.2f/%.2f (x%.2f), point %.2f/%.2f/%.2f (x%.2f); look changes 1 vs 32: %.4f" % [
			str(not shown), results.curved_1, results.curved_8, results.curved_32, curved_ratio,
			results.straight_1, results.straight_8, results.straight_32, straight_ratio,
			results.point_1, results.point_8, results.point_32, point_ratio, diff])
	# Leave the curved set on the default 8 for eyeballing.
	for l in _curved:
		l.shadow_samples = 8
	label("12 curved line lights, RAYMARCHED shadows, shadow_samples 8 (hidden in the inspector)", Vector2(52, 74), 13)


func _enable_only(kind: String) -> void:
	for l in _curved:
		l.enabled = kind == "curved"
	for l in _straight:
		l.enabled = kind == "straight"
	for l in _points:
		l.enabled = kind == "point"


func _gpu_ms(vp: RID) -> float:
	await frames(WARM_FRAMES)
	var total := 0.0
	for k in MEASURE_FRAMES:
		await RenderingServer.frame_post_draw
		total += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return total / float(MEASURE_FRAMES)
