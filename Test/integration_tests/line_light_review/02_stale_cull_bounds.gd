extends "res://Test/integration_tests/line_light_review/demo_base.gd"

## Walkthrough of issue 2: an off-screen curved line light keeps stale cull bounds when its
## Path2D child moves or its curve is replaced. See checks/02_stale_cull_bounds_check.gd
## for the automated version and the code references.
##
## Careful when editing: ANY node entering or leaving the tree heals the bug (it rebuilds
## Lit's light cache), so every node is created in build() and the steps only change
## properties - except the one step that adds a node on purpose.

const RING_R := 110.0
const RANGE := 110.0
const ENERGY := 0.8
const RING_Y := 360.0
const PANELS := [Rect2(20, 64, 930, 800), Rect2(970, 64, 930, 800)]
const NODE_X := [-700.0, 2620.0]      # the light nodes, off screen left / right
const TARGET_X := [485.0, 1435.0]     # where each ring ends up on screen

var _lights: Array[LitLineLight2D] = []
var _paths: Array[Path2D] = []
var _outlines: Array[Line2D] = []
var _drawn: Array[Label] = []
var _states: Array[Label] = []
var _counter: Label
var _map: MiniMap
var _notify_expected := true
var _frames_since := 0
var _healed := false
var _probe_tick := 0


func demo_title() -> String:
	return "Issue 2 - Off-screen curved line light: moving its Path2D doesn't wake it up"


func build() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	for i in 2:
		var rect: Rect2 = PANELS[i]
		floor_receiver(rect)
		var l := line_light(Vector2(NODE_X[i], RING_Y), 0.0, RANGE, ENERGY, 60.0)
		var path := Path2D.new()
		path.curve = _ring(Vector2.ZERO)
		l.add_child(path)
		l.closed = true
		_lights.append(l)
		_paths.append(path)
		if i == 0:
			panel(rect, "expected", "the light is told its path moved (what a fix would do)")
		else:
			panel(rect, "actual", "unmodified LitLineLight2D")
		var outline := overlay_line(_dashed(Vector2.ZERO), Color(1.0, 0.85, 0.2, 0.85), 2.0)
		_outlines.append(outline)
		_drawn.append(readout(Vector2(rect.position.x + 30, 620), 30, C_EXPECTED if i == 0 else C_ACTUAL))
		_states.append(readout(Vector2(rect.position.x + 30, 120), 24, C_NOTE))
		var arrow_x: float = rect.position.x + 14.0 if i == 0 else rect.end.x - 330.0
		var arrow := readout(Vector2(arrow_x, RING_Y - 70.0), 18, C_DIM)
		arrow.text = ("<-- light node: 700 px off screen" if i == 0 else "light node: 700 px off screen -->")
	_counter = readout(Vector2(1000, 570), 22, C_NOTE)
	_map = MiniMap.new()
	_map.demo = self
	_ui.add_child(_map)

	add_step("The setup",
			"Each panel has a %s whose %s sits %s (see the arrows and the minimap). Its ring shape comes from a %s child - parked off screen too for now. Lit skips (culls) lights whose bounds are off screen; that is correct and saves GPU time. The minimap shows the screen (white box), each light node (dot), where the ring really is (yellow circle) and the %s (filled box)." % [
			code("LitLineLight2D"), y("node"), y("off screen"), code("Path2D"), y("bounds Lit's culling uses")],
			10.0, _s_setup, _s_setup_tick)
	add_step("Slow motion: slide the Path2D onto the screen",
			"Both Path2D children slide right / left until their rings are on screen (the yellow circles). The light nodes don't move. %s the light is told after each move, its cull box follows the ring, and the ring lights the floor as it arrives. %s nothing tells the light its Path2D moved: its cull box (red, minimap) stays off screen with the node, so Lit keeps skipping it - the ring is %s." % [
			g("LEFT (expected):"), r("RIGHT (bug):"), r("never drawn")],
			12.0, _s_slide, _s_slide_tick)
	add_step("Waiting doesn't help",
			"The ring is fully on screen and nothing else changes. Lit only re-reads a curved light's path when the light is already being drawn, or when one of its own properties changes - so the stale bounds stay %s." % [
			r("frame after frame")],
			8.0, _s_wait, _s_wait_tick)
	add_step("BEFORE / AFTER: an unrelated node joins the tree",
			"%s: still dark. %s: a plain %s is added somewhere else in the scene (think: a bullet spawning). Any node entering or leaving the tree makes Lit rebuild its light cache, which re-reads the path - and the ring %s. So in a busy game these rings tend to appear late; in a quiet scene they stay dark indefinitely." % [
			y("BEFORE"), y("AFTER"), code("Node"), g("appears")],
			10.0, _s_heal, _s_heal_tick)
	add_step("Second trigger: replacing the curve",
			"Rings parked off screen again. %s: a brand-new %s, whose points are already on screen, is assigned to %s on both sides. Left (told) lights up; %s stays dark. Then %s - a no-op write to one of the light's own properties - wakes it up (only properties with a setter that notifies Lit count: %s, %s, %s, %s... but not %s)." % [
			y("BEFORE -> AFTER"), code("Curve2D"), code("path.curve"), r("right"), code("light.range = light.range"), code("range"), code("width"), code("length"), code("enabled"), code("energy")],
			14.0, _s_swap, _s_swap_tick)
	add_step("Summary",
			"The runtime cull (%s) tests a curved light against bounds mirrored in %s, refreshed only for lights marked pending (their own setters, %s) or on a full cache rebuild. Moving the Path2D or assigning a new curve marks nothing; %s notices it, but only runs while the light is drawn. Fix: watch the Path2D's transform and curve swap (or re-read %s for culled curved lights)." % [
			code("light_cache.gd cull_visible"), code("_prects"), code("Curve2D.changed"), code("LitLineLight2D._refresh_path()"), code("path_rect()")],
			10.0, _s_summary, Callable())


