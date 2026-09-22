extends LitSuiteSection

## LitManager.sample_luminance / LitSprite2D.get_luminance: the CPU mirror of the
## receiver compositing. Ambient, point falloff and range, spot cones, directional
## lights, cookies, light / receiver masks, subtractive lights (clamped at black),
## shadow occlusion by loose occluders and tilemap cells, shadow colour, the
## receiver's shadow_ignore_mask, the self-occluder exemption, and agreement with
## what is rendered.

const AMBIENT := 0.2
const TOL := 0.01

var _mgr: Node
var _props: Node2D


func run() -> void:
	_mgr = get_node("/root/LitManager")
	_props = group("Props")
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	floor_receiver(Rect2(20, 90, 1360, 950))
	label("luminance probes: the number printed under each marker is sample_luminance at that spot",
			Vector2(24, 74))
	await frames(2)
	await _lights()
	await _shadows()
	await _render_agreement()


func _sample(pos: Vector2, rmask := 1, rx := 0, excl: Node = null) -> float:
	return _mgr.sample_luminance(pos, rmask, rx, excl)


## Visual tag beside a probe point (never on it: markers are unlit sprites).
func _tag(pos: Vector2, text: String) -> void:
	marker(pos + Vector2(0, 16), Vector2(6, 6), Color(1, 0.9, 0.3))
	label(text, pos + Vector2(-20, 22), 11, Color(1, 0.9, 0.3))


func _lights() -> void:
	var case_name := "luminance_lights"
	check_approx(case_name, "no light: ambient luminance", AMBIENT, _sample(Vector2(1200, 900)), TOL)
	var l := point_light(Vector2(300, 300), 200.0, 0.5, Color.WHITE, 100.0)
	await frames(1)
	check_approx(case_name, "at a point light: ambient + energy", AMBIENT + 0.5, _sample(l.position), TOL)
	check_approx(case_name, "100 px away (falloff 1): ambient + energy / 2", AMBIENT + 0.25,
			_sample(l.position + Vector2(100, 0)), TOL)
	check_approx(case_name, "beyond range: ambient", AMBIENT, _sample(l.position + Vector2(250, 0)), TOL)
	l.falloff = 2.0
	check_approx(case_name, "falloff 2 at 100 px: ambient + energy / 4", AMBIENT + 0.125,
			_sample(l.position + Vector2(100, 0)), TOL)
	l.falloff = 1.0
	l.color = Color(1.0, 0.0, 0.0)
	check_approx(case_name, "red light: contribution weighted by luminance (0.2126)",
			AMBIENT + 0.5 * Color(1, 0, 0).get_luminance(), _sample(l.position), TOL)
	l.color = Color.WHITE
	l.light_mask = 2
	check_approx(case_name, "light_mask 2 vs receiver_mask 1: ambient only", AMBIENT, _sample(l.position, 1), TOL)
	check_approx(case_name, "light_mask 2 vs receiver_mask 3: lit", AMBIENT + 0.5, _sample(l.position, 3), TOL)
	l.light_mask = 1
	l.blend_mode = LitPointLight2D.BlendMode.SUBTRACT
	l.energy = 0.1
	check_approx(case_name, "subtractive: ambient - energy", AMBIENT - 0.1, _sample(l.position), TOL)
	l.energy = 2.0
	check_approx(case_name, "subtractive beyond ambient clamps at 0", 0.0, _sample(l.position), TOL)
	l.blend_mode = LitPointLight2D.BlendMode.ADD
	l.energy = 0.5
	l.enabled = false
	await frames(1)
	check_approx(case_name, "disabled light: ambient", AMBIENT, _sample(l.position), TOL)
	l.enabled = true
	await frames(1)
	l.scale = Vector2(2, 2)
	check_approx(case_name, "node scale 2 doubles the range (250 px lit)", AMBIENT + 0.5 * (1.0 - 250.0 / 400.0),
			_sample(l.position + Vector2(250, 0)), TOL)
	l.scale = Vector2.ONE
	_tag(l.position, "point")

	var s := spot_light(Vector2(700, 300), 0.0, 200.0, 0.5, Color.WHITE, 100.0)
	s.spot_angle = 30.0
	s.spot_softness = 0.0
	await frames(1)
	check_approx(case_name, "spot: on the axis 100 px ahead", AMBIENT + 0.25, _sample(s.position + Vector2(100, 0)), TOL)
	check_approx(case_name, "spot: behind the cone", AMBIENT, _sample(s.position + Vector2(-100, 0)), TOL)
	check_approx(case_name, "spot: 45 degrees off a 30 degree cone", AMBIENT, _sample(s.position + Vector2(70, 70)), TOL)
	s.spot_angle = 60.0
	check_gt(case_name, "spot: 45 degrees inside a 60 degree cone", _sample(s.position + Vector2(70, 70)), AMBIENT, 0.15)
	_tag(s.position, "spot")

	var d := directional_light(0.0, 0.3, Color.WHITE)
	await frames(1)
	check_approx(case_name, "directional: adds energy everywhere", AMBIENT + 0.3, _sample(Vector2(1200, 900)), TOL)
	d.enabled = false
	await frames(1)

	var ck := tex_fn(64, 64, func(x, _y): return Color(1, 1, 1, 1) if x < 32 else Color(0, 0, 0, 0))
	var c := point_light(Vector2(1100, 300), 300.0, 0.5, Color.WHITE, 100.0)
	c.falloff = 0.0
	c.texture = ck
	c.texture_scale = 4.0
	await frames(1)
	check_approx(case_name, "cookie: opaque half", AMBIENT + 0.5, _sample(c.position + Vector2(-64, 0)), TOL)
	check_approx(case_name, "cookie: transparent half masks", AMBIENT, _sample(c.position + Vector2(64, 0)), TOL)
	check_approx(case_name, "cookie: outside the footprint", AMBIENT, _sample(c.position + Vector2(-200, 0)), TOL)
	c.texture_offset = Vector2(100, 0)
	check_approx(case_name, "cookie offset slides the opaque half", AMBIENT + 0.5, _sample(c.position + Vector2(64, 0)), TOL)
	c.texture_offset = Vector2.ZERO
	c.texture_size_mode = LitPointLight2D.TextureSizeMode.FIT_RANGE
	check_approx(case_name, "cookie FIT_RANGE: the opaque half spans out to the range (200 px lit)", AMBIENT + 0.5,
			_sample(c.position + Vector2(-200, 0)), TOL)
	check_approx(case_name, "cookie FIT_RANGE: the transparent half still masks", AMBIENT, _sample(c.position + Vector2(64, 0)), TOL)
	c.texture_size_mode = LitPointLight2D.TextureSizeMode.NATIVE
	_tag(c.position, "cookie")


