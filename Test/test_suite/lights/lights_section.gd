extends LitSuiteSection

## The three light types and their shading contract, checked against the rendered
## frame: LitPointLight2D (range, falloff, energy, colour, height, node scale, enabled
## and visibility gates, additive vs subtractive blend), LitSpotLight2D (aim, cone
## angle, edge softness), LitDirectionalLight2D (uniform across the screen, direction
## from rotation, height as elevation, the receiver's horizontal scale), light masks,
## and the headline feature: an uncapped number of lights all contributing at once.
##
## Every numeric expectation is the receiver shader's diffuse term on a flat white
## receiver (normal (0,0,1), specular off): albedo x ambient + energy x
## (height / sqrt(d^2 + height^2)) x (1 - d / range)^falloff, times the pinned
## model's diffuse factor (1 under Blinn-Phong, 0.96 under PBR: see diffuse_scale()).

const AMBIENT := 0.3
const TOL := 0.03

var _floor_a: LitSprite2D
var _floor_b: LitSprite2D
var _floor_c: LitSprite2D
var _floor_d: LitSprite2D


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	label("point light: range / falloff / energy / colour / scale / gates / subtract",
			Vector2(24, 74))
	label("spot light: aim, cone angle, softness  +  light masks", Vector2(704, 74))
	label("directional light: uniform, rotation, height, normal maps", Vector2(24, 544))
	label("70 point lights at once (no light cap)", Vector2(704, 544))
	_floor_a = floor_receiver(Rect2(20, 90, 660, 430))
	_floor_b = floor_receiver(Rect2(700, 90, 680, 430))
	_floor_c = floor_receiver(Rect2(20, 560, 660, 480))
	_floor_d = floor_receiver(Rect2(700, 560, 680, 480))
	await frames(2)

	await _point_light()
	await _spot_light()
	await _light_masks()
	await _directional_light()
	await _many_lights()


# --- Point light ---------------------------------------------------------------------------

func _expected_point(d: float, p_range: float, energy: float, falloff: float, height: float) -> float:
	if d > p_range:
		return AMBIENT
	var atten := pow(clampf(1.0 - d / p_range, 0.0, 1.0), falloff)
	var ndotl := height / sqrt(d * d + height * height)
	var c := energy * ndotl * atten
	return AMBIENT + (c * diffuse_scale() if c >= 0.004 else 0.0)


## Ambient plus a direct contribution of `c` under the pinned model.
func _lit(c: float) -> float:
	return AMBIENT + c * diffuse_scale()


