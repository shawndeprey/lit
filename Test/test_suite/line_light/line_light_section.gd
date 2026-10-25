extends LitSuiteSection

## LitLineLight2D against the rendered frame: the capsule footprint (every distance
## measured from Q, the nearest point of the segment, so the light is constant along
## the tube and a point light past each end cap), length / rotation / node scale, the
## point-light shading contract (range, falloff, energy, colour, height, gates, blend,
## light masks), width and glow (a flat beam under the tube, a halo at a fraction of its
## brightness falling off from its surface),
## shadows (umbra, colour, length, soft along the tube and sharp across it on Cone
## Traced and Stochastic with the stochastic as the reference, Raymarched hard, and an
## occluder beside the tube darkening nothing but its own shadow), cookies
## (node-centered NATIVE, FIT_RANGE over the capsule's box, offset), the node API and
## registry plumbing (kind, mirror, packed row, capsule culling, activity flags), the
## luminance mirror, z ranges and camera zoom invariance.
##
## Numeric expectations are the receiver shader's diffuse term on a flat white
## receiver, with d the distance to Q: albedo x ambient + energy x
## (height / sqrt(d^2 + height^2)) x (1 - d / range)^falloff x diffuse_scale().

const AMBIENT := 0.1
const TOL := 0.03
const ALGO := LitShaderLibrary.ShadowAlgorithm

# A: geometry and shading. Tube centered on CA along +X, 200 long (x 200..400).
const CA := Vector2(300, 300)
# B: broadside shadows. Tube x 890..1190 at y 170, a wall parallel to it below.
const CB := Vector2(1040, 170)
const P_UM := Vector2(1040, 360)     # umbra behind the wall
const P_PEN := Vector2(1200, 360)    # penumbra of the tube, umbra of a point light
const P_REF := Vector2(840, 300)     # lit for the tube and for a point light at CB
const P_NEAR := Vector2(1040, 210)   # between the tube and the wall
# D: shadow shape. Tube x 890..1190 at y 800, a box off its right end and one beside it.
const CD := Vector2(1040, 800)
const P_AX := Vector2(1360, 800)     # on the axis behind the end-on box: umbra
const P_EDGE := Vector2(1360, 700)   # 6 px outside the end-on box's shadow edge
const P_SIDE := Vector2(1105, 980)   # 15 px outside the broadside box's hard shadow edge
const P_OPP := Vector2(1040, 700)    # 100 px above the tube, opposite the broadside box
const P_BETWEEN := Vector2(1040, 850) # between the tube and the broadside box
# C: cookie light (x 220..380 at y 700, range 100) and the luminance exhibit.
const CC := Vector2(300, 700)

var _props: Node2D
var _floor_a: LitSprite2D
var _floor_c: LitSprite2D
var _tube_b: LitLineLight2D
var _tube_d: LitLineLight2D
var _cam: Camera2D


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_props = group("Props")
	label("line light: capsule footprint (Q), end caps, length, rotation, scale, shading, gates, masks",
			Vector2(24, 74))
	label("line shadows beside the tube: umbra, colour, length, soft along the tube vs a point", Vector2(704, 74))
	label("cookies (node-centered, FIT_RANGE over the capsule), API, culling, luminance, ranges", Vector2(24, 544))
	label("shadow shape: sharp across the tube, soft along it, cone vs stochastic, zoom", Vector2(704, 544))
	_floor_a = floor_receiver(Rect2(20, 90, 660, 430))
	floor_receiver(Rect2(700, 90, 680, 430))
	_floor_c = floor_receiver(Rect2(20, 560, 660, 480))
	floor_receiver(Rect2(700, 560, 680, 480))
	await frames(2)
	await _geometry()
	await _shading()
	await _width()
	await _shadows()
	await _shadow_shape()
	await _cookies()
	await _api()
	await _luminance()
	await _ranges()
	await _camera()


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


## Diffuse at distance d from Q on a flat white receiver.
func _exp(d: float, p_range: float, energy: float, falloff: float, height: float) -> float:
	if d > p_range:
		return AMBIENT
	var atten := pow(clampf(1.0 - d / p_range, 0.0, 1.0), falloff)
	var ndotl := height / sqrt(d * d + height * height)
	var c := energy * ndotl * atten
	return AMBIENT + (c * diffuse_scale() if c >= 0.004 else 0.0)


# --- A: geometry -----------------------------------------------------------------------------

