extends LitSuiteSection

## LitManager.sample_luminance / LitSprite2D.get_luminance: the CPU mirror of the
## receiver compositing on a flat, matte surface. Ambient, point falloff, range and
## elevation, spot cones, directional lights, cookies, light / receiver masks,
## subtractive lights (clamped at black), shadow occlusion by loose occluders and
## tilemap cells, shadow colour, the receiver's shadow_ignore_mask, the self-occluder
## exemption, and agreement with what is rendered.

const AMBIENT := 0.2
const TOL := 0.01
# Rendered-versus-sampled tolerances of the sprite proofs.
const TOL_FAR := 0.015
const TOL_NEAR := 0.02
const TOL_SHADOW := 0.025

var _mgr: Node
var _props: Node2D
var _floor: LitSprite2D


func run() -> void:
	_mgr = get_node("/root/LitManager")
	_props = group("Props")
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_floor = floor_receiver(Rect2(20, 90, 1360, 950))
	label("luminance probes: the number printed under each marker is sample_luminance at that spot",
			Vector2(24, 74))
	await frames(2)
	await _lights()
	await _shadows()
	await _render_agreement()
	await _sprite_surfaces()
	await _sprite_proofs()


func _sample(pos: Vector2, rmask := 1, rx := 0, excl: Node = null, dir_scale := 32.0) -> float:
	return _mgr.sample_luminance(pos, rmask, rx, excl, dir_scale)


## Share of a point or spot light's energy a flat receiver takes `d` px from it at
## height `h`: the elevation term times the model's diffuse factor.
func _elev(d: float, h := 100.0) -> float:
	return h / sqrt(d * d + h * h) * diffuse_scale()


## Same for a directional light at the builder's height 16.
func _sun(dir_scale := 32.0) -> float:
	return 16.0 / sqrt(dir_scale * dir_scale + 16.0 * 16.0) * diffuse_scale()


## Visual tag beside a probe point (never on it: markers are unlit sprites).
func _tag(pos: Vector2, text: String) -> void:
	marker(pos + Vector2(0, 16), Vector2(6, 6), Color(1, 0.9, 0.3))
	label(text, pos + Vector2(-20, 22), 11, Color(1, 0.9, 0.3))