func _point_light() -> void:
	var case_name := "point_light"
	var center := Vector2(350, 300)
	var l := point_light(center, 300.0, 0.5, Color.WHITE, 100.0)
	await frames(1)
	var img := await capture()
	var pts := {"at the light": 0.0, "150 px away": 150.0, "320 px away (beyond range)": 320.0}
	for desc in pts:
		var d: float = pts[desc]
		check_approx(case_name, "diffuse %s" % desc, _expected_point(d, 300.0, 0.5, 1.0, 100.0),
				lum(img, center + Vector2(d, 0)), TOL)
	# Near the range end the light adds only 0.0385 over ambient: a tight tolerance so
	# "no light at all" cannot pass.
	check_approx(case_name, "diffuse 240 px away (near the range end)",
			_expected_point(240.0, 300.0, 0.5, 1.0, 100.0), lum(img, center + Vector2(240, 0)), 0.015)
	check_approx(case_name, "radially symmetric (150 px above)",
			lum(img, center + Vector2(150, 0)), lum(img, center + Vector2(0, -150)), TOL)

	l.falloff = 2.0
	img = await capture()
	check_approx(case_name, "falloff 2 at 150 px", _expected_point(150.0, 300.0, 0.5, 2.0, 100.0),
			lum(img, center + Vector2(150, 0)), TOL)
	l.falloff = 0.0
	img = await capture()
	check_approx(case_name, "falloff 0 at 150 px (no attenuation, only elevation)",
			_expected_point(150.0, 300.0, 0.5, 0.0, 100.0), lum(img, center + Vector2(150, 0)), TOL)
	l.falloff = 1.0

	l.energy = 0.2
	img = await capture()
	check_approx(case_name, "energy 0.2 at the light", _lit(0.2), lum(img, center), TOL)
	l.energy = 0.5

	l.height = 300.0
	img = await capture()
	check_approx(case_name, "height 300 at 150 px (more head-on: brighter)",
			_expected_point(150.0, 300.0, 0.5, 1.0, 300.0), lum(img, center + Vector2(150, 0)), TOL)
	l.height = 100.0

	l.color = Color(1.0, 0.0, 0.0)
	img = await capture()
	var c := probe(img, center)
	check_approx(case_name, "red light: red channel", _lit(0.5), c.r, TOL)
	check_approx(case_name, "red light: green channel stays ambient", AMBIENT, c.g, TOL)
	l.color = Color.WHITE

	l.range = 150.0
	img = await capture()
	check_approx(case_name, "range 150: 200 px away is ambient", AMBIENT,
			lum(img, center + Vector2(200, 0)), TOL)
	l.range = 300.0

	img = await capture()
	check_approx(case_name, "300 px away (at the range end): ambient", AMBIENT,
			lum(img, center + Vector2(-300, 0)), TOL)
	l.scale = Vector2(2.0, 2.0)
	img = await capture()
	check_approx(case_name, "node scale 2 doubles the range (300 px away now lit)",
			_expected_point(300.0, 600.0, 0.5, 1.0, 100.0), lum(img, center + Vector2(-300, 0)), TOL)
	# 150 px out under scale 2: 0.508 with the height unscaled, 0.600 if it doubled too
	# (at the light itself ndotl is 1 for any height, so that probe would prove nothing).
	check_approx(case_name, "node scale 2 leaves height alone (150 px away)",
			_expected_point(150.0, 600.0, 0.5, 1.0, 100.0), lum(img, center + Vector2(150, 0)), TOL)
	l.scale = Vector2.ONE

	l.enabled = false
	img = await capture()
	check_approx(case_name, "enabled = false: ambient only", AMBIENT, lum(img, center), TOL)
	l.enabled = true
	l.visible = false
	img = await capture()
	check_approx(case_name, "visible = false: ambient only", AMBIENT, lum(img, center), TOL)
	l.visible = true
	img = await capture()
	check_approx(case_name, "re-enabled and visible: lit again", _lit(0.5), lum(img, center), TOL)

	l.position = center + Vector2(200, 0)
	img = await capture()
	check_approx(case_name, "moved light: old spot now 200 px away",
			_expected_point(200.0, 300.0, 0.5, 1.0, 100.0), lum(img, center), TOL)
	l.position = center

	# Subtractive blend carves below ambient.
	l.blend_mode = LitPointLight2D.BlendMode.SUBTRACT
	l.energy = 0.2
	img = await capture()
	check_approx("negative_light", "subtract energy 0.2 at the light: ambient - 0.2", AMBIENT - 0.2 * diffuse_scale(),
			lum(img, center), TOL)
	check_approx("negative_light", "subtract at 150 px: partial carve",
			AMBIENT - (_expected_point(150.0, 300.0, 0.2, 1.0, 100.0) - AMBIENT),
			lum(img, center + Vector2(150, 0)), TOL)
	l.energy = 2.0
	img = await capture()
	check_approx("negative_light", "large subtract clamps at black", 0.0, lum(img, center), TOL)
	l.blend_mode = LitPointLight2D.BlendMode.ADD
	l.energy = 0.5
	img = await capture()
	check_approx("negative_light", "back to additive", _lit(0.5), lum(img, center), TOL)

	# Light freed at runtime.
	l.queue_free()
	await frames(1)
	img = await capture()
	check_approx(case_name, "freed light: ambient only", AMBIENT, lum(img, center), TOL)
	# Marker + a resident light so the exhibit stays lit for the rest of the section.
	var keep := point_light(center, 300.0, 0.5, Color.WHITE, 100.0)
	keep.name = "PointExhibit"


# --- Spot light -------------------------------------------------------------------------------