func _geometry() -> void:
	var c := "line_geometry"
	var l := line_light(CA, 200.0, 150.0, 0.5, 100.0)
	await frames(1)
	var img := await capture()
	var on := _exp(0.0, 150.0, 0.5, 1.0, 100.0)
	var beside := _exp(100.0, 150.0, 0.5, 1.0, 100.0)
	check_approx(c, "on the segment at the node", on, lum(img, CA), TOL)
	check_approx(c, "on the segment 80 px along it (still distance 0)", on, lum(img, CA + Vector2(80, 0)), TOL)
	check_approx(c, "at the right end cap", on, lum(img, CA + Vector2(100, 0)), TOL)
	check_approx(c, "at the left end cap", on, lum(img, CA + Vector2(-100, 0)), TOL)
	for dx in [-100, 0, 100]:
		check_approx(c, "100 px beside the tube at x %+d: the point-light value at 100 px" % dx, beside,
				lum(img, CA + Vector2(dx, 100)), TOL)
	check_approx(c, "100 px above the tube reads the same", beside, lum(img, CA + Vector2(0, -100)), TOL)
	check_approx(c, "100 px past the end cap along the axis: a point light at the endpoint", beside,
			lum(img, CA + Vector2(200, 0)), TOL)
	check_approx(c, "100 px past the end cap on the diagonal", beside, lum(img, CA + Vector2(171, 71)), TOL)
	check_approx(c, "120 px beside the tube", _exp(120.0, 150.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(0, 120)), 0.02)
	check_approx(c, "170 px beside the tube (beyond range): ambient", AMBIENT, lum(img, CA + Vector2(0, 170)), TOL)
	check_approx(c, "170 px above the tube: ambient", AMBIENT, lum(img, CA + Vector2(0, -170)), TOL)
	check_approx(c, "170 px past the end cap: ambient", AMBIENT, lum(img, CA + Vector2(270, 0)), TOL)

	l.length = 0.0
	img = await capture()
	check_approx(c, "length 0: a point light (the old end cap is now 100 px away)", beside, lum(img, CA + Vector2(100, 0)), TOL)
	check_approx(c, "length 0: still lit at the node", on, lum(img, CA), TOL)
	check_approx(c, "length 0: 100 px beside unchanged", beside, lum(img, CA + Vector2(0, 100)), TOL)
	l.length = 200.0
	l.rotation = PI / 2.0
	img = await capture()
	check_approx(c, "rotation 90: the segment runs along y (100 px above the node is on it)", on,
			lum(img, CA + Vector2(0, -100)), TOL)
	check_approx(c, "rotation 90: 100 px below the node is on it too", on, lum(img, CA + Vector2(0, 100)), TOL)
	check_approx(c, "rotation 90: 100 px to the right is beside it", beside, lum(img, CA + Vector2(100, 0)), TOL)
	l.rotation = 0.0
	l.scale = Vector2(2.0, 1.0)
	img = await capture()
	check_approx(c, "scale (2, 1): the segment doubles (200 px along is on it)", on, lum(img, CA + Vector2(200, 0)), TOL)
	check_approx(c, "scale (2, 1): range follows the larger axis (200 px above lit at range 300)",
			_exp(200.0, 300.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(0, -200)), TOL)
	check_approx(c, "scale (2, 1): 100 px past the doubled end cap", _exp(100.0, 300.0, 0.5, 1.0, 100.0),
			lum(img, CA + Vector2(300, 0)), TOL)
	l.scale = Vector2(1.0, 2.0)
	img = await capture()
	check_approx(c, "scale (1, 2): the segment keeps its length (200 px along is 100 px past the cap, range 300)",
			_exp(100.0, 300.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(200, 0)), TOL)
	check_approx(c, "scale (1, 2): range follows the larger axis", _exp(200.0, 300.0, 0.5, 1.0, 100.0),
			lum(img, CA + Vector2(0, -200)), TOL)
	l.scale = Vector2.ONE
	l.name = "TubeA"


# --- A: shading --------------------------------------------------------------------------------