func _shadows() -> void:
	var case_name := "luminance_shadows"
	var l := point_light(Vector2(200, 700), 600.0, 0.5, Color.WHITE, 100.0)
	l.falloff = 0.0
	l.shadow_enabled = true
	var box := occluder(Vector2(400, 700), Vector2(40, 100), _props)
	var behind := Vector2(600, 700)
	var beside := Vector2(600, 550)
	await frames(2)
	check_approx(case_name, "occluder between light and sample: ambient", AMBIENT, _sample(behind), TOL)
	check_approx(case_name, "beside the shadow: lit", AMBIENT + 0.5, _sample(beside), TOL)
	l.shadow_color = Color(0.5, 0.5, 0.5)
	check_approx(case_name, "grey shadow colour halves the light", AMBIENT + 0.25, _sample(behind), TOL)
	l.shadow_color = Color.BLACK
	l.shadow_enabled = false
	check_approx(case_name, "shadows off: lit", AMBIENT + 0.5, _sample(behind), TOL)
	l.shadow_enabled = true
	box.occluder_light_mask = 2
	await frames(2)
	check_approx(case_name, "occluder mask 2 vs shadow_mask 1: no shadow", AMBIENT + 0.5, _sample(behind), TOL)
	l.shadow_mask = 3
	await frames(2)
	check_approx(case_name, "shadow_mask 3 matches mask 2: shadow", AMBIENT, _sample(behind), TOL)
	check_approx(case_name, "receiver shadow_ignore_mask 2 ignores it", AMBIENT + 0.5, _sample(behind, 1, 2), TOL)
	box.occluder_light_mask = 1
	l.shadow_mask = 1
	box.sdf_collision = false
	await frames(2)
	check_approx(case_name, "sdf_collision off: no Lit shadow", AMBIENT + 0.5, _sample(behind), TOL)
	box.sdf_collision = true
	box.visible = false
	await frames(2)
	check_approx(case_name, "hidden occluder: no shadow", AMBIENT + 0.5, _sample(behind), TOL)
	box.visible = true
	await frames(2)
	l.shadow_length = 0.2
	check_approx(case_name, "shadow_length 0.2: the march never reaches the box", AMBIENT + 0.5, _sample(behind), TOL)
	l.shadow_length = 1.0

	# Self exemption: a sprite's own occluder never shadows its origin. The sprite sits
	# off the box's shadow line, so only its own occluder is between it and the light.
	var spr := box_receiver(Vector2(650, 520), Vector2(30, 30))
	occluder(Vector2(-25, 0), Vector2(10, 40), spr)
	await frames(2)
	check_approx(case_name, "exclude_occluders_of: own occluder ignored at the sprite origin", AMBIENT + 0.5,
			_sample(spr.position, 1, 0, spr), TOL)
	check_approx(case_name, "without the exemption the same spot is shadowed by it", AMBIENT,
			_sample(spr.position), TOL)
	check_approx(case_name, "LitSprite2D.get_luminance() applies its own exemption", AMBIENT + 0.5,
			spr.get_luminance(), TOL)
	spr.self_shadow = true
	check_approx(case_name, "self_shadow = true: get_luminance() sees its own occluder", AMBIENT,
			spr.get_luminance(), TOL)
	spr.queue_free()

	# Tilemap cells shadow too (the first shadow light is off meanwhile: its range
	# reaches this sample).
	l.enabled = false
	var ts := TileSet.new()
	ts.tile_size = Vector2i(32, 32)
	ts.add_occlusion_layer()
	ts.set_occlusion_layer_sdf_collision(0, true)
	var src := TileSetAtlasSource.new()
	src.texture = tex_solid(32, Color(0.5, 0.4, 0.3))
	src.texture_region_size = Vector2i(32, 32)
	src.create_tile(Vector2i.ZERO)
	ts.add_source(src, 0)
	var td := src.get_tile_data(Vector2i.ZERO, 0)
	td.add_occluder_polygon(0)
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-16, -16), Vector2(16, -16), Vector2(16, 16), Vector2(-16, 16)])
	td.set_occluder_polygon(0, 0, poly)
	var tm := LitTileMapLayer.new()
	tm.tile_set = ts
	tm.position = Vector2(384, 850)
	tm.set_cell(Vector2i.ZERO, 0, Vector2i.ZERO)
	tm.set_cell(Vector2i(0, 1), 0, Vector2i.ZERO)
	add_child(tm)
	var l2 := point_light(Vector2(200, 880), 600.0, 0.5, Color.WHITE, 100.0)
	l2.falloff = 0.0
	l2.shadow_enabled = true
	await frames(3)
	check_approx(case_name, "tilemap occluder cells shadow the sample behind them", AMBIENT,
			_sample(Vector2(600, 880)), TOL)
	ts.set_occlusion_layer_light_mask(0, 2)
	await frames(3)
	check_approx(case_name, "tilemap occlusion layer mask 2 vs shadow_mask 1: no shadow", AMBIENT + 0.5,
			_sample(Vector2(600, 880)), TOL)
	ts.set_occlusion_layer_light_mask(0, 1)
	l2.enabled = false
	# Directional shadows in the sampler: it marches shadow_reach x shadow_length toward
	# the sun (rotation 0 shines along +x, so the occluder sits to the sample's left).
	var sun := directional_light(0.0, 0.3, Color.WHITE)
	sun.shadow_enabled = true
	sun.shadow_length = 1.0
	var sun_box := occluder(Vector2(1150, 1000), Vector2(40, 100), _props)
	var sun_pt := Vector2(1250, 1000)
	await frames(2)
	check_approx(case_name, "directional shadow: an occluder toward the sun blocks its energy", AMBIENT, _sample(sun_pt), TOL)
	sun.shadow_length = 0.0
	check_approx(case_name, "directional shadow_length 0: no shadow", AMBIENT + 0.3, _sample(sun_pt), TOL)
	sun.shadow_length = 1.0
	sun.shadow_color = Color(0.5, 0.5, 0.5)
	check_approx(case_name, "directional grey shadow colour halves the sun", AMBIENT + 0.15, _sample(sun_pt), TOL)
	sun.enabled = false
	sun_box.queue_free()
	await frames(2)
	l.enabled = true
	await frames(2)
	_tag(behind, "shadow")


