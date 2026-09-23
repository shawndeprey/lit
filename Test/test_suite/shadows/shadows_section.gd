extends LitSuiteSection

## Shadows: enable/disable, the three algorithms (Raymarched, Cone Traced, Stochastic)
## each casting an umbra and shaping a penumbra (hardness, source radius / angle,
## samples, jitter), shadow colour, shadow length, occluder visibility and SDF
## collision gates, moving occluders, footprint darkening, directional light shadows
## (direction, length, reach, source angle), spot light shadows, and the quality
## project settings (step scaling, max steps, max samples, receiver march dials).

const AMBIENT := 0.1
const TOL := 0.03
const ALGO := LitShaderLibrary.ShadowAlgorithm

var _floor_a: LitSprite2D
var _light: LitPointLight2D
var _box: LightOccluder2D
var _props: Node2D


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_props = group("Props")
	label("point light shadows: algorithms, hardness, source radius, colour, length, footprint",
			Vector2(24, 74))
	label("directional light shadows: direction, length, reach, source angle", Vector2(704, 74))
	label("spot light shadows", Vector2(24, 544))
	label("quality settings: step scaling, max steps, max samples, receiver dials", Vector2(704, 544))
	_floor_a = floor_receiver(Rect2(20, 90, 660, 430))
	floor_receiver(Rect2(700, 90, 680, 430))
	floor_receiver(Rect2(20, 560, 660, 480))
	floor_receiver(Rect2(700, 560, 680, 480))
	await frames(2)
	await _point_shadows()
	await _directional_shadows()
	await _spot_shadows()
	await _quality()
	(get_node("Sun") as LitDirectionalLight2D).enabled = true


# Light L at the left, box B in the middle, probe S behind the box; P sits outside
# the shadow band. The geometric umbra edge at x = 520 is y = 200; E_OUT sits 30 px
# outside it (a soft penumbra darkens it), E_IN 30 px inside (a wide source lights it).
const L := Vector2(120, 300)
const B := Vector2(330, 300)
const S := Vector2(520, 300)
const P := Vector2(520, 120)
const E_OUT := Vector2(520, 170)
const E_IN := Vector2(520, 230)
const F := Vector2(330, 300)   # inside the box footprint