func _shading() -> void:
	var c := "line_shading"
	var l := get_node("TubeA") as LitLineLight2D
	var side := CA + Vector2(0, 100)
	var img := await capture()
	check_approx(c, "falloff 1 at 100 px beside", _exp(100.0, 150.0, 0.5, 1.0, 100.0), lum(img, side), TOL)
	l.falloff = 2.0
	img = await capture()
	check_approx(c, "falloff 2 at 100 px beside", _exp(100.0, 150.0, 0.5, 2.0, 100.0), lum(img, side), TOL)
	l.falloff = 0.0
	img = await capture()
	check_approx(c, "falloff 0 at 100 px beside (elevation only)", _exp(100.0, 150.0, 0.5, 0.0, 100.0), lum(img, side), TOL)
	l.falloff = 1.0
	l.energy = 0.2
	img = await capture()
	check_approx(c, "energy 0.2 on the segment", AMBIENT + 0.2 * diffuse_scale(), lum(img, CA), TOL)
	l.energy = 0.5
	l.height = 300.0
	img = await capture()
	check_approx(c, "height 300 at 100 px beside (more head-on: brighter)", _exp(100.0, 150.0, 0.5, 1.0, 300.0),
			lum(img, side), TOL)
	l.height = 100.0
	l.color = Color(1.0, 0.0, 0.0)
	img = await capture()
	var col := probe(img, CA)
	check_approx(c, "red light: red channel", AMBIENT + 0.5 * diffuse_scale(), col.r, TOL)
	check_approx(c, "red light: green channel stays ambient", AMBIENT, col.g, TOL)
	l.color = Color.WHITE
	l.range = 80.0
	img = await capture()
	check_approx(c, "range 80: 100 px beside is ambient", AMBIENT, lum(img, side), TOL)
	check_approx(c, "range 80: 50 px beside", _exp(50.0, 80.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(0, 50)), TOL)
	l.range = 150.0
	l.enabled = false
	img = await capture()
	check_approx(c, "enabled = false: ambient on the segment", AMBIENT, lum(img, CA), TOL)
	l.enabled = true
	l.visible = false
	img = await capture()
	check_approx(c, "visible = false: ambient on the segment", AMBIENT, lum(img, CA), TOL)
	l.visible = true
	img = await capture()
	check_approx(c, "re-enabled and visible: lit again", _exp(0.0, 150.0, 0.5, 1.0, 100.0), lum(img, CA), TOL)
	l.position = CA + Vector2(0, 100)
	img = await capture()
	check_approx(c, "moved 100 px down: the old side probe is on the segment", _exp(0.0, 150.0, 0.5, 1.0, 100.0),
			lum(img, side), TOL)
	check_approx(c, "moved: the old node position is 100 px beside", _exp(100.0, 150.0, 0.5, 1.0, 100.0), lum(img, CA), TOL)
	l.position = CA
	l.blend_mode = LitShaderLibrary.BlendMode.SUBTRACT
	l.energy = 0.3
	img = await capture()
	check_approx(c, "subtract energy 0.3 on the segment clamps at black", 0.0, lum(img, CA), TOL)
	check_approx(c, "subtract at 100 px beside: partial carve",
			AMBIENT - (_exp(100.0, 150.0, 0.3, 1.0, 100.0) - AMBIENT), lum(img, side), TOL)
	l.blend_mode = LitShaderLibrary.BlendMode.ADD
	l.energy = 0.5

	# Light masks: a small tube on mask 2 over a mask-1 and a mask-3 box.
	var a := box_receiver(Vector2(520, 460), Vector2(60, 60))
	var b := box_receiver(Vector2(600, 460), Vector2(60, 60))
	a.specular_strength = 0.0
	b.specular_strength = 0.0
	b.receiver_mask = 3
	var m := line_light(Vector2(560, 460), 60.0, 90.0, 0.6, 100.0)
	m.light_mask = 2
	await frames(1)
	img = await capture()
	check_approx(c, "light_mask 2 vs receiver_mask 1: not lit", AMBIENT, lum(img, a.position), TOL)
	check_gt(c, "light_mask 2 vs receiver_mask 3: lit", lum(img, b.position), AMBIENT, 0.2)
	check_approx(c, "the mask-1 floor beside the mask-2 tube stays ambient", AMBIENT, lum(img, Vector2(560, 400)), TOL)
	m.light_mask = 1
	img = await capture()
	check_gt(c, "light_mask 1: receiver_mask 1 now lit", lum(img, a.position), AMBIENT, 0.2)
	check_gt(c, "light_mask 1: the floor beside the tube lit", lum(img, Vector2(560, 400)), AMBIENT, 0.15)
	m.queue_free()
	a.queue_free()
	b.queue_free()
	l.queue_free()
	await frames(1)
	img = await capture()
	check_approx(c, "freed light: ambient only", AMBIENT, lum(img, CA), TOL)
	var keep := line_light(CA, 200.0, 150.0, 0.5, 100.0)
	keep.name = "LineExhibit"


# --- A: width ----------------------------------------------------------------------------------

func _width() -> void:
	var c := "line_width"
	var mgr := get_node("/root/LitManager")
	var l := get_node("LineExhibit") as LitLineLight2D
	var on := _exp(0.0, 150.0, 0.5, 1.0, 100.0)
	l.width = 40.0
	await frames(1)
	var img := await capture()
	check_approx(c, "width 40: on the segment unchanged", on, lum(img, CA), TOL)
	check_approx(c, "width 40: 10 px beside is under the tube (flat core)", on, lum(img, CA + Vector2(0, 10)), TOL)
	check_approx(c, "width 40: 20 px beside, the tube's surface, is continuous", on, lum(img, CA + Vector2(0, 20)), TOL)
	check_approx(c, "width 40: 60 px beside falls off from the surface over range - 20",
			_exp(40.0, 130.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(0, 60)), TOL)
	check_approx(c, "width 40: 100 px past the end cap carries the width too",
			_exp(80.0, 130.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(200, 0)), TOL)
	check_approx(c, "width 40: the range still ends at 150 (160 px beside is ambient)", AMBIENT,
			lum(img, CA + Vector2(0, 160)), TOL)
	check_approx(c, "width 40: sample_luminance 60 px beside matches the render", lum(img, CA + Vector2(0, 60)),
			mgr.sample_luminance(CA + Vector2(0, 60)), TOL)
	check_approx(c, "width 40: sample_luminance under the tube matches the render", lum(img, CA + Vector2(0, 10)),
			mgr.sample_luminance(CA + Vector2(0, 10)), TOL)
	l.glow = 0.5
	await frames(1)
	img = await capture()
	check_approx(c, "glow 0.5, width 40: under the tube the beam keeps its brightness", on, lum(img, CA + Vector2(0, 10)), TOL)
	var halo := AMBIENT + 0.5 * (_exp(40.0, 130.0, 0.5, 1.0, 100.0) - AMBIENT)
	check_approx(c, "glow 0.5: 60 px beside, the halo is half the beam's energy", halo, lum(img, CA + Vector2(0, 60)), TOL)
	check_approx(c, "glow 0.5: 100 px past the end cap, the halo too", AMBIENT + 0.5 * (_exp(80.0, 130.0, 0.5, 1.0, 100.0) - AMBIENT),
			lum(img, CA + Vector2(200, 0)), TOL)
	check_approx(c, "glow 0.5: sample_luminance 60 px beside matches the render", lum(img, CA + Vector2(0, 60)),
			mgr.sample_luminance(CA + Vector2(0, 60)), TOL)
	l.glow = 0.0
	await frames(1)
	img = await capture()
	check_approx(c, "glow 0: the beam alone, 60 px beside is ambient", AMBIENT, lum(img, CA + Vector2(0, 60)), TOL)
	check_approx(c, "glow 0: under the tube still the beam", on, lum(img, CA + Vector2(0, 10)), TOL)
	l.glow = 0.5
	l.width = 0.0
	await frames(1)
	img = await capture()
	var halo_on := AMBIENT + 0.5 * (on - AMBIENT)
	check_approx(c, "width 0, glow 0.5: no beam, the pixel on the segment is halo (no hairline)", halo_on, lum(img, CA), TOL)
	check_approx(c, "width 0, glow 0.5: one pixel beside the segment is halo too", halo_on, lum(img, CA + Vector2(0, 1)), TOL)
	check_approx(c, "width 0, glow 0.5: sample_luminance on the segment matches", lum(img, CA), mgr.sample_luminance(CA), TOL)
	l.width = 12.0
	await frames(1)
	img = await capture()
	check_approx(c, "width 12, glow 0.5: the beam is back on the segment", on, lum(img, CA), TOL)
	l.glow = 1.0
	l.width = 400.0
	await frames(1)
	img = await capture()
	check_approx(c, "width 400 (wider than the range): the core is clamped inside it, 100 px beside is core", on,
			lum(img, CA + Vector2(0, 100)), TOL)
	check_approx(c, "width 400: the last tenth of the range still falls off (140 px beside)",
			_exp(5.0, 15.0, 0.5, 1.0, 100.0), lum(img, CA + Vector2(0, 140)), TOL)
	l.width = -3.0
	check(c, "a negative width clamps to 0", 0.0, l.width)
	await frames(1)
	img = await capture()
	check_approx(c, "width 0: 10 px beside is the ideal line again", _exp(10.0, 150.0, 0.5, 1.0, 100.0),
			lum(img, CA + Vector2(0, 10)), TOL)