func _lights() -> void:
	var case_name := "luminance_lights"
	check_approx(case_name, "no light: ambient luminance", AMBIENT, _sample(Vector2(1200, 900)), TOL)
	var l := point_light(Vector2(300, 300), 200.0, 0.5, Color.WHITE, 100.0)
	await frames(1)
	check_approx(case_name, "at a point light: ambient + energy", AMBIENT + 0.5 * _elev(0.0), _sample(l.position), TOL)
	check_approx(case_name, "100 px away (falloff 1, height 100): ambient + energy / 2 x elevation",
			AMBIENT + 0.25 * _elev(100.0), _sample(l.position + Vector2(100, 0)), TOL)
	check_approx(case_name, "beyond range: ambient", AMBIENT, _sample(l.position + Vector2(250, 0)), TOL)
	l.falloff = 2.0
	check_approx(case_name, "falloff 2 at 100 px: ambient + energy / 4 x elevation", AMBIENT + 0.125 * _elev(100.0),
			_sample(l.position + Vector2(100, 0)), TOL)
	l.falloff = 1.0
	l.height = 300.0
	check_approx(case_name, "height 300 at 100 px: a higher light lands more of its energy",
			AMBIENT + 0.25 * _elev(100.0, 300.0), _sample(l.position + Vector2(100, 0)), TOL)
	l.height = 0.0
	check_approx(case_name, "height 0: the light grazes the plane and adds nothing", AMBIENT,
			_sample(l.position + Vector2(100, 0)), TOL)
	l.height = 100.0
	l.color = Color(1.0, 0.0, 0.0)
	check_approx(case_name, "red light: contribution weighted by luminance (0.2126)",
			AMBIENT + 0.5 * Color(1, 0, 0).get_luminance() * _elev(0.0), _sample(l.position), TOL)
	l.color = Color.WHITE
	l.light_mask = 2
	check_approx(case_name, "light_mask 2 vs receiver_mask 1: ambient only", AMBIENT, _sample(l.position, 1), TOL)
	check_approx(case_name, "light_mask 2 vs receiver_mask 3: lit", AMBIENT + 0.5 * _elev(0.0), _sample(l.position, 3), TOL)
	l.light_mask = 1
	l.blend_mode = LitPointLight2D.BlendMode.SUBTRACT
	l.energy = 0.1
	check_approx(case_name, "subtractive: ambient - energy", AMBIENT - 0.1 * _elev(0.0), _sample(l.position), TOL)
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
	check_approx(case_name, "node scale 2 doubles the range, not the height (250 px lit)",
			AMBIENT + 0.5 * (1.0 - 250.0 / 400.0) * _elev(250.0), _sample(l.position + Vector2(250, 0)), TOL)
	l.scale = Vector2.ONE
	_tag(l.position, "point")

	var s := spot_light(Vector2(700, 300), 0.0, 200.0, 0.5, Color.WHITE, 100.0)
	s.spot_angle = 30.0
	s.spot_softness = 0.0
	await frames(1)
	check_approx(case_name, "spot: on the axis 100 px ahead", AMBIENT + 0.25 * _elev(100.0),
			_sample(s.position + Vector2(100, 0)), TOL)
	check_approx(case_name, "spot: behind the cone", AMBIENT, _sample(s.position + Vector2(-100, 0)), TOL)
	check_approx(case_name, "spot: 45 degrees off a 30 degree cone", AMBIENT, _sample(s.position + Vector2(70, 70)), TOL)
	s.spot_angle = 60.0
	check_gt(case_name, "spot: 45 degrees inside a 60 degree cone", _sample(s.position + Vector2(70, 70)), AMBIENT, 0.1)
	_tag(s.position, "spot")

	var d := directional_light(0.0, 0.3, Color.WHITE)
	await frames(1)
	check_approx(case_name, "directional: adds energy x elevation everywhere", AMBIENT + 0.3 * _sun(),
			_sample(Vector2(1200, 900)), TOL)
	check_approx(case_name, "directional: a receiver's directional_horizontal_scale 8 raises the elevation",
			AMBIENT + 0.3 * _sun(8.0), _sample(Vector2(1200, 900), 1, 0, null, 8.0), TOL)
	d.enabled = false
	await frames(1)

	var ck := tex_fn(64, 64, func(x, _y): return Color(1, 1, 1, 1) if x < 32 else Color(0, 0, 0, 0))
	var c := point_light(Vector2(1100, 300), 300.0, 0.5, Color.WHITE, 100.0)
	c.falloff = 0.0
	c.texture = ck
	c.texture_scale = 4.0
	await frames(1)
	check_approx(case_name, "cookie: opaque half", AMBIENT + 0.5 * _elev(64.0), _sample(c.position + Vector2(-64, 0)), TOL)
	check_approx(case_name, "cookie: transparent half masks", AMBIENT, _sample(c.position + Vector2(64, 0)), TOL)
	check_approx(case_name, "cookie: outside the footprint", AMBIENT, _sample(c.position + Vector2(-200, 0)), TOL)
	c.texture_offset = Vector2(100, 0)
	check_approx(case_name, "cookie offset slides the opaque half", AMBIENT + 0.5 * _elev(64.0),
			_sample(c.position + Vector2(64, 0)), TOL)
	c.texture_offset = Vector2.ZERO
	c.texture_size_mode = LitPointLight2D.TextureSizeMode.FIT_RANGE
	check_approx(case_name, "cookie FIT_RANGE: the opaque half spans out to the range (200 px lit)",
			AMBIENT + 0.5 * _elev(200.0), _sample(c.position + Vector2(-200, 0)), TOL)
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
	# The light's unshadowed contribution at each sample.
	var lit_behind := 0.5 * _elev(behind.distance_to(l.position))
	var lit_beside := 0.5 * _elev(beside.distance_to(l.position))
	await frames(2)
	check_approx(case_name, "occluder between light and sample: ambient", AMBIENT, _sample(behind), TOL)
	check_approx(case_name, "beside the shadow: lit", AMBIENT + lit_beside, _sample(beside), TOL)
	l.shadow_color = Color(0.5, 0.5, 0.5)
	check_approx(case_name, "grey shadow colour halves the light", AMBIENT + lit_behind * 0.5, _sample(behind), TOL)
	l.shadow_color = Color.BLACK
	l.shadow_enabled = false
	check_approx(case_name, "shadows off: lit", AMBIENT + lit_behind, _sample(behind), TOL)
	l.shadow_enabled = true
	box.occluder_light_mask = 2
	await frames(2)
	check_approx(case_name, "occluder mask 2 vs shadow_mask 1: no shadow", AMBIENT + lit_behind, _sample(behind), TOL)
	l.shadow_mask = 3
	await frames(2)
	check_approx(case_name, "shadow_mask 3 matches mask 2: shadow", AMBIENT, _sample(behind), TOL)
	check_approx(case_name, "receiver shadow_ignore_mask 2 ignores it", AMBIENT + lit_behind, _sample(behind, 1, 2), TOL)
	box.occluder_light_mask = 1
	l.shadow_mask = 1
	box.sdf_collision = false
	await frames(2)
	check_approx(case_name, "sdf_collision off: no Lit shadow", AMBIENT + lit_behind, _sample(behind), TOL)
	box.sdf_collision = true
	box.visible = false
	await frames(2)
	check_approx(case_name, "hidden occluder: no shadow", AMBIENT + lit_behind, _sample(behind), TOL)
	box.visible = true
	await frames(2)
	l.shadow_length = 0.2
	check_approx(case_name, "shadow_length 0.2: the march never reaches the box", AMBIENT + lit_behind, _sample(behind), TOL)
	l.shadow_length = 1.0

	# Self exemption: a sprite's own occluder never shadows its origin. The sprite sits
	# off the box's shadow line, so only its own occluder is between it and the light.
	var spr := box_receiver(Vector2(650, 520), Vector2(30, 30))
	occluder(Vector2(-25, 0), Vector2(10, 80), spr)
	var lit_spr := 0.5 * _elev(spr.position.distance_to(l.position))
	await frames(2)
	check_approx(case_name, "exclude_occluders_of: own occluder ignored at the sprite origin", AMBIENT + lit_spr,
			_sample(spr.position, 1, 0, spr), TOL)
	check_approx(case_name, "without the exemption the same spot is shadowed by it", AMBIENT,
			_sample(spr.position), TOL)
	check_approx(case_name, "LitSprite2D.get_luminance() applies its own exemption", AMBIENT + lit_spr,
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
	check_approx(case_name, "tilemap occlusion layer mask 2 vs shadow_mask 1: no shadow", AMBIENT + 0.5 * _elev(400.0),
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
	check_approx(case_name, "directional shadow_length 0: no shadow", AMBIENT + 0.3 * _sun(), _sample(sun_pt), TOL)
	sun.shadow_length = 1.0
	sun.shadow_color = Color(0.5, 0.5, 0.5)
	check_approx(case_name, "directional grey shadow colour halves the sun", AMBIENT + 0.15 * _sun(), _sample(sun_pt), TOL)
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
	check_approx(case_name, "rendered and sampled agree at a lit point (427 px from a height-100 light)",
			lum(img, lit_pt), _sample(lit_pt), 0.03)
	# A sun lands its elevation share everywhere; the receiver's horizontal scale sets it.
	var sun := directional_light(0.0, 0.3, Color.WHITE)
	await frames(2)
	img = await capture()
	check_approx(case_name, "rendered and sampled agree under a directional light", lum(img, far_pt),
			_sample(far_pt), 0.03)
	_floor.directional_horizontal_scale = 8.0
	await frames(2)
	img = await capture()
	check_approx(case_name, "receiver directional_horizontal_scale 8: rendered and sampled still agree",
			lum(img, far_pt), _sample(far_pt, 1, 0, null, 8.0), 0.03)
	check_gt(case_name, "sampled: horizontal scale 8 reads brighter than 32", _sample(far_pt, 1, 0, null, 8.0),
			_sample(far_pt), 0.05)
	_floor.directional_horizontal_scale = 32.0
	sun.queue_free()
	await frames(2)


## get_luminance() on sprites against the mean of the pixels they render: normal maps,
## rotation, flips, frames, alpha, and a plain sprite with a light close by. Every rect
## is inset 2 px from the sprite's edge.
func _sprite_surfaces() -> void:
	var case_name := "luminance_sprite_surface"
	var white := tex_sized(Vector2(64, 64))
	# Dome: normals lean outward from the centre, up to about 60 degrees at the rim.
	var dome := lit_sprite(white, Vector2(1000, 780), 2.0, tex_fn(64, 64, func(x, y):
		return LitSuiteSection.normal_color(((x + 0.5) / 32.0 - 1.0) / 0.6, -((y + 0.5) / 32.0 - 1.0) / 0.6)))
	dome.specular_strength = 0.0
	var dome_rect := Rect2(938, 718, 124, 124)
	# Tilt: every normal leans toward the screen's upper left.
	var tilt := lit_sprite(white, Vector2(1250, 780), 2.0, tex_normal(8, -0.8, 0.8))
	tilt.specular_strength = 0.0
	var tilt_rect := Rect2(1188, 718, 124, 124)
	var nl := point_light(Vector2(800, 780), 500.0, 1.0, Color.WHITE, 24.0)
	await frames(2)
	var img := await capture()
	check_approx(case_name, "dome, low light 200 px to its left: get_luminance() matches the rendered mean",
			mean_lum(img, dome_rect), dome.get_luminance(), 0.015)
	check_gt(case_name, "dome: its normal map lifts it above the flat-surface sample at the same point",
			dome.get_luminance(), _sample(dome.position), 0.03)

	nl.position = Vector2(1100, 630)
	await frames(2)
	img = await capture()
	var facing := tilt.get_luminance()
	check_approx(case_name, "tilt facing a light to its upper left: matches the rendered mean",
			mean_lum(img, tilt_rect), facing, 0.015)
	check_gt(case_name, "tilt facing the light reads far above the flat-surface sample", facing,
			_sample(tilt.position), 0.15)
	check_approx(case_name, "dome, light on a diagonal 180 px away: matches the rendered mean",
			mean_lum(img, dome_rect), dome.get_luminance(), 0.015)

	nl.position = Vector2(1400, 930)
	await frames(2)
	img = await capture()
	check_approx(case_name, "tilt facing away from a light to its lower right: matches the rendered mean",
			mean_lum(img, tilt_rect), tilt.get_luminance(), 0.015)
	check_approx(case_name, "tilt facing away: ambient only", AMBIENT, tilt.get_luminance(), 0.015)

	nl.position = Vector2(1100, 630)
	tilt.rotation = PI * 0.5
	await frames(2)
	img = await capture()
	check_approx(case_name, "tilt rotated 90 degrees: the normals turn with the sprite, still matches the render",
			mean_lum(img, tilt_rect), tilt.get_luminance(), 0.015)
	check_lt(case_name, "tilt rotated 90 degrees reads darker than facing the light", tilt.get_luminance(), facing, 0.1)
	tilt.rotation = 0.0
	tilt.flip_h = true
	await frames(2)
	img = await capture()
	check_approx(case_name, "tilt under flip_h: the normals mirror with the sprite, still matches the render",
			mean_lum(img, tilt_rect), tilt.get_luminance(), 0.015)
	check_lt(case_name, "tilt under flip_h reads darker than facing the light", tilt.get_luminance(), facing, 0.1)
	tilt.flip_h = false

	# Two-frame sheet, each frame opaque in its top half only. Frame 0 leans left, frame
	# 1 right; the transparent halves carry the opposite lean and must not count.
	var sheet := canvas_tex(
			tex_fn(128, 64, func(_x, y): return Color.WHITE if y < 32 else Color(1, 1, 1, 0)),
			tex_fn(128, 64, func(x, y):
				return LitSuiteSection.normal_color(-0.8 if (x < 64) == (y < 32) else 0.8)))
	var strip := LitSprite2D.new()
	strip.texture = sheet
	strip.hframes = 2
	strip.scale = Vector2(2, 2)
	strip.position = Vector2(1250, 960)
	strip.specular_strength = 0.0
	add_child(strip)
	var strip_rect := Rect2(1188, 898, 124, 60)
	nl.position = Vector2(1050, 928)
	await frames(2)
	img = await capture()
	var frame_0 := strip.get_luminance()
	check_approx(case_name, "sheet frame 0 (opaque half leans to the light): matches the rendered opaque half",
			mean_lum(img, strip_rect), frame_0, 0.015)
	check_gt(case_name, "sheet frame 0 reads lit: the transparent texels' opposite lean is ignored",
			frame_0, AMBIENT, 0.15)
	strip.frame = 1
	await frames(2)
	img = await capture()
	check_approx(case_name, "sheet frame 1 (opaque half leans away): matches the rendered opaque half",
			mean_lum(img, strip_rect), strip.get_luminance(), 0.015)
	check_lt(case_name, "sheet frame 1 reads darker than frame 0", strip.get_luminance(), frame_0, 0.1)
	strip.hframes = 1
	strip.region_enabled = true
	strip.region_rect = Rect2(0, 0, 64, 64)
	await frames(2)
	img = await capture()
	check_approx(case_name, "region_rect over frame 0's texels: matches the render", mean_lum(img, strip_rect),
			strip.get_luminance(), 0.015)
	check_approx(case_name, "region_rect over frame 0's texels reads like frame 0", frame_0, strip.get_luminance(), 0.01)

	# A sun: one direction for every pixel, so only the normals shape the result.
	nl.enabled = false
	var sun := directional_light(0.0, 0.3, Color.WHITE)
	await frames(2)
	img = await capture()
	check_approx(case_name, "tilt under a directional light: matches the rendered mean",
			mean_lum(img, tilt_rect), tilt.get_luminance(), 0.015)
	check_approx(case_name, "dome under a directional light: matches the rendered mean",
			mean_lum(img, dome_rect), dome.get_luminance(), 0.015)
	# The sprite's own directional_horizontal_scale, on a sprite with no normal map and
	# a plain (non-CanvasTexture) texture.
	var plain := LitSprite2D.new()
	plain.texture = white
	plain.scale = Vector2(2, 2)
	plain.position = Vector2(1000, 960)
	plain.specular_strength = 0.0
	add_child(plain)
	var plain_rect := Rect2(938, 898, 124, 124)
	await frames(2)
	img = await capture()
	var sun_32 := plain.get_luminance()
	check_approx(case_name, "plain sprite under a directional light: matches the rendered mean",
			mean_lum(img, plain_rect), sun_32, 0.015)
	plain.directional_horizontal_scale = 8.0
	await frames(2)
	img = await capture()
	check_approx(case_name, "plain sprite with directional_horizontal_scale 8: get_luminance() follows the sprite's own scale",
			mean_lum(img, plain_rect), plain.get_luminance(), 0.015)
	check_gt(case_name, "directional_horizontal_scale 8 reads brighter than 32", plain.get_luminance(), sun_32, 0.1)
	plain.directional_horizontal_scale = 32.0
	sun.queue_free()
	nl.enabled = true

	# A light close enough that one side of the plain sprite is far brighter than the
	# other, then on top of it: the mean follows the render where one point cannot.
	nl.position = Vector2(900, 960)
	await frames(2)
	img = await capture()
	check_approx(case_name, "plain sprite, light 100 px from its centre: matches the rendered mean",
			mean_lum(img, plain_rect), plain.get_luminance(), 0.015)
	nl.position = Vector2(1000, 960)
	nl.energy = 0.7
	await frames(2)
	img = await capture()
	check_approx(case_name, "plain sprite, light on its centre: matches the rendered mean",
			mean_lum(img, plain_rect), plain.get_luminance(), 0.02)
	check_gt(case_name, "plain sprite, light on its centre: the single point at its origin reads far above the mean",
			_sample(plain.position), plain.get_luminance(), 0.2)


## The remaining corners of get_luminance(), each against the rendered mean of the
## sprite's own pixels (read on a black unlit backdrop, so any outline works): the
## skull's real normal map and alpha, flip_v, uneven scale, skew, rotation, offset and
## non-centred sprites, stride-sampled normal maps, a spot cone and a cookie edge
## crossing a sprite.
func _sprite_proofs() -> void:
	var case_name := "luminance_sprite_proof"
	# Every earlier light off and the tilemap exhibit hidden (a hidden layer casts
	# nothing): this case owns its lights and casters.
	var parked: Array = []
	var hidden: Array = []
	for child in get_children():
		var is_light: bool = child is LitPointLight2D or child is LitSpotLight2D \
				or child is LitDirectionalLight2D
		if is_light and child.enabled:
			child.enabled = false
			parked.append(child)
		elif child is TileMapLayer and child.visible:
			child.visible = false
			hidden.append(child)
	var backdrop := ColorRect.new()
	backdrop.color = Color.BLACK
	backdrop.position = Vector2(40, 770)
	backdrop.size = Vector2(800, 262)
	add_child(backdrop)

	# The skull's own normal map and outline under a white albedo, at its scene scale.
	var skull_alpha: Image = (load("res://Test/cinderskull_preview.png") as Texture2D).get_image()
	if skull_alpha.is_compressed():
		skull_alpha.decompress()
	var skull := lit_sprite(
			tex_fn(skull_alpha.get_width(), skull_alpha.get_height(), func(x, y):
				return Color(1, 1, 1, skull_alpha.get_pixel(x, y).a)),
			Vector2(170, 900), 5.0, load("res://Test/cinderskull_preview_n.png"))
	skull.specular_strength = 0.0
	var skull_rect := Rect2(50, 780, 240, 240)
	var pl := point_light(Vector2(470, 950), 500.0, 0.75, Color.WHITE, 32.0)
	await frames(2)
	var img := await capture()
	check_approx(case_name, "skull normal map, low light 300 px away: get_luminance() matches the rendered mean",
			masked_mean_lum(img, skull_rect), skull.get_luminance(), TOL_FAR)
	check_gt(case_name, "skull: reads above the flat-surface sample at its origin", skull.get_luminance(),
			_sample(skull.position), 0.03)
	pl.position = Vector2(300, 780)
	await frames(2)
	img = await capture()
	check_approx(case_name, "skull, light on a diagonal 180 px away: matches the rendered mean",
			masked_mean_lum(img, skull_rect), skull.get_luminance(), TOL_FAR)
	skull.rotation = 0.5
	await frames(2)
	img = await capture()
	check_approx(case_name, "skull rotated 0.5 rad: matches the rendered mean",
			masked_mean_lum(img, skull_rect), skull.get_luminance(), TOL_FAR)
	skull.rotation = 0.0
	pl.position = Vector2(260, 900)
	await frames(2)
	img = await capture()
	check_approx(case_name, "skull, light 90 px from its centre (just off its edge): matches the rendered mean",
			masked_mean_lum(img, skull_rect), skull.get_luminance(), TOL_NEAR)
	pl.position = Vector2(170, 900)
	await frames(2)
	img = await capture()
	check_approx(case_name, "skull, light on its centre: matches the rendered mean",
			masked_mean_lum(img, skull_rect), skull.get_luminance(), TOL_NEAR)

	# One tilted normal across the sprite, through the remaining transforms.
	var tilt := lit_sprite(tex_sized(Vector2(64, 64)), Vector2(470, 900), 2.0, tex_normal(8, -0.8, 0.8))
	tilt.specular_strength = 0.0
	var tilt_rect := Rect2(340, 780, 262, 250)
	pl.position = Vector2(330, 780)
	tilt.flip_v = true
	await frames(2)
	img = await capture()
	check_approx(case_name, "flip_v: matches the rendered mean", masked_mean_lum(img, tilt_rect),
			tilt.get_luminance(), TOL_FAR)
	tilt.flip_h = true
	await frames(2)
	img = await capture()
	check_approx(case_name, "flip_h and flip_v together: matches the rendered mean", masked_mean_lum(img, tilt_rect),
			tilt.get_luminance(), TOL_FAR)
	tilt.flip_h = false
	tilt.flip_v = false
	tilt.scale = Vector2(3.0, 1.5)
	await frames(2)
	img = await capture()
	check_approx(case_name, "uneven scale (3, 1.5): matches the rendered mean", masked_mean_lum(img, tilt_rect),
			tilt.get_luminance(), TOL_FAR)
	tilt.scale = Vector2(2, 2)
	tilt.skew = 0.5
	await frames(2)
	img = await capture()
	check_approx(case_name, "skew 0.5: matches the rendered mean", masked_mean_lum(img, tilt_rect),
			tilt.get_luminance(), TOL_FAR)
	tilt.scale = Vector2(2.5, 1.5)
	tilt.skew = 0.3
	tilt.rotation = 0.7
	await frames(2)
	img = await capture()
	check_approx(case_name, "rotation 0.7, uneven scale and skew together: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), tilt.get_luminance(), TOL_FAR)
	tilt.scale = Vector2(2, 2)
	tilt.skew = 0.0
	tilt.rotation = 0.0
	tilt.centered = false
	await frames(2)
	img = await capture()
	check_approx(case_name, "centered = false: the mean follows the pixels, not the origin",
			masked_mean_lum(img, tilt_rect), tilt.get_luminance(), TOL_FAR)
	tilt.centered = true
	tilt.offset = Vector2(20, -10)
	await frames(2)
	img = await capture()
	check_approx(case_name, "offset (20, -10): the mean follows the pixels, not the origin",
			masked_mean_lum(img, tilt_rect), tilt.get_luminance(), TOL_FAR)
	tilt.offset = Vector2.ZERO

	# Frames larger than the summary reads: random normals and holes, then a stripe
	# pattern at the stride's own period.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var noise_n := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var noise_d := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 128:
			noise_n.set_pixel(x, y, LitSuiteSection.normal_color(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.2, 1.2)))
			noise_d.set_pixel(x, y, Color(1, 1, 1, 0.0 if rng.randf() < 0.25 else 1.0))
	var big := lit_sprite(ImageTexture.create_from_image(noise_d), Vector2(720, 900), 1.0,
			ImageTexture.create_from_image(noise_n))
	big.specular_strength = 0.0
	var big_rect := Rect2(650, 830, 140, 140)
	pl.position = Vector2(560, 800)
	await frames(2)
	img = await capture()
	check_approx(case_name, "128 px frame of random normals and holes (stride-sampled): matches the rendered mean",
			masked_mean_lum(img, big_rect), big.get_luminance(), TOL_FAR)
	big.texture = canvas_tex(tex_sized(Vector2(128, 128)), tex_fn(128, 128, func(x, _y):
		return LitSuiteSection.normal_color(-0.9 if x % 4 < 2 else 0.9)))
	await frames(2)
	img = await capture()
	check_approx(case_name, "128 px frame striped at the sampling stride: matches the rendered mean (no aliasing)",
			masked_mean_lum(img, big_rect), big.get_luminance(), TOL_FAR)

	# A spot cone and a cookie whose edges cross the sprite.
	pl.enabled = false
	var sl := spot_light(Vector2(250, 900), 0.0, 500.0, 0.75, Color.WHITE, 32.0)
	sl.spot_angle = 12.0
	sl.spot_softness = 0.5
	await frames(2)
	img = await capture()
	var in_cone := tilt.get_luminance()
	check_approx(case_name, "spot cone narrower than the sprite: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), in_cone, TOL_FAR)
	check_gt(case_name, "spot cone: part of the sprite is lit", in_cone, AMBIENT, 0.03)
	sl.spot_angle = 45.0
	await frames(2)
	check_gt(case_name, "widening the cone to cover the sprite raises its reading", tilt.get_luminance(), in_cone, 0.03)
	sl.enabled = false
	var cl := point_light(Vector2(470, 760), 500.0, 0.75, Color.WHITE, 60.0)
	cl.texture = tex_fn(64, 64, func(x, _y): return Color(1, 1, 1, 1) if x < 32 else Color(0, 0, 0, 0))
	cl.texture_scale = 8.0
	await frames(2)
	img = await capture()
	var half_cookie := tilt.get_luminance()
	check_approx(case_name, "cookie edge through the sprite's middle: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), half_cookie, TOL_FAR)
	cl.texture = null
	await frames(2)
	check_gt(case_name, "without the cookie the whole sprite is lit: reads higher", tilt.get_luminance(), half_cookie, 0.03)
	cl.enabled = false

	# Shadow edges crossing a sprite: each part of it is shadowed on its own. The casters
	# sit under a wrapper node, so no sprite owns them.
	var sh := point_light(Vector2(220, 900), 500.0, 0.75, Color.WHITE, 60.0)
	sh.shadow_enabled = true
	sh.shadow_hardness = 1.0
	var caster := occluder(Vector2(350, 925), Vector2(20, 90), _props)
	await frames(6)
	img = await capture()
	var mostly_shadowed := tilt.get_luminance()
	check_approx(case_name, "caster shadowing most of the sprite: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), mostly_shadowed, TOL_SHADOW)
	caster.position = Vector2(350, 960)
	await frames(6)
	img = await capture()
	var half_shadowed := tilt.get_luminance()
	check_approx(case_name, "caster shadowing the lower part of the sprite: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), half_shadowed, TOL_SHADOW)
	check_gt(case_name, "less of the sprite in shadow reads brighter", half_shadowed, mostly_shadowed, 0.03)
	sh.shadow_color = Color(0.5, 0.5, 0.5)
	await frames(4)
	img = await capture()
	check_approx(case_name, "grey shadow colour over part of the sprite: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), tilt.get_luminance(), TOL_SHADOW)
	sh.shadow_color = Color.BLACK
	caster.position = Vector2(350, 1200)
	await frames(6)
	img = await capture()
	var unshadowed := tilt.get_luminance()
	check_approx(case_name, "caster moved clear: matches the rendered mean", masked_mean_lum(img, tilt_rect),
			unshadowed, TOL_FAR)
	check_gt(case_name, "caster moved clear reads brighter than half shadowed", unshadowed, half_shadowed, 0.03)
	# The skull, a caster covering its upper part from a light to its right.
	sh.position = Vector2(420, 900)
	caster.position = Vector2(300, 850)
	await frames(6)
	img = await capture()
	check_approx(case_name, "skull partly shadowed: matches the rendered mean",
			masked_mean_lum(img, skull_rect), skull.get_luminance(), TOL_SHADOW)
	sh.enabled = false
	# A sun travelling +x: the caster to the sprite's left shadows a band of it.
	var sun := directional_light(0.0, 0.5, Color.WHITE)
	sun.shadow_enabled = true
	sun.shadow_hardness = 1.0
	sun.shadow_length = 1.0
	caster.position = Vector2(370, 930)
	await frames(6)
	img = await capture()
	var sun_band := tilt.get_luminance()
	check_approx(case_name, "directional shadow over a band of the sprite: matches the rendered mean",
			masked_mean_lum(img, tilt_rect), sun_band, TOL_SHADOW)
	caster.position = Vector2(370, 1200)
	await frames(6)
	check_gt(case_name, "directional caster moved clear reads brighter", tilt.get_luminance(), sun_band, 0.03)
	sun.queue_free()
	caster.queue_free()
	pl.enabled = true
	for l in parked:
		l.enabled = true
	for layer in hidden:
		layer.visible = true
	await frames(2)