func _point_shadows() -> void:
	var case_name := "shadow_basics"
	# Range 500: reaches every probe in this region and none in the others.
	_light = point_light(L, 500.0, 0.8, Color.WHITE, 300.0)
	_light.falloff = 0.3
	_box = occluder(B, Vector2(40, 100), _props)
	await frames(3)
	var img := await capture()
	var lit_ref := lum(img, S)
	check_gt(case_name, "shadows off: the point behind the box is lit", lit_ref, AMBIENT, 0.25)
	_light.shadow_enabled = true
	await frames(2)
	img = await capture()
	check_approx(case_name, "shadow_enabled: the point behind the box is ambient (Cone Traced default)",
			AMBIENT, lum(img, S), TOL)
	check_gt(case_name, "outside the shadow band: still lit", lum(img, P), AMBIENT, 0.15)
	check_gt(case_name, "between light and box: lit", lum(img, Vector2(230, 300)), AMBIENT, 0.25)

	_light.shadow_color = Color(1.0, 0.0, 0.0)
	img = await capture()
	var c := probe(img, S)
	check_gt(case_name, "red shadow colour tints the shadowed light (red stays)", c.r, AMBIENT, 0.25)
	check_approx(case_name, "red shadow colour: green channel ambient", AMBIENT, c.g, TOL)
	_light.shadow_color = Color.BLACK

	_light.shadow_length = 0.3
	img = await capture()
	check_gt(case_name, "shadow_length 0.3: the box is beyond the capped march, point lit", lum(img, S),
			AMBIENT, 0.25)
	_light.shadow_length = 1.0
	img = await capture()
	check_approx(case_name, "shadow_length 1: shadow back", AMBIENT, lum(img, S), TOL)

	_box.visible = false
	await frames(2)
	img = await capture()
	check_gt(case_name, "hidden occluder casts nothing", lum(img, S), AMBIENT, 0.25)
	_box.visible = true
	_box.sdf_collision = false
	await frames(2)
	img = await capture()
	check_gt(case_name, "sdf_collision off: no Lit shadow", lum(img, S), AMBIENT, 0.25)
	_box.sdf_collision = true
	await frames(2)
	img = await capture()
	# Box moved 100 px down: rays from L through its corners put the umbra at x = 520
	# between y 405 and 561, 435 px from the light (inside range 500). (520, 470) is lit
	# before the move and 65 px inside the new umbra after it.
	var moved_probe := Vector2(520, 470)
	check_gt(case_name, "before the move: the future shadow spot is lit", lum(img, moved_probe), AMBIENT, 0.2)
	_box.position = B + Vector2(0, 100)
	await frames(2)
	img = await capture()
	check_gt(case_name, "moved occluder: old shadow spot lit", lum(img, S), AMBIENT, 0.25)
	check_approx(case_name, "moved occluder: new shadow spot dark", AMBIENT, lum(img, moved_probe), 0.06)
	_box.position = B
	await frames(2)
	img = await capture()
	check_approx(case_name, "footprint_shadow 16: floor inside the box footprint is dark", AMBIENT, lum(img, F), 0.06)
	_floor_a.footprint_shadow = 0.0
	img = await capture()
	check_gt(case_name, "footprint_shadow 0: floor inside the footprint is lit", lum(img, F), AMBIENT, 0.2)
	_floor_a.footprint_shadow = 16.0
	# footprint_ramp: the interior shadow eases in over world px from the lit edge (x 310).
	var near_edge := Vector2(318, 300)
	_floor_a.footprint_ramp = 40.0
	img = await capture()
	var ramp_edge := lum(img, near_edge)
	check_gt(case_name, "footprint_ramp 40: 8 px inside the lit edge is mostly lit", ramp_edge, AMBIENT, 0.15)
	check_gt(case_name, "footprint_ramp 40: the box centre (20 px in) is only partly shadowed", lum(img, F),
			AMBIENT, 0.05)
	check_lt(case_name, "footprint_ramp 40: deeper in is darker than near the edge", lum(img, F), ramp_edge, 0.05)
	_floor_a.footprint_ramp = 0.0
	img = await capture()
	check_approx(case_name, "footprint_ramp 0: hard edge again", AMBIENT, lum(img, near_edge), 0.06)

	# Algorithms.
	for algo in [ALGO.RAYMARCHED, ALGO.CONE_TRACED, ALGO.STOCHASTIC]:
		var an: String = ["Raymarched", "Cone Traced", "Stochastic"][algo]
		_light.shadow_algorithm = algo
		await frames(2)
		img = await capture()
		check_approx("shadow_algorithms", "%s: umbra behind the box is ambient" % an, AMBIENT, lum(img, S), 0.06)
		check_gt("shadow_algorithms", "%s: outside the band stays lit" % an, lum(img, P), AMBIENT, 0.15)
		# Interior shadow is hard on every algorithm: 8 px inside the box's lit edge.
		check_approx("shadow_algorithms", "%s: box interior 8 px inside its lit edge is dark (no ramp)" % an,
				AMBIENT, lum(img, Vector2(318, 300)), 0.06)
	# Penumbra shaping. Raymarched softness reaches outward from the geometric edge.
	_light.shadow_algorithm = ALGO.RAYMARCHED
	_light.shadow_hardness = 1.0
	await frames(2)
	img = await capture()
	var hard := lum(img, E_OUT)
	check_gt("shadow_algorithms", "Raymarched hardness 1: 30 px outside the edge is lit", hard, AMBIENT, 0.2)
	_light.shadow_hardness = 0.0
	img = await capture()
	check_lt("shadow_algorithms", "Raymarched hardness 0: the soft penumbra darkens outside the edge", lum(img, E_OUT), hard, 0.05)
	_light.shadow_hardness = 0.5
	# Cone traced: a wide source widens the penumbra both ways and closes the umbra
	# behind a small occluder (antumbra), so the deep probe re-brightens.
	_light.shadow_algorithm = ALGO.CONE_TRACED
	_light.source_radius = 2.0
	await frames(2)
	img = await capture()
	var tight_out := lum(img, E_OUT)
	var tight_in := lum(img, E_IN)
	var tight_deep := lum(img, S)
	_light.source_radius = 150.0
	img = await capture()
	check_lt("shadow_algorithms", "Cone Traced: source_radius 150 darkens outside the edge vs 2", lum(img, E_OUT), tight_out, 0.05)
	check_gt("shadow_algorithms", "Cone Traced: source_radius 150 lights inside the edge vs 2", lum(img, E_IN), tight_in, 0.05)
	check_gt("shadow_algorithms", "Cone Traced: the umbra tapers closed behind a small occluder (antumbra brighter)",
			lum(img, S), tight_deep, 0.05)
	# Hardness under the physical algorithms reshapes the penumbra profile without
	# moving its ends (lit_shadow_contrast): outside the edge, harder reads brighter.
	var wide_out := lum(img, E_OUT)   # cone, radius 150, hardness 0.5
	var wide_in := lum(img, E_IN)
	_light.shadow_hardness = 1.0
	img = await capture()
	var hard_out := lum(img, E_OUT)
	_light.shadow_hardness = 0.0
	img = await capture()
	var soft_out := lum(img, E_OUT)
	check_gt("shadow_algorithms", "Cone Traced hardness 1 vs 0: the sharper profile is brighter outside the edge", hard_out, soft_out, 0.04)
	check_between("shadow_algorithms", "Cone Traced hardness 0.5 sits between 0 and 1 outside the edge", wide_out,
			soft_out - 0.01, hard_out + 0.01)
	_light.shadow_hardness = 0.5
	# Stochastic: one sample without jitter degenerates to the cone estimate
	# (lit_shadow_stoch.gdshaderinc); more samples change it and jitter adds per-pixel noise.
	_light.shadow_algorithm = ALGO.STOCHASTIC
	_light.shadow_samples = 1
	_light.shadow_jitter = 0.0
	await frames(2)
	img = await capture()
	check_approx("shadow_algorithms", "Stochastic 1 sample, no jitter: equals the Cone Traced estimate inside the edge",
			wide_in, lum(img, E_IN), 0.04)
	_light.shadow_samples = 16
	_light.shadow_jitter = 1.0
	img = await capture()
	check_gt("shadow_algorithms", "Stochastic: source_radius 150 with 16 samples lights inside the edge vs the tight cone",
			lum(img, E_IN), tight_in, 0.05)
	var band := Rect2(500, 150, 40, 100)   # penumbra column through E_OUT and E_IN
	_light.shadow_samples = 4
	_light.shadow_jitter = 0.0
	img = await capture()
	var v_flat := image_variance(img, band)
	_light.shadow_jitter = 1.0
	img = await capture()
	check_gt("shadow_algorithms", "shadow_jitter 1 with 4 samples: per-pixel noise raises the penumbra's variance",
			image_variance(img, band), v_flat * 1.3)
	_light.source_radius = 8.0
	_light.shadow_samples = 1
	_light.shadow_jitter = 0.0
	img = await capture()
	check_approx("shadow_algorithms", "Stochastic: 1 sample, no jitter, small source still shadows the core", AMBIENT, lum(img, S), 0.08)
	_light.shadow_samples = 8
	_light.shadow_jitter = 0.35
	_light.source_radius = 32.0
	_light.shadow_algorithm = ALGO.CONE_TRACED
	await frames(2)
	check_true("shadow_algorithms", "activity flags publish F_CONE while a cone light casts",
			LitLightRegistry.activity_flags & LitShaderLibrary.F_CONE != 0)