# --- B: shadows beside the tube ------------------------------------------------------------

func _shadows() -> void:
	var c := "line_shadows"
	_tube_b = line_light(CB, 300.0, 300.0, 0.8, 300.0)
	_tube_b.falloff = 0.3
	_tube_b.source_radius = 2.0
	_tube_b.shadow_samples = 16
	var wall := occluder(Vector2(1040, 250), Vector2(200, 20), _props)
	await frames(3)
	var img := await capture()
	var lit_um := lum(img, P_UM)
	check_gt(c, "shadows off: behind the wall is lit", lit_um, AMBIENT, 0.25)
	_tube_b.shadow_enabled = true
	await frames(2)
	img = await capture()
	check_approx(c, "shadow_enabled (Cone Traced): the umbra behind the wall is ambient", AMBIENT, lum(img, P_UM), 0.06)
	check_gt(c, "beside the shadow band: lit", lum(img, P_REF), AMBIENT, 0.2)
	check_gt(c, "between the tube and the wall: lit", lum(img, P_NEAR), AMBIENT, 0.25)
	_tube_b.shadow_algorithm = ALGO.RAYMARCHED
	await frames(2)
	img = await capture()
	check_approx(c, "Raymarched: the umbra behind the wall is ambient", AMBIENT, lum(img, P_UM), 0.06)
	_tube_b.shadow_color = Color(1.0, 0.0, 0.0)
	img = await capture()
	var col := probe(img, P_UM)
	check_gt(c, "red shadow colour keeps red in the umbra", col.r, AMBIENT, 0.25)
	check_approx(c, "red shadow colour: green channel ambient", AMBIENT, col.g, TOL)
	_tube_b.shadow_color = Color.BLACK
	for algo in [ALGO.RAYMARCHED, ALGO.CONE_TRACED]:
		var an: String = ["Raymarched", "Cone Traced", "Stochastic"][algo]
		_tube_b.shadow_algorithm = algo
		_tube_b.shadow_length = 0.3
		await frames(2)
		img = await capture()
		check_gt(c, "%s shadow_length 0.3: the wall is beyond the capped march, lit" % an, lum(img, P_UM), AMBIENT, 0.25)
		_tube_b.shadow_length = 1.0
		img = await capture()
		check_approx(c, "%s shadow_length 1: umbra back" % an, AMBIENT, lum(img, P_UM), 0.06)
	wall.visible = false
	await frames(2)
	img = await capture()
	check_gt(c, "hidden wall casts nothing", lum(img, P_UM), AMBIENT, 0.25)
	wall.visible = true
	await frames(2)

	# Soft along the tube: the wall's shadow edge along the tube's direction is a wide
	# penumbra (the source is 300 px long) where a point light at the node has umbra.
	var point_pen := {}
	var line_pen := {}
	for algo in [ALGO.CONE_TRACED, ALGO.STOCHASTIC, ALGO.RAYMARCHED]:
		var an: String = ["Raymarched", "Cone Traced", "Stochastic"][algo]
		_tube_b.shadow_algorithm = algo
		_tube_b.shadow_samples = 16
		_tube_b.length = 0.0
		await frames(2)
		img = await capture()
		point_pen[algo] = lum(img, P_PEN)
		check_approx(c, "%s, length 0 (a point light): the penumbra probe is in its umbra" % an, AMBIENT, point_pen[algo], 0.06)
		_tube_b.length = 300.0
		await frames(2)
		img = await capture()
		line_pen[algo] = lum(img, P_PEN)
		check_approx(c, "%s: umbra behind the wall is ambient" % an, AMBIENT, lum(img, P_UM), 0.06)
		check_gt(c, "%s: beside the band stays lit" % an, lum(img, P_REF), AMBIENT, 0.2)
	check_gt(c, "Cone Traced: soft along the tube (the point's umbra probe is partly lit)", line_pen[ALGO.CONE_TRACED],
			point_pen[ALGO.CONE_TRACED], 0.1)
	check_gt(c, "Stochastic: soft along the tube too", line_pen[ALGO.STOCHASTIC], point_pen[ALGO.STOCHASTIC], 0.1)
	check_approx(c, "Cone Traced matches the Stochastic reference in the penumbra", line_pen[ALGO.STOCHASTIC],
			line_pen[ALGO.CONE_TRACED], 0.04)
	check_gt(c, "Raymarched: its one hard march goes to Q, the end cap here, and clears the wall", line_pen[ALGO.RAYMARCHED],
			AMBIENT, 0.25)
	# Each stratum is a cone: with 4 of them over the 300 px tube every sub-cone is
	# wider than the 20 px wall, and the half-plane coverage cannot close the umbra.
	_tube_b.shadow_algorithm = ALGO.CONE_TRACED
	_tube_b.shadow_samples = 4
	await frames(2)
	img = await capture()
	check_gt(c, "Cone Traced, 4 strata: sub-cones wider than the thin wall leave its umbra partly open", lum(img, P_UM),
			AMBIENT, 0.04)
	_tube_b.shadow_samples = 16
	await frames(2)
	check_true(c, "a Cone Traced line light publishes F_STOCH (its cone is marched as strata)",
			LitLightRegistry.activity_flags & LitShaderLibrary.F_STOCH != 0)
	check_true(c, "and not F_CONE", LitLightRegistry.activity_flags & LitShaderLibrary.F_CONE == 0)
	_tube_b.name = "TubeB"
	wall.name = "WallB"


