extends LitSuiteSection

## Shared helpers for the PR #107 review repro scenes (Test/integration_tests/line_light_review).
##
## Each scene in this folder reproduces one issue found while reviewing LitLineLight2D.
## They run standalone on the test-suite harness (HUD, pixel probes, report card):
##
##   godot --path . res://Test/integration_tests/line_light_review/checks/<scene>_check.tscn
##   godot --path . res://Test/integration_tests/line_light_review/checks/<scene>_check.tscn -- quit=on
##
## Every check states the CORRECT behaviour, so while the issue is present its checks
## FAIL and the run ends on "SUITE RESULT FAIL"; once fixed they pass and the scene is a
## regression test. Reference checks (marked "(reference)") show the comparison case
## behaving correctly and should pass either way. Each scene also prints one line
##   REPRO <id>: REPRODUCED | NOT REPRODUCED - <numbers>
## so a console run can be read at a glance.
##
## These scenes are not in the suite's SECTIONS list on purpose: the default suite run
## stays green while the issues are open.

const AMBIENT := 0.1
const ALGO := LitShaderLibrary.ShadowAlgorithm


func line_light(pos: Vector2, length: float, p_range: float, energy: float, height: float,
		parent: Node = null) -> LitLineLight2D:
	var l := LitLineLight2D.new()
	l.position = pos
	l.length = length
	l.range = p_range
	l.energy = energy
	l.height = height
	(parent if parent != null else self).add_child(l)
	return l


## A round LightOccluder2D of `radius` px centred on `pos` (local to `parent`).
func disc_occluder(pos: Vector2, radius: float, parent: Node = null, sides := 32) -> LightOccluder2D:
	var o := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var pts := PackedVector2Array()
	for k in sides:
		pts.append(Vector2.from_angle(TAU * float(k) / float(sides)) * radius)
	poly.polygon = pts
	o.occluder = poly
	o.position = pos
	(parent if parent != null else self).add_child(o)
	return o


## An unlit overlay line (Line2D ignores Lit's lighting), drawn above the exhibits.
func overlay_line(points: PackedVector2Array, color: Color, width := 1.0, parent: Node = null) -> Line2D:
	var ln := Line2D.new()
	ln.points = points
	ln.default_color = color
	ln.width = width
	ln.z_index = 50
	(parent if parent != null else self).add_child(ln)
	return ln


## An unlit overlay circle outline.
func overlay_circle(center: Vector2, radius: float, color: Color, width := 1.0, parent: Node = null) -> Line2D:
	var pts := PackedVector2Array()
	for k in 33:
		pts.append(center + Vector2.from_angle(TAU * float(k) / 32.0) * radius)
	return overlay_line(pts, color, width, parent)


## The light's share left at `p` relative to an unshadowed capture: (lum - ambient) over
## (lum_open - ambient). 1 = the occluder changed nothing, 0 = fully shadowed.
func light_share(img: Image, img_open: Image, p: Vector2, half := 1) -> float:
	var open := lum(img_open, p, half) - AMBIENT
	if open <= 0.001:
		return 1.0
	return (lum(img, p, half) - AMBIENT) / open


## Prints the one-line verdict for the scene.
func repro(id: String, reproduced: bool, detail: String) -> void:
	say("REPRO %s: %s - %s" % [id, "REPRODUCED" if reproduced else "NOT REPRODUCED", detail])
	status = "%s: %s" % [id, "REPRODUCED" if reproduced else "not reproduced"]


## Captures after the world SDF has caught up with occluder edits.
func settle_capture(n := 4) -> Image:
	await frames(n)
	return await capture()