func _directional_shadows() -> void:
	var case_name := "directional_shadows"
	var d := directional_light(0.0, 0.5, Color.WHITE, 40.0)
	d.shadow_enabled = true
	# Its own row: a sun shadows along the whole screen, so nothing else may share it.
	var box := occluder(Vector2(1000, 180), Vector2(40, 100), _props)
	var right := Vector2(1200, 180)
	var left := Vector2(800, 180)
	var edge := Vector2(1200, 142)
	await frames(3)
	var img := await capture()
	check_approx(case_name, "rotation 0 (from the left): shadow falls to the right", AMBIENT, lum(img, right), TOL)
	check_gt(case_name, "rotation 0: the left side is lit", lum(img, left), AMBIENT, 0.2)
	# Footprint under a sun: the box interior past its lit edge is shadowed like any
	# Godot occluder's interior, with no distance ramp.
	check_approx(case_name, "directional footprint: 35 px inside the box's lit edge is dark", AMBIENT,
			lum(img, Vector2(1015, 180)), 0.06)
	check_approx(case_name, "directional footprint: 8 px inside the lit edge is dark too (no ramp)", AMBIENT,
			lum(img, Vector2(988, 180)), 0.06)
	d.rotation = PI
	await frames(2)
	img = await capture()
	check_approx(case_name, "rotation 180 (from the right): shadow falls to the left", AMBIENT, lum(img, left), TOL)
	check_gt(case_name, "rotation 180: the right side is lit", lum(img, right), AMBIENT, 0.2)
	d.rotation = 0.0
	d.shadow_length = 0.0
	await frames(2)
	img = await capture()
	check_gt(case_name, "shadow_length 0: no shadow at all", lum(img, right), AMBIENT, 0.2)
	d.shadow_length = 1.0
	d.shadow_reach = 256.0
	d.shadow_length = 0.25   # 64 px world cap: the box is 180 px from the probe
	await frames(2)
	img = await capture()
	check_gt(case_name, "shadow_reach 256 x length 0.25 (64 px): probe 180 px behind the box is lit",
			lum(img, right), AMBIENT, 0.2)
	d.shadow_length = 1.0
	await frames(2)
	img = await capture()
	check_approx(case_name, "reach 256 x length 1: shadow reaches the probe again", AMBIENT, lum(img, right), TOL)
	d.shadow_reach = 4096.0
	d.source_angle = 0.5
	await frames(2)
	img = await capture()
	var tight := lum(img, edge)
	d.source_angle = 30.0
	img = await capture()
	check_gt(case_name, "source_angle 30 softens the umbra edge vs 0.5", lum(img, edge), tight, 0.05)
	d.source_angle = 6.0
	d.shadow_algorithm = ALGO.RAYMARCHED
	await frames(2)
	img = await capture()
	check_approx(case_name, "Raymarched directional shadow", AMBIENT, lum(img, right), 0.06)
	d.shadow_algorithm = ALGO.STOCHASTIC
	await frames(2)
	img = await capture()
	check_approx(case_name, "Stochastic directional shadow", AMBIENT, lum(img, right), 0.06)
	d.shadow_algorithm = ALGO.CONE_TRACED
	d.shadow_color = Color(0.0, 0.0, 1.0)
	await frames(2)
	img = await capture()
	var c := probe(img, right)
	check_gt(case_name, "blue shadow colour keeps blue in the shadow", c.b, c.r, 0.1)
	d.shadow_color = Color.BLACK
	d.name = "Sun"
	box.name = "SunBox"
	# Off while the spot and quality regions run (its shadows cross every region).
	d.enabled = false
	await frames(2)