# --- D: shadow shape ---------------------------------------------------------------------------

func _shadow_shape() -> void:
	var c := "line_shadow_shape"
	_tube_d = line_light(CD, 300.0, 300.0, 0.8, 300.0)
	_tube_d.falloff = 0.3
	_tube_d.source_radius = 2.0
	_tube_d.shadow_enabled = true
	var end_box := occluder(Vector2(1290, 800), Vector2(20, 100), _props)
	var side_box := occluder(Vector2(1040, 900), Vector2(100, 20), _props)
	await frames(3)
	var img := await capture()
	var lit_edge := _exp(sqrt(170.0 * 170.0 + 100.0 * 100.0), 300.0, 0.8, 0.3, 300.0)
	var lit_side := _exp(180.0, 300.0, 0.8, 0.3, 300.0)
	# The broadside box sits 90 px below the tube's middle. A source marched as one
	# tube-wide cone read it from every direction (an hourglass pinch at its height on
	# both sides of the tube); the strata see it only from behind it.
	var lit_opp := lum(img, P_OPP)
	var lit_between := lum(img, P_BETWEEN)
	check_approx(c, "Cone Traced (default): 100 px above the tube, opposite the broadside box, is unshadowed", _exp(100.0, 300.0, 0.8, 0.3, 300.0),
			lit_opp, TOL)
	var results := {}
	for algo in [ALGO.CONE_TRACED, ALGO.STOCHASTIC, ALGO.RAYMARCHED]:
		var an: String = ["Raymarched", "Cone Traced", "Stochastic"][algo]
		_tube_d.shadow_algorithm = algo
		_tube_d.shadow_samples = 16
		await frames(2)
		img = await capture()
		results[algo] = {"ax": lum(img, P_AX), "edge": lum(img, P_EDGE, 1), "side": lum(img, P_SIDE)}
		check_approx(c, "%s: on the axis behind the end-on box is umbra" % an, AMBIENT, results[algo]["ax"], 0.06)
		check_approx(c, "%s: sharp across the tube (6 px outside the end-on edge reads lit)" % an, lit_edge,
				results[algo]["edge"], 0.04)
		check_approx(c, "%s: the box beside the tube casts nothing across it (opposite side unchanged)" % an, lit_opp,
				lum(img, P_OPP), 0.02)
		check_approx(c, "%s: between the tube and the box is unchanged" % an, lit_between, lum(img, P_BETWEEN), 0.02)
	check_lt(c, "Cone Traced: soft along the tube (15 px outside the broadside hard edge is shadowed)",
			results[ALGO.CONE_TRACED]["side"], lit_side, 0.15)
	check_lt(c, "Stochastic: soft along the tube", results[ALGO.STOCHASTIC]["side"], lit_side, 0.15)
	check_approx(c, "Raymarched: hard along the tube (15 px outside the edge is lit)", lit_side,
			results[ALGO.RAYMARCHED]["side"], 0.04)
	check_approx(c, "Cone Traced matches the Stochastic reference beside the box", results[ALGO.STOCHASTIC]["side"],
			results[ALGO.CONE_TRACED]["side"], 0.04)
	check_gt(c, "the broadside penumbra is partly lit, not umbra", results[ALGO.STOCHASTIC]["side"], AMBIENT, 0.1)
	# Cone Traced on a line light is the same strata without the dither.
	_tube_d.shadow_algorithm = ALGO.STOCHASTIC
	_tube_d.shadow_samples = 16
	_tube_d.shadow_jitter = 0.0
	await frames(2)
	img = await capture()
	check_approx(c, "Stochastic 16 samples, no jitter: equals Cone Traced", results[ALGO.CONE_TRACED]["side"],
			lum(img, P_SIDE), 0.01)
	_tube_d.shadow_samples = 8
	_tube_d.shadow_jitter = 0.35
	await frames(2)
	check_true(c, "a stochastic line light publishes F_STOCH",
			LitLightRegistry.activity_flags & LitShaderLibrary.F_STOCH != 0)
	# A wide source closes the umbra behind the thin end-on box (antumbra).
	_tube_d.shadow_algorithm = ALGO.CONE_TRACED
	_tube_d.source_radius = 60.0
	await frames(2)
	img = await capture()
	check_gt(c, "source_radius 60: the end-on umbra re-brightens behind the 20 px box", lum(img, P_AX),
			results[ALGO.CONE_TRACED]["ax"], 0.05)
	_tube_d.source_radius = 2.0
	_tube_d.name = "TubeD"
	end_box.name = "EndBox"
	side_box.name = "SideBox"
	await frames(2)