func _spot_light() -> void:
	var case_name := "spot_light"
	var center := Vector2(1000, 300)
	var s := spot_light(center, 0.0, 300.0, 0.5, Color.WHITE, 100.0)
	s.spot_angle = 30.0
	s.spot_softness = 0.5
	await frames(1)
	var img := await capture()
	check_approx(case_name, "on the aim axis 150 px ahead: full point-light diffuse",
			_expected_point(150.0, 300.0, 0.5, 1.0, 100.0), lum(img, center + Vector2(150, 0)), TOL)
	check_approx(case_name, "150 px behind the spot: ambient", AMBIENT,
			lum(img, center + Vector2(-150, 0)), TOL)
	var off45 := center + Vector2(106, 106)
	check_approx(case_name, "45 degrees off axis with a 30 degree cone: ambient", AMBIENT,
			lum(img, off45), TOL)
	s.spot_angle = 80.0
	img = await capture()
	check_gt(case_name, "45 degrees off axis with an 80 degree cone: lit", lum(img, off45),
			AMBIENT, 0.1)
	s.spot_angle = 30.0

	# Softness: 25 degrees off axis is inside the outer edge; a hard cone lights it fully.
	var off25 := center + Vector2(cos(deg_to_rad(25.0)), sin(deg_to_rad(25.0))) * 150.0
	s.spot_softness = 0.0
	img = await capture()
	var hard := lum(img, off25)
	check_approx(case_name, "softness 0: 25 degrees off axis fully lit",
			_expected_point(150.0, 300.0, 0.5, 1.0, 100.0), hard, TOL)
	s.spot_softness = 1.0
	img = await capture()
	check_lt(case_name, "softness 1: 25 degrees off axis dimmer than the hard cone", lum(img, off25),
			hard, 0.05)
	s.spot_softness = 0.5

	s.rotation = PI
	img = await capture()
	check_approx(case_name, "rotated 180: the point behind is now lit",
			_expected_point(150.0, 300.0, 0.5, 1.0, 100.0), lum(img, center + Vector2(-150, 0)), TOL)
	check_approx(case_name, "rotated 180: the point ahead is now ambient", AMBIENT,
			lum(img, center + Vector2(150, 0)), TOL)
	s.rotation = 0.0
	s.color = Color(0.2, 0.4, 1.0)
	img = await capture()
	var c := probe(img, center + Vector2(150, 0))
	check_gt(case_name, "tinted spot: blue over red on the axis", c.b, c.r, 0.1)
	s.color = Color.WHITE
	s.enabled = false
	img = await capture()
	check_approx(case_name, "enabled = false: ambient on the axis", AMBIENT,
			lum(img, center + Vector2(150, 0)), TOL)
	s.enabled = true
	s.blend_mode = LitShaderLibrary.BlendMode.SUBTRACT
	s.energy = 0.2
	img = await capture()
	check_approx(case_name, "subtractive spot: carves energy x point-light diffuse below ambient on the axis",
			AMBIENT - (_expected_point(150.0, 300.0, 0.2, 1.0, 100.0) - AMBIENT), lum(img, center + Vector2(150, 0)), TOL)
	check_approx(case_name, "subtractive spot: nothing behind the cone", AMBIENT, lum(img, center + Vector2(-150, 0)), TOL)
	s.blend_mode = LitShaderLibrary.BlendMode.ADD
	s.energy = 0.5
	s.enabled = false
	s.enabled = true


# --- Light masks ---------------------------------------------------------------------------------

func _light_masks() -> void:
	var case_name := "light_masks"
	var a := box_receiver(Vector2(780, 460), Vector2(60, 60))
	var b := box_receiver(Vector2(860, 460), Vector2(60, 60))
	a.specular_strength = 0.0
	b.specular_strength = 0.0
	a.receiver_mask = 1
	b.receiver_mask = 3
	var l := point_light(Vector2(820, 460), 120.0, 0.5, Color.WHITE, 200.0)
	l.light_mask = 2
	await frames(1)
	var img := await capture()
	check_approx(case_name, "light_mask 2 vs receiver_mask 1: not lit", AMBIENT, lum(img, a.position), TOL)
	check_gt(case_name, "light_mask 2 vs receiver_mask 3: lit", lum(img, b.position), AMBIENT, 0.2)
	check_approx(case_name, "floor (receiver_mask 1) under the mask-2 light stays ambient", AMBIENT,
			lum(img, Vector2(820, 400)), TOL)
	l.light_mask = 1
	img = await capture()
	check_gt(case_name, "light_mask 1: receiver_mask 1 now lit", lum(img, a.position), AMBIENT, 0.2)
	check_gt(case_name, "light_mask 1: receiver_mask 3 still lit", lum(img, b.position), AMBIENT, 0.2)
	a.receiver_mask = 4
	img = await capture()
	check_approx(case_name, "receiver_mask 4 vs light_mask 1: not lit", AMBIENT, lum(img, a.position), TOL)
	a.receiver_mask = 1


# --- Directional light --------------------------------------------------------------------------

func _expected_directional(energy: float, height: float, horizontal_scale := 32.0) -> float:
	var ldir := Vector3(-horizontal_scale, 0.0, height).normalized()
	return AMBIENT + energy * maxf(ldir.z, 0.0) * diffuse_scale()


