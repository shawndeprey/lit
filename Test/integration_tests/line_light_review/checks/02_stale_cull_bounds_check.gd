extends "res://Test/integration_tests/line_light_review/checks/review_section.gd"

## Issue 2: an off-screen curved line light does not notice its Path2D moving or its
## curve being swapped, so it can stay culled after its curve comes on screen.
##
## At runtime the light cull (light_cache.gd cull_visible) tests a curved light against
## its chain bounds mirrored in `_prects`. The mirror is rewritten only for lights in
## `_pending` (light setters, Curve2D.changed) or on a full cache rebuild. Moving the
## Path2D child, or assigning a new Curve2D to `path.curve`, emits nothing; the change is
## only noticed by polling in LitLineLight2D._refresh_path(), which runs when the light is
## packed, i.e. when it is already visible. So a culled light keeps its stale bounds.
##
## It is not literally forever: the cache rebuilds whenever ANY node enters or leaves the
## tree (light_cache.gd _on_tree_changed), and the rebuild re-reads the path. In a busy
## game that happens often; in a static scene the light stays dark indefinitely.
##
## Row 1: the light sits at x=5000 (far off screen) with a ring Path2D around it. After a
## few frames the Path2D child is moved 4600 px left, so the ring lies on screen at the
## dashed outline. It stays dark for 120 frames with no tree changes; adding one plain
## Node anywhere in the tree brings it back.
## Row 2: the same, but a new Curve2D (already offset on screen) is assigned to
## `path.curve`; a no-op write to a notifying property (range = range) brings it back.

const OFF_X := 5000.0
const SHIFT := 4600.0
const RING_R := 100.0
const RANGE := 120.0
const ENERGY := 0.8
const ROWS := [300.0, 780.0]
const WAIT_FRAMES := 120