# --- C: cookies --------------------------------------------------------------------------------

func _cookies() -> void:
	var c := "line_cookie"
	var l := line_light(CC, 160.0, 100.0, 0.6, 100.0)
	l.falloff = 0.0
	var half_tex := tex_fn(64, 64, func(x: int, _y: int) -> Color:
		return Color.WHITE if x < 32 else Color.TRANSPARENT)
	name_texture(half_tex, "left-half cookie")
	await frames(1)
	var img := await capture()
	var on := _exp(0.0, 100.0, 0.6, 0.0, 100.0)
	check_approx(c, "no cookie: the left end cap is lit", on, lum(img, CC + Vector2(-80, 0)), TOL)
	l.texture = half_tex
	await frames(3)
	img = await capture()
	check_gt(c, "NATIVE cookie: its opaque half (15 px left of the node) is lit", lum(img, CC + Vector2(-15, 0), 2), AMBIENT, 0.3)
	check_approx(c, "NATIVE cookie: its transparent half masks the segment 15 px right of the node", AMBIENT,
			lum(img, CC + Vector2(15, 0), 2), TOL)
	check_approx(c, "NATIVE cookie is centered on the node, not Q: the left end cap outside it is dark", AMBIENT,
			lum(img, CC + Vector2(-80, 0)), TOL)
	l.texture_size_mode = LitShaderLibrary.TextureSizeMode.FIT_RANGE
	await frames(2)
	img = await capture()
	check_gt(c, "FIT_RANGE spans the capsule's box: 150 px left of the node (70 px past the cap) is lit",
			lum(img, CC + Vector2(-150, 0)), AMBIENT, 0.25)
	check_gt(c, "FIT_RANGE: the left end cap is lit", lum(img, CC + Vector2(-80, 0)), AMBIENT, 0.3)
	check_approx(c, "FIT_RANGE: the transparent half still masks the right end cap", AMBIENT, lum(img, CC + Vector2(80, 0)), TOL)
	check_gt(c, "FIT_RANGE: 60 px above the node (inside the range half-extent) is lit", lum(img, CC + Vector2(-20, -60)), AMBIENT, 0.15)
	l.texture_scale = 0.5
	await frames(2)
	img = await capture()
	check_approx(c, "FIT_RANGE texture_scale 0.5: 150 px left is outside the halved footprint", AMBIENT,
			lum(img, CC + Vector2(-150, 0)), TOL)
	check_gt(c, "FIT_RANGE texture_scale 0.5: the left end cap (80 px, inside 90) still lit", lum(img, CC + Vector2(-80, 0)), AMBIENT, 0.3)
	l.texture_scale = 1.0
	l.texture_size_mode = LitShaderLibrary.TextureSizeMode.NATIVE
	l.texture_offset = Vector2(100.0, 0.0)
	await frames(2)
	img = await capture()
	check_gt(c, "texture_offset (100, 0) slides the cookie: 85 px right of the node is now lit",
			lum(img, CC + Vector2(85, 0), 2), AMBIENT, 0.3)
	check_approx(c, "texture_offset (100, 0): 15 px left of the node is dark", AMBIENT, lum(img, CC + Vector2(-15, 0), 2), TOL)
	l.texture_offset = Vector2.ZERO
	l.texture = null
	await frames(3)
	img = await capture()
	check_approx(c, "cookie cleared: the left end cap is lit again", on, lum(img, CC + Vector2(-80, 0)), TOL)
	l.name = "TubeC"


# --- C: API and registry ------------------------------------------------------------------------