# --- Scene control ------------------------------------------------------------------------

## A closed ring around `c` (light-local): four cubic quarters.
func _ring(c: Vector2) -> Curve2D:
	var k := RING_R * 0.5523
	var curve := Curve2D.new()
	var pts := [Vector2(RING_R, 0), Vector2(0, RING_R), Vector2(-RING_R, 0), Vector2(0, -RING_R)]
	var tans := [Vector2(0, k), Vector2(-k, 0), Vector2(0, -k), Vector2(k, 0)]
	for q in 4:
		curve.add_point(c + pts[q], -tans[q], tans[q])
	curve.add_point(c + pts[0], -tans[0], Vector2.ZERO)
	return curve


func _dashed(c: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 48:
		pts.append(c + Vector2.from_angle(TAU * float(k) / 48.0) * RING_R)
	return pts


## Where panel i's ring centre is, in world space.
func ring_center(i: int) -> Vector2:
	return _lights[i].global_position + _paths[i].position + _ring_offset[i]


var _ring_offset := [Vector2.ZERO, Vector2.ZERO]
var ring_extent := RING_R + RANGE


## Park both rings off screen next to their nodes, with fresh curves, and let Lit see
## that state (the notify), so the cache holds off-screen bounds.
func _park() -> void:
	for i in 2:
		_paths[i].position = Vector2.ZERO
		_paths[i].curve = _ring(Vector2.ZERO)
		_ring_offset[i] = Vector2.ZERO
		_notify(i)
	_frames_since = 0


func _notify(i: int) -> void:
	_lights[i].range = _lights[i].range


func _update_visuals() -> void:
	for i in 2:
		_outlines[i].points = _dashed(ring_center(i))
	_probe_tick += 1
	if _probe_tick % 3 != 0:
		return
	var img := frame_image()
	for i in 2:
		var c := ring_center(i)
		var on_screen := c.x > 0.0 and c.x < 1920.0
		var lit := on_screen and lum(img, c + Vector2(RING_R - 15.0, 0), 1) > AMBIENT + 0.1
		if not on_screen:
			_drawn[i].text = "ring off screen"
		else:
			_drawn[i].text = "ring drawn: %s" % ("YES" if lit else "NO")


func _base(states := "") -> void:
	for i in 2:
		_states[i].text = states
	_counter.text = ""


# --- Steps --------------------------------------------------------------------------------

func _s_setup() -> void:
	_park()
	_base()


func _s_setup_tick(_f: float, _t: float) -> void:
	_update_visuals()


func _s_slide() -> void:
	_park()
	_base()


func _s_slide_tick(f: float, _t: float) -> void:
	var e := smoothstep(0.05, 0.9, f)
	for i in 2:
		_paths[i].position = Vector2((TARGET_X[i] - NODE_X[i]) * e, 0.0)
	_notify(0)
	_update_visuals()


func _s_wait() -> void:
	_base()
	_frames_since = 0
	for i in 2:
		_paths[i].position = Vector2(TARGET_X[i] - NODE_X[i], 0.0)
	_notify(0)


func _s_wait_tick(_f: float, _t: float) -> void:
	_frames_since += 1
	_counter.text = "frames since the ring arrived: %d" % _frames_since
	_update_visuals()


func _s_heal() -> void:
	_base("BEFORE")
	_healed = false
	for i in 2:
		_paths[i].position = Vector2(TARGET_X[i] - NODE_X[i], 0.0)
	_notify(0)


func _s_heal_tick(f: float, _t: float) -> void:
	if f >= 0.4 and not _healed:
		_healed = true
		var n := Node.new()
		n.name = "UnrelatedNode"
		add_child(n)
		for i in 2:
			_states[i].text = "AFTER: one plain Node added to the tree"
	_update_visuals()


var _swap_state := 0


func _s_swap() -> void:
	_park()
	_base("BEFORE: rings parked off screen")
	_swap_state = 0


func _s_swap_tick(f: float, _t: float) -> void:
	if f >= 0.2 and _swap_state == 0:
		_swap_state = 1
		for i in 2:
			var off := Vector2(TARGET_X[i] - NODE_X[i], 0.0)
			_paths[i].curve = _ring(off)
			_ring_offset[i] = off
			_states[i].text = "AFTER: path.curve = new Curve2D (on screen)"
		_notify(0)
	elif f >= 0.65 and _swap_state == 1:
		_swap_state = 2
		_notify(1)
		_states[1].text = "AFTER: light.range = light.range"
	_update_visuals()


func _s_summary() -> void:
	_base()


# --- Minimap ------------------------------------------------------------------------------

class MiniMap extends Node2D:
	var demo
	const AREA := Rect2(560, 670, 800, 160)
	const WORLD := Rect2(-900, 64, 3720, 800)

	func _process(_d: float) -> void:
		queue_redraw()

	func _w2m(p: Vector2) -> Vector2:
		var s := AREA.size.x / WORLD.size.x
		return AREA.position + (p - WORLD.position) * s

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(AREA.grow(8), Color(0.05, 0.05, 0.07, 0.95))
		draw_string(font, AREA.position + Vector2(0, -14), "minimap (whole world, 1:4.6)", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.85, 0.85, 0.9))
		var scr := Rect2(_w2m(Vector2(0, 64)), Vector2(1920, 800) * (AREA.size.x / WORLD.size.x))
		draw_rect(scr, Color(1, 1, 1, 0.9), false, 2.0)
		draw_string(font, scr.position + Vector2(4, 14), "screen", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.8))
		var mgr = demo.get_node_or_null("/root/LitManager")
		if mgr == null:
			return
		var cache = mgr._registry._light_cache
		for i in 2:
			var l: LitLineLight2D = demo._lights[i]
			var col: Color = Color(0.36, 0.9, 0.45) if i == 0 else Color(1.0, 0.36, 0.3)
			var idx: int = cache._index.get(l.get_instance_id(), -1)
			if idx >= 0:
				var xf := l.global_transform
				var b := idx * 4
				var pr: PackedFloat32Array = cache._prects
				var c0 := xf.basis_xform(Vector2(pr[b], pr[b + 1]))
				var c1 := xf.basis_xform(Vector2(pr[b + 2], pr[b + 3]))
				var lr: float = cache._ranges[idx] * maxf(xf.x.length(), xf.y.length())
				var lo := xf.origin + c0.min(c1) - Vector2(lr, lr)
				var hi := xf.origin + c0.max(c1) + Vector2(lr, lr)
				var r := Rect2(_w2m(lo), _w2m(hi) - _w2m(lo))
				draw_rect(r, Color(col, 0.35))
				draw_rect(r, col, false, 1.5)
			var c: Vector2 = demo.ring_center(i)
			var rad: float = demo.ring_extent * (AREA.size.x / WORLD.size.x)
			draw_arc(_w2m(c), rad, 0, TAU, 32, Color(1, 0.85, 0.2), 1.5)
			draw_circle(_w2m(l.global_position), 5.0, col)
		draw_string(font, AREA.position + Vector2(0, AREA.size.y + 22),
				"dot = light node    yellow circle = where the ring really is    filled box = bounds Lit culls with",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.8, 0.8, 0.85))