var _insets_x := 620.0


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	floor_receiver(Rect2(40, 60, 1340, 1000))
	var on_x := OFF_X - SHIFT   # 400: where the ring lands on screen

	# Row 1: move the Path2D child.
	var y1: float = ROWS[0]
	var l1 := line_light(Vector2(OFF_X, y1), 0.0, RANGE, ENERGY, 60.0)
	var p1 := Path2D.new()
	p1.curve = _ring(Vector2.ZERO)
	l1.add_child(p1)
	l1.closed = true
	_expected_outline(Vector2(on_x, y1))
	label("row 1: LitLineLight2D at x=%d (off screen); its Path2D child is moved %d px left, so the ring belongs at the dashed circle" % [OFF_X, SHIFT],
			Vector2(52, y1 + 228), 13)

	# Row 2: swap the curve resource.
	var y2: float = ROWS[1]
	var l2 := line_light(Vector2(OFF_X, y2), 0.0, RANGE, ENERGY, 60.0)
	var p2 := Path2D.new()
	p2.curve = _ring(Vector2.ZERO)
	l2.add_child(p2)
	l2.closed = true
	_expected_outline(Vector2(on_x, y2))
	label("row 2: same light; a new Curve2D already offset %d px left is assigned to path.curve" % SHIFT,
			Vector2(52, y2 + 228), 13)

	await frames(8)
	var img := await capture()
	var c := "setup"
	check_true(c, "(reference) both lights are curved", l1.is_curved() and l2.is_curved())
	check_approx(c, "(reference) row 1: nothing lit at the dashed circle before the move", AMBIENT,
			lum(img, Vector2(on_x + RING_R - 15.0, y1)), 0.02)
	check_approx(c, "(reference) row 2: nothing lit at the dashed circle before the swap", AMBIENT,
			lum(img, Vector2(on_x + RING_R - 15.0, y2)), 0.02)

	# The edits. No node may enter or leave the tree from here until the heal step.
	p1.position = Vector2(-SHIFT, 0)
	p2.curve = _ring(Vector2(-SHIFT, 0))
	await frames(WAIT_FRAMES)
	var stuck := await capture()
	var r1 := lum(stuck, Vector2(on_x + RING_R - 15.0, y1))
	var r2 := lum(stuck, Vector2(on_x + RING_R - 15.0, y2))
	c = "path_moved"
	check_gt(c, "row 1: %d frames after moving the Path2D on screen, the ring lights the floor" % WAIT_FRAMES, r1, AMBIENT, 0.1)
	c = "curve_swapped"
	check_gt(c, "row 2: %d frames after assigning an on-screen curve, the ring lights the floor" % WAIT_FRAMES, r2, AMBIENT, 0.1)

	# Heal row 2 first with a write to one of the light's notifying properties (range has a
	# setter that marks the light pending; energy does not), and check row 1 is still dark.
	# Then heal row 1 with an unrelated tree change (which rebuilds the whole cache).
	l2.range = l2.range
	await frames(6)
	var half_healed := await capture()
	var h2 := lum(half_healed, Vector2(on_x + RING_R - 15.0, y2))
	var still1 := lum(half_healed, Vector2(on_x + RING_R - 15.0, y1))
	check_gt("curve_swapped", "(reference) row 2: after `range = range`, the ring is lit", h2, AMBIENT, 0.1)
	check_approx("path_moved", "(reference) row 1: still dark after row 2's property write", AMBIENT, still1, 0.02)
	add_child(Node.new())
	await frames(6)
	var healed := await capture()
	var h1 := lum(healed, Vector2(on_x + RING_R - 15.0, y1))
	check_gt("path_moved", "(reference) row 1: after one plain Node joins the tree, the ring is lit", h1, AMBIENT, 0.1)

	_inset(stuck, Vector2(on_x, y1), "row 1, %d frames after the move (stuck)" % WAIT_FRAMES)
	_inset(stuck, Vector2(on_x, y2), "row 2, %d frames after the swap (stuck)" % WAIT_FRAMES)
	label("left: live view after the heal step   right: captured while stuck", Vector2(620, 1030), 13)
	var reproduced := r1 <= AMBIENT + 0.02 or r2 <= AMBIENT + 0.02
	repro("2 stale cull bounds", reproduced,
			"ring lum after %d frames: moved Path2D %.3f, swapped curve %.3f (ambient %.2f); after heal %.3f / %.3f" % [
			WAIT_FRAMES, r1, r2, AMBIENT, h1, h2])


## A closed ring of radius RING_R around `c` (light-local), four cubic quarters.
func _ring(c: Vector2) -> Curve2D:
	var k := RING_R * 0.5523
	var curve := Curve2D.new()
	var pts := [Vector2(RING_R, 0), Vector2(0, RING_R), Vector2(-RING_R, 0), Vector2(0, -RING_R)]
	var tans := [Vector2(0, k), Vector2(-k, 0), Vector2(0, -k), Vector2(k, 0)]
	for i in 4:
		curve.add_point(c + pts[i], -tans[i], tans[i])
	curve.add_point(c + pts[0], -tans[0], Vector2.ZERO)
	return curve


func _expected_outline(center: Vector2) -> void:
	for k in 24:
		var a0 := TAU * float(k) / 24.0
		var a1 := a0 + TAU / 48.0
		overlay_line(PackedVector2Array([center + Vector2.from_angle(a0) * RING_R,
				center + Vector2.from_angle(a1) * RING_R]), Color(1.0, 0.85, 0.2, 0.8), 1.5)


func _inset(img: Image, center: Vector2, title: String) -> void:
	var c := to_px(center, img)
	var half := int(RING_R + RANGE)
	var crop := img.get_region(Rect2i(int(c.x) - half, int(c.y) - half, half * 2, half * 2))
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(crop)
	spr.centered = false
	spr.scale = Vector2(0.8, 0.8)
	spr.position = Vector2(_insets_x, center.y - half * 0.8)
	spr.z_index = 40
	add_child(spr)
	label(title, spr.position + Vector2(0, -18), 12)
	_insets_x += 0.0