func _api() -> void:
	var c := "line_api"
	var reg = get_node("/root/LitManager")._registry
	var fresh := LitLineLight2D.new()
	var any: Variant = fresh
	check_true(c, "LitLineLight2D is a LitPositionalLight2D", fresh is LitPositionalLight2D)
	check_true(c, "LitLineLight2D is a LitLight2D", fresh is LitLight2D)
	check_true(c, "LitLineLight2D is not a LitPointLight2D or LitSpotLight2D", not (any is LitPointLight2D) and not (any is LitSpotLight2D))
	check(c, "fresh length 128", 128.0, fresh.length)
	check(c, "fresh width 0 (an ideal line)", 0.0, fresh.width)
	check(c, "fresh glow 1 (the halo runs into the beam)", 1.0, fresh.glow)
	fresh.glow = 2.0
	check(c, "glow clamps to 1", 1.0, fresh.glow)
	check(c, "fresh range 256 (point-light defaults)", 256.0, fresh.range)
	fresh.length = -5.0
	check(c, "a negative length clamps to 0", 0.0, fresh.length)
	check_true(c, "inherits the PointLight2D method names", fresh.has_method("set_texture") and fresh.has_method("set_texture_offset")
			and fresh.has_method("set_item_cull_mask") and fresh.has_method("set_energy"))
	check_true(c, "no set_max_distance (directional only)", not fresh.has_method("set_max_distance"))
	fresh.free()

	# Registry plumbing on the cookie exhibit's light.
	var l := get_node("TubeC") as LitLineLight2D
	var cache = reg._light_cache
	var i: int = cache._index.get(l.get_instance_id(), -1)
	check_true(c, "the light cache mirrors the line light", i >= 0)
	if i >= 0:
		check(c, "light cache kind 3 = line", 3, cache._kinds[i])
		check_approx(c, "light cache mirrors the length", 160.0, cache._lengths[i], 0.001)
		check_approx(c, "light cache mirrors the range", 100.0, cache._ranges[i], 0.001)
	l.length = 150.0
	await frames(1)
	if i >= 0:
		check_approx(c, "a length edit reaches the mirror next frame", 150.0, cache._lengths[i], 0.001)
	check_true(c, "in the lit_lights group", l.is_in_group("lit_lights"))
	var row: int = reg._ctx.visible.find(l)
	check_true(c, "packed this frame", row >= 0)
	if row >= 0:
		var packer = reg._light_packer
		var o: int = row * packer._tpl * 4
		check(c, "packed type bits = 3 (flags bits 20-21)", 3, (int(round(packer._pack_buf[o + 1])) >> 20) & 3)
		check_approx(c, "texel 4.x: half-vector along +x = length / 2 in screen px", 75.0, packer._pack_buf[o + 16], 0.01)
		check_approx(c, "texel 4.y: no y component unrotated", 0.0, packer._pack_buf[o + 17], 0.01)
		check_approx(c, "texel 4.z: glow 1", 1.0, packer._pack_buf[o + 18], 0.001)
		l.glow = 0.4
		await frames(1)
		check_approx(c, "texel 4.z: glow 0.4", 0.4, packer._pack_buf[o + 18], 0.001)
		l.glow = 1.0
		check_approx(c, "texel 1.z: range", 100.0, packer._pack_buf[o + 6], 0.01)
		check_approx(c, "texel 4.w: half width 0", 0.0, packer._pack_buf[o + 19], 0.01)
		l.width = 30.0
		l.rotation = PI / 2.0
		await frames(1)
		check_approx(c, "rotated 90: the half-vector turns to +y", 75.0, packer._pack_buf[o + 17], 0.01)
		check_approx(c, "rotated 90: x component 0", 0.0, packer._pack_buf[o + 16], 0.01)
		check_approx(c, "texel 4.w: width 30 packs its half (15)", 15.0, packer._pack_buf[o + 19], 0.01)
		l.scale = Vector2(2.0, 1.0)
		await frames(1)
		check_approx(c, "scale (2, 1) rotated 90: the segment follows the node's x axis (150)", 150.0,
				packer._pack_buf[o + 17], 0.01)
		check_approx(c, "scale (2, 1): range packs x the larger axis (200)", 200.0, packer._pack_buf[o + 6], 0.01)
		check_approx(c, "scale (2, 1): the half width packs x the larger axis too (30)", 30.0, packer._pack_buf[o + 19], 0.01)
		l.width = 1000.0
		await frames(1)
		check_approx(c, "a width past the range packs its half clamped to 0.9 x range (180)", 180.0,
				packer._pack_buf[o + 19], 0.01)
		l.width = 0.0
		l.scale = Vector2.ONE
		l.rotation = 0.0
		l.length = 0.0
		await frames(1)
		check_approx(c, "length 0 packs a zero half-vector", 0.0, packer._pack_buf[o + 16], 0.001)
	l.length = 160.0

	# Capsule culling: a line whose node sits off screen but whose segment reaches the
	# view is packed; the same node as a point light is culled.
	var far := line_light(Vector2(-300, 900), 800.0, 50.0, 0.6, 100.0)
	await frames(2)
	var img := await capture()
	check_true(c, "off-screen node, on-screen segment: not culled", reg._ctx.visible.has(far))
	check_gt(c, "the on-screen part of the segment lights the floor", lum(img, Vector2(60, 900)), AMBIENT, 0.3)
	far.length = 0.0
	await frames(2)
	img = await capture()
	check_true(c, "length 0 (a point 300 px off screen, range 50): culled", not reg._ctx.visible.has(far))
	check_approx(c, "culled: the floor is ambient", AMBIENT, lum(img, Vector2(60, 900)), TOL)
	far.length = 800.0
	far.rotation = PI / 2.0
	await frames(2)
	img = await capture()
	check_true(c, "rotated to run along y off screen: culled", not reg._ctx.visible.has(far))
	check_approx(c, "rotated off screen: ambient", AMBIENT, lum(img, Vector2(60, 900)), TOL)
	far.queue_free()
	await frames(1)
	check_true(c, "the world SDF hull takes both endpoints (shadow-casting tubes present)",
			reg._world_sdf._wsdf_vp != null)