func _render_agreement() -> void:
	var case_name := "luminance_render_agreement"
	# Same light and occluder as the shadow exhibit: the render must order the same way.
	var img := await capture()
	var lit_pt := Vector2(600, 550)
	var shadow_pt := Vector2(600, 700)
	var far_pt := Vector2(1200, 1000)
	check_gt(case_name, "rendered: lit point brighter than the shadowed point", lum(img, lit_pt), lum(img, shadow_pt), 0.1)
	check_gt(case_name, "sampled: lit point brighter than the shadowed point", _sample(lit_pt), _sample(shadow_pt), 0.1)
	check_approx(case_name, "rendered and sampled agree on the ambient floor", lum(img, far_pt), _sample(far_pt), 0.03)
	check_approx(case_name, "rendered and sampled agree in the umbra", lum(img, shadow_pt), _sample(shadow_pt), 0.03)
	# At a lit point they diverge: registry/luminance.gd applies energy x falloff only,
	# with no elevation term (the shader multiplies by height / sqrt(d^2 + h^2)) and no
	# lighting-model factor. Here: render ~0.31, sample 0.70.
	check_approx(case_name, "(known gap) rendered and sampled agree at a lit point (sampler has no elevation term)",
			lum(img, lit_pt), _sample(lit_pt), 0.03)