func _directional_light() -> void:
	var case_name := "directional_light"
	var d := directional_light(0.0, 0.4, Color.WHITE, 16.0)
	var p1 := Vector2(100, 700)
	var p2 := Vector2(600, 1000)
	await frames(1)
	var img := await capture()
	check_approx(case_name, "flat receiver: energy x elevation (height 16 over scale 32)",
			_expected_directional(0.4, 16.0), lum(img, p1), TOL)
	check_approx(case_name, "uniform across the screen (second probe 580 px away)",
			lum(img, p1), lum(img, p2), 0.015)
	d.height = 64.0
	img = await capture()
	check_approx(case_name, "height 64: more head-on, brighter", _expected_directional(0.4, 64.0),
			lum(img, p1), TOL)
	d.height = 16.0
	_floor_c.directional_horizontal_scale = 8.0
	img = await capture()
	check_approx(case_name, "receiver directional_horizontal_scale 8: same elevation as height 64",
			_expected_directional(0.4, 16.0, 8.0), lum(img, p1), TOL)
	_floor_c.directional_horizontal_scale = 32.0
	d.energy = 0.8
	img = await capture()
	check_approx(case_name, "energy 0.8", _expected_directional(0.8, 16.0), lum(img, p1), TOL)
	d.energy = 0.4
	d.enabled = false
	img = await capture()
	check_approx(case_name, "enabled = false: ambient", AMBIENT, lum(img, p1), TOL)
	d.enabled = true
	d.blend_mode = LitShaderLibrary.BlendMode.SUBTRACT
	d.energy = 0.2
	img = await capture()
	check_approx(case_name, "subtractive directional: carves energy x elevation below ambient everywhere",
			AMBIENT - (_expected_directional(0.2, 16.0) - AMBIENT), lum(img, p1), TOL)
	d.blend_mode = LitShaderLibrary.BlendMode.ADD
	d.energy = 0.4

	# Direction: normal-mapped tiles facing left and right. Rotation 0 travels +X, so
	# the light comes from the left and the left-facing tile is the bright one.
	var left := box_receiver(Vector2(250, 850), Vector2(80, 80), Color.WHITE, null, tex_normal(8, -1.0))
	var right := box_receiver(Vector2(350, 850), Vector2(80, 80), Color.WHITE, null, tex_normal(8, 1.0))
	var flat := box_receiver(Vector2(450, 850), Vector2(80, 80))
	for n in [left, right, flat]:
		n.specular_strength = 0.0
	label("normal: left   right   flat", Vector2(210, 900))
	img = await capture()
	var l_lum := lum(img, left.position)
	var r_lum := lum(img, right.position)
	var f_lum := lum(img, flat.position)
	check_gt(case_name, "rotation 0 (from the left): left-facing normal brighter than flat", l_lum, f_lum, 0.05)
	check_lt(case_name, "rotation 0: right-facing normal darker than flat", r_lum, f_lum, 0.05)
	d.rotation = PI
	img = await capture()
	check_gt(case_name, "rotation 180 (from the right): right-facing normal now the bright one",
			lum(img, right.position), lum(img, flat.position), 0.05)
	check_lt(case_name, "rotation 180: left-facing normal now dark", lum(img, left.position),
			lum(img, flat.position), 0.05)
	d.rotation = 0.0
	d.color = Color(1.0, 0.5, 0.1)
	img = await capture()
	var c := probe(img, p1)
	check_gt(case_name, "tinted sun: red over blue", c.r, c.b, 0.1)
	d.color = Color.WHITE
	d.name = "Sun"


# --- Many lights -------------------------------------------------------------------------------

func _many_lights() -> void:
	var case_name := "many_lights"
	var origin := Vector2(740, 600)
	# The directional exhibit stays on, so the floor's resting level is measured, not assumed.
	var img := await capture()
	var resting := peak(img, origin + Vector2(32, 32), 1)
	check_approx(case_name, "resting level before the grid (ambient + the exhibit sun)",
			_expected_directional(0.4, 16.0), resting, 0.05)
	var lights: Array = []
	for row in 7:
		for col in 10:
			var l := point_light(origin + Vector2(col * 64, row * 64), 40.0, 0.6,
					Color.from_hsv(float(col * 7 + row) / 70.0, 0.5, 1.0), 200.0)
			lights.append(l)
	await frames(2)
	img = await capture()
	var lit := 0
	var min_lum := 1.0
	for l in lights:
		var v := peak(img, l.position, 2)
		min_lum = minf(min_lum, v)
		if v > resting + 0.35:
			lit += 1
	check(case_name, "all 70 lights light their own spot (no 15-light cap)", 70, lit)
	check_gt(case_name, "dimmest light spot still well above the resting level", min_lum, resting, 0.35)
	check_approx(case_name, "between four lights (out of every range): resting level", resting,
			peak(img, origin + Vector2(32, 32), 1), 0.05)
	check_true(case_name, "lit_lights group holds every light in the section",
			get_tree().get_nodes_in_group("lit_lights").size() >= 70)
	# One removed at runtime goes dark, the rest stay.
	var gone: LitPointLight2D = lights[35]
	var gone_pos: Vector2 = gone.position
	gone.queue_free()
	await frames(1)
	img = await capture()
	check_approx(case_name, "a freed light's spot returns to the resting level", resting, peak(img, gone_pos, 2), 0.05)
	check_gt(case_name, "its neighbour is still lit", peak(img, lights[36].position, 2), resting, 0.35)