# --- C: luminance mirror -------------------------------------------------------------------------

func _luminance() -> void:
	var c := "line_luminance"
	var mgr := get_node("/root/LitManager")
	var l := get_node("TubeC") as LitLineLight2D
	var img := await capture()
	var pts := {"on the segment": CC, "80 px beside": CC + Vector2(0, 80), "70 px past the right end cap": CC + Vector2(150, 0),
			"110 px beside (beyond range)": CC + Vector2(0, 110)}
	for desc in pts:
		var p: Vector2 = pts[desc]
		check_approx(c, "sample_luminance %s matches the render" % desc, lum(img, p),
				mgr.sample_luminance(p), TOL)
	check_gt(c, "past the end cap is lit (Q, not the node, sets the distance)",
			mgr.sample_luminance(CC + Vector2(150, 0)), AMBIENT, 0.2)
	# A hard shadow (Raymarched): the mirror's segment test agrees with the render.
	l.shadow_enabled = true
	l.shadow_algorithm = ALGO.RAYMARCHED
	l.shadow_hardness = 1.0
	var post := occluder(Vector2(300, 760), Vector2(60, 10), _props)
	await frames(3)
	img = await capture()
	var behind := CC + Vector2(0, 85)
	check_approx(c, "behind the post: rendered umbra", AMBIENT, lum(img, behind), 0.06)
	check_approx(c, "behind the post: sampled umbra", lum(img, behind), mgr.sample_luminance(behind), 0.06)
	var clear := CC + Vector2(60, 85)
	check_gt(c, "beside the post: rendered lit", lum(img, clear), AMBIENT, 0.15)
	check_approx(c, "beside the post: sampled lit", lum(img, clear), mgr.sample_luminance(clear), TOL)
	post.queue_free()
	l.shadow_enabled = false
	# get_luminance on a sprite past the end cap.
	var box := box_receiver(CC + Vector2(150, 0), Vector2(20, 20))
	box.specular_strength = 0.0
	await frames(3)
	img = await capture()
	check_approx(c, "get_luminance on a box 70 px past the end cap matches its rendered mean",
			mean_lum(img, Rect2(box.position - Vector2(8, 8), Vector2(16, 16))), box.get_luminance(), TOL)
	box.queue_free()
	await frames(1)


# --- C: z ranges -----------------------------------------------------------------------------------

func _ranges() -> void:
	var c := "line_ranges"
	var l := get_node("TubeC") as LitLineLight2D
	var img := await capture()
	check_gt(c, "default ranges: the z 0 floor is lit", lum(img, CC), AMBIENT, 0.3)
	l.set_z_range_min(5)
	await frames(2)
	img = await capture()
	check_approx(c, "set_z_range_min(5) excludes the z 0 floor", AMBIENT, lum(img, CC), TOL)
	l.set_z_range_min(-4096)
	l.range_layer_min = 1
	await frames(2)
	img = await capture()
	check_approx(c, "range_layer_min 1 excludes the base canvas", AMBIENT, lum(img, CC), TOL)
	l.range_layer_min = -4096
	await frames(2)
	img = await capture()
	check_gt(c, "ranges restored: lit again", lum(img, CC), AMBIENT, 0.3)


# --- D: camera zoom invariance ---------------------------------------------------------------------

func _camera() -> void:
	var c := "line_camera"
	_tube_d.shadow_algorithm = ALGO.CONE_TRACED
	await frames(2)
	var img := await capture()
	var base := {"umbra behind the end-on box": lum(img, P_AX), "6 px outside the end-on edge": lum(img, P_EDGE, 1),
			"beside the broadside box": lum(img, P_SIDE), "lit floor": lum(img, Vector2(1040, 700))}
	# Centred so every probe stays left of the HUD panel (screen x < 1400) under zoom 2.
	_cam = Camera2D.new()
	_cam.position = Vector2(1200, 840)
	add_child(_cam)
	_cam.make_current()
	_cam.zoom = Vector2(2, 2)
	await frames(3)
	img = await capture()
	for k in base:
		check_approx(c, "zoom 2: %s reads as without a camera" % k, base[k], lum(img, _probe_pt(k), 1 if "edge" in k else 3), TOL)
	_cam.zoom = Vector2(0.5, 0.5)
	await frames(3)
	img = await capture()
	for k in ["umbra behind the end-on box", "beside the broadside box", "lit floor"]:
		check_approx(c, "zoom 0.5: %s reads as without a camera" % k, base[k], lum(img, _probe_pt(k)), TOL)
	_cam.enabled = false
	await frames(2)
	get_viewport().canvas_transform = Transform2D()
	await frames(2)
	img = await capture()
	check_approx(c, "camera off: the umbra reads as before", base["umbra behind the end-on box"], lum(img, P_AX), TOL)


func _probe_pt(k: String) -> Vector2:
	match k:
		"umbra behind the end-on box": return P_AX
		"6 px outside the end-on edge": return P_EDGE
		"beside the broadside box": return P_SIDE
	return Vector2(1040, 700)


func _exit_tree() -> void:
	if _cam != null and is_instance_valid(_cam):
		_cam.enabled = false
	get_viewport().canvas_transform = Transform2D()
	super()