func _spot_shadows() -> void:
	var case_name := "spot_shadows"
	var s := spot_light(Vector2(120, 800), 0.0, 900.0, 0.8, Color.WHITE, 300.0)
	s.falloff = 0.3
	s.spot_angle = 40.0
	s.shadow_enabled = true
	var box := occluder(Vector2(330, 800), Vector2(40, 100), _props)
	await frames(3)
	var img := await capture()
	check_approx(case_name, "spot: shadow behind the box", AMBIENT, lum(img, Vector2(520, 800)), TOL)
	check_gt(case_name, "spot: lit beside the band, inside the cone", lum(img, Vector2(520, 690)), AMBIENT, 0.2)
	box.visible = false
	await frames(2)
	img = await capture()
	check_gt(case_name, "spot: hidden box, lit", lum(img, Vector2(520, 800)), AMBIENT, 0.2)
	box.visible = true
	s.shadow_algorithm = ALGO.STOCHASTIC
	await frames(2)
	img = await capture()
	check_approx(case_name, "spot: Stochastic shadow", AMBIENT, lum(img, Vector2(520, 800)), 0.06)
	s.shadow_algorithm = ALGO.CONE_TRACED


## One float of a light's packed row in the CPU upload buffer (row = its index in the
## registry's visible list; texel 7 = source_radius | samples | jitter, floats 28..30).
func _packed(light: Node, float_index: int) -> float:
	var reg = get_node("/root/LitManager")._registry
	var row: int = reg._ctx.visible.find(light)
	if row < 0:
		return -1.0
	var packer = reg._light_packer
	return packer._pack_buf[row * packer._tpl * 4 + float_index]


# Quality dials need a march that a starved or coarse budget cannot finish: the ray from
# the probe to the light grazes a long wall 10 px away (sphere tracing advances ~10 px a
# step there) before reaching a thin blocking wall 250 px out. 64 fixed steps resolve it;
# the 16-step floor of the scaled budget, a 16-step receiver budget and a coarse minimum
# step all hop the blocker (the bounded tail sweep behind the budget takes ~95 px strides).
const Q_L := Vector2(720, 800)
const Q_P := Vector2(1300, 800)

func _quality() -> void:
	var case_name := "shadow_quality_settings"
	var mgr := get_node("/root/LitManager")
	var l := point_light(Q_L, 1200.0, 0.8, Color.WHITE, 300.0)
	l.falloff = 0.3
	l.shadow_enabled = true
	l.shadow_hardness = 1.0
	occluder(Vector2(1075, 815), Vector2(350, 10), _props)   # grazing wall: y 810..820, x 900..1250
	occluder(Vector2(1045, 800), Vector2(10, 200), _props)   # blocker: x 1040..1050, y 700..900
	var floor_d := get_children().filter(func(n): return n is LitSprite2D and n.position == Vector2(1040, 800))[0] as LitSprite2D
	await frames(3)
	var img := await capture()
	check_approx(case_name, "raymarched, 64 fixed steps: the blocker's shadow reaches the probe", AMBIENT, lum(img, Q_P), 0.06)
	# Stochastic sample cap: the packed count clamps, and with a wide source the jittered
	# penumbra at the blocker's shadow edge (y ~619 at x 1300) turns visibly noisier.
	l.shadow_algorithm = ALGO.STOCHASTIC
	l.shadow_samples = 16
	l.shadow_jitter = 1.0
	l.source_radius = 150.0
	await frames(2)
	img = await capture()
	var band := Rect2(1280, 560, 40, 120)
	var v16 := image_variance(img, band)
	check_approx(case_name, "packed shadow_samples 16 under shadow_samples_max 32", 16.0, _packed(l, 29), 0.5)
	set_setting("lit/quality/shadow_samples_max", 2)
	await frames(2)
	img = await capture()
	check(case_name, "manager picked up shadow_samples_max", 2, mgr.shadow_samples_max)
	check_approx(case_name, "shadow_samples_max 2: the packed sample count clamps to 2", 2.0, _packed(l, 29), 0.5)
	# The stochastic estimator stays smooth at any sample count (the strata move, not the
	# noise), so the clamp shows as a shift in the penumbra's statistics, not as grain.
	check_gt(case_name, "shadow_samples_max 2: the penumbra's variance moves by more than 30% vs 16 samples",
			absf(image_variance(img, band) - v16), v16 * 0.3)
	set_setting("lit/quality/shadow_samples_max", 32)
	l.shadow_algorithm = ALGO.RAYMARCHED
	l.source_radius = 2.0
	# Receiver step budget (scaling off): 16 steps stop ~50 px short of the blocker and
	# the tail sweep strides past it.
	floor_d.shadow_steps = 16
	await frames(2)
	img = await capture()
	check_gt(case_name, "receiver shadow_steps 16: the grazing march is starved, the blocker is hopped (probe lit)",
			lum(img, Q_P), AMBIENT, 0.15)
	floor_d.shadow_steps = 64
	await frames(2)
	img = await capture()
	check_approx(case_name, "receiver shadow_steps 64: the march reaches the blocker again", AMBIENT, lum(img, Q_P), 0.06)
	# Step scaling: budget = ceil(march / screen diagonal x steps_max), floored at 16, and
	# the receiver's own dial is ignored. 580 px of 2203: steps_max 48 gives 16 (starved),
	# steps_max 256 gives 68 (resolved).
	set_setting("lit/quality/shadow_step_scaling", true)
	set_setting("lit/quality/shadow_steps_max", 48)
	await frames(2)
	img = await capture()
	check(case_name, "manager picked up shadow_steps_max", 48, mgr.shadow_steps_max)
	check_true(case_name, "receiver shadow_steps reported inert while scaling is on",
			LitReceiverHelper.inactive_reason("shadow_steps") != "")
	check_gt(case_name, "step scaling on, steps_max 48: the 16-step floor starves the march despite the receiver's 64 (probe lit)",
			lum(img, Q_P), AMBIENT, 0.15)
	set_setting("lit/quality/shadow_steps_max", 256)
	await frames(2)
	img = await capture()
	check_approx(case_name, "step scaling on, steps_max 256: a 68-step budget resolves the march (shadow back)",
			AMBIENT, lum(img, Q_P), 0.06)
	set_setting("lit/quality/shadow_step_scaling", false)
	set_setting("lit/quality/shadow_steps_max", 64)
	# Minimum step (SDF texels, ~4.3 px each): the march starts at t = min_step and never
	# strides less, so 40 texels (~170 px) hops the 10 px blocker outright (measured: up
	# to 8 texels still finds it, 16..23 land in its penumbra, 30+ read fully lit).
	floor_d.shadow_min_step = 40.0
	await frames(2)
	img = await capture()
	check_gt(case_name, "receiver shadow_min_step 40 texels: coarse strides hop the thin blocker (probe lit)",
			lum(img, Q_P), AMBIENT, 0.25)
	floor_d.shadow_min_step = 0.2
	await frames(2)
	img = await capture()
	check_approx(case_name, "receiver shadow_min_step 0.2: fine strides find the blocker again", AMBIENT, lum(img, Q_P), 0.06)
	# Light node scale doubles the packed source radius (light_packer.gd) and with it the
	# cone penumbra: a probe just inside the shadow edge loses shadow fraction.
	l.shadow_algorithm = ALGO.CONE_TRACED
	l.source_radius = 20.0
	await frames(2)
	img = await capture()
	check_approx(case_name, "packed source_radius 20 at node scale 1", 20.0, _packed(l, 28), 0.5)
	var edge_in := Vector2(1300, 645)
	var edge_ref := Vector2(1300, 585)
	var frac1 := (lum(img, edge_ref) - lum(img, edge_in)) / maxf(lum(img, edge_ref) - AMBIENT, 0.01)
	l.scale = Vector2(2, 2)
	await frames(2)
	img = await capture()
	check_approx(case_name, "light node scale 2: packed source_radius doubles to 40", 40.0, _packed(l, 28), 0.5)
	var frac2 := (lum(img, edge_ref) - lum(img, edge_in)) / maxf(lum(img, edge_ref) - AMBIENT, 0.01)
	check_lt(case_name, "light node scale 2: the wider source softens the shadow edge (less shadow 25 px inside it)", frac2, frac1, 0.1)
	check_approx(case_name, "light node scale 2: the umbra core still shadows", AMBIENT, lum(img, Q_P), 0.08)
	l.scale = Vector2.ONE
