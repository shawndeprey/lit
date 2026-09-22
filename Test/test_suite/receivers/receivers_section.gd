extends LitSuiteSection

## Receivers: LitSprite2D pre-wiring and every proxied export, emissive strength and
## mask, receiver masks, normal maps read straight from the CanvasTexture (and their
## rotation with the node), specular maps and the Blinn-Phong specular dials, the
## has_specular_map auto-detect, bare receivers (a plain Sprite2D or Polygon2D handed
## the receiver material renders exactly like LitSprite2D), make_material_unique, and
## the luminance proxy.

const AMBIENT := 0.05
const TOL := 0.03
const SubclassedSprite := preload("res://Test/test_suite/receivers/subclassed_sprite.gd")


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	await _prewiring()
	await _emissive()
	await _normal_maps()
	await _specular()
	await _specular_nomap()
	await _bare_receivers()


func _prewiring() -> void:
	var case_name := "lit_sprite_prewiring"
	var fresh := LitSprite2D.new()
	check_true(case_name, "fresh LitSprite2D carries a ShaderMaterial", fresh.material is ShaderMaterial)
	check(case_name, "on the fast receiver tier", 0,
			LitShaderLibrary.flags_of((fresh.material as ShaderMaterial).shader))
	check_true(case_name, "fresh LitSprite2D carries a CanvasTexture", fresh.texture is CanvasTexture)
	check(case_name, "receiver_mask seeded on the material", 1,
			int((fresh.material as ShaderMaterial).get_shader_parameter("receiver_mask")))
	check(case_name, "specular_k seeded on the material", 32.0,
			float((fresh.material as ShaderMaterial).get_shader_parameter("specular_k")))
	check_proxies(case_name, fresh)
	fresh.free()
	# A subclass that overrides _ready without super() must still get wired.
	var sub := SubclassedSprite.new()
	sub.texture = canvas_tex(white())
	add_child(sub)
	await frames(1)
	check_true(case_name, "subclass overriding _ready without super() still pools at ready",
			LitLightRegistry.pool_is_pooled(sub.material))
	sub.queue_free()
	# A stale rx_mask a scene save baked into the material heals at ready.
	var stale := LitSprite2D.new()
	stale.texture = canvas_tex(white())
	var baked := receiver_material()
	baked.set_shader_parameter("rx_mask", 2)
	stale.material = baked
	add_child(stale)
	await frames(1)
	var healed = (stale.material as ShaderMaterial).get_shader_parameter("rx_mask")
	check_true(case_name, "a baked rx_mask with shadow_ignore_mask 0 heals to 0 at ready", healed == null or int(healed) == 0)
	stale.queue_free()




func _emissive() -> void:
	var case_name := "emissive"
	var c := cell("emissive 0.8, no light")
	var e := box_receiver(cell_center(c), Vector2(80, 80))
	e.specular_strength = 0.0
	e.emissive_strength = 0.8
	c = cell("emissive 0.8 + mask\n(left black, right white)")
	var m := box_receiver(cell_center(c), Vector2(80, 80))
	m.specular_strength = 0.0
	m.emissive_strength = 0.8
	var mask := tex_fn(64, 64, func(x, _y): return Color.BLACK if x < 32 else Color.WHITE)
	# A texture uniform set by hand at runtime goes on a private material (a raw write
	# on a pooled material would reach every poolmate).
	m.make_material_unique().set_shader_parameter("emissive_mask", mask)
	c = cell("emissive 0 (control)")
	var z := box_receiver(cell_center(c), Vector2(80, 80))
	z.specular_strength = 0.0
	await frames(1)
	var img := await capture()
	check_approx(case_name, "emissive 0.8 in the dark: albedo x 0.8 + ambient", AMBIENT + 0.8,
			lum(img, e.position), TOL)
	check_approx(case_name, "emissive mask: black half stays ambient", AMBIENT,
			lum(img, m.position + Vector2(-25, 0)), TOL)
	check_approx(case_name, "emissive mask: white half glows", AMBIENT + 0.8,
			lum(img, m.position + Vector2(25, 0)), TOL)
	check_approx(case_name, "emissive 0: ambient only", AMBIENT, lum(img, z.position), TOL)
	e.emissive_strength = 0.0
	img = await capture()
	check_approx(case_name, "emissive set to 0 at runtime: dark again", AMBIENT, lum(img, e.position), TOL)
	e.emissive_strength = 0.8

	# Receiver mask against a mask-1 light.
	c = cell("receiver_mask 2 vs light 1\n(dark)   |   receiver_mask 3 (lit)")
	var a := box_receiver(cell_center(c) + Vector2(-45, 0), Vector2(60, 60))
	var b := box_receiver(cell_center(c) + Vector2(45, 0), Vector2(60, 60))
	a.specular_strength = 0.0
	b.specular_strength = 0.0
	a.receiver_mask = 2
	b.receiver_mask = 3
	var l := point_light(cell_center(c), 140.0, 0.6, Color.WHITE, 200.0)
	l.falloff = 0.0
	await frames(1)
	img = await capture()
	check_approx("receiver_mask", "receiver_mask 2 under a light_mask 1 light: ambient", AMBIENT,
			lum(img, a.position), TOL)
	check_gt("receiver_mask", "receiver_mask 3 under the same light: lit", lum(img, b.position), AMBIENT, 0.3)
	a.receiver_mask = 1
	img = await capture()
	check_gt("receiver_mask", "receiver_mask back to 1: lit", lum(img, a.position), AMBIENT, 0.3)


## Diffuse at a tile whose normal map is tex_normal(nx): N = normalize(nx, 0, 1), and the
## light direction L = normalize(to_light.xy, height); the shader shades N.L (a flat tile
## is the height-only ndotl of the point-light formula).
func _ndotl_lit(nx: float, to_light: Vector3, energy: float) -> float:
	var n := Vector3(nx, 0.0, 1.0).normalized()
	return AMBIENT + maxf(n.dot(to_light.normalized()), 0.0) * energy * diffuse_scale()


func _normal_maps() -> void:
	var case_name := "normal_maps"
	# Second row, two cells apart, lights of range 200: no exhibit lights another.
	_cell_index = 7
	var c := cell("normal maps, light from the left:\nleft-facing / flat / right-facing")
	var base := cell_center(c) + Vector2(20, 10)
	var l := point_light(base + Vector2(-130, 0), 200.0, 0.6, Color.WHITE, 60.0)
	l.falloff = 0.0
	var left := box_receiver(base + Vector2(-50, 0), Vector2(40, 40), Color.WHITE, null, tex_normal(8, -1.0))
	var flat := box_receiver(base, Vector2(40, 40))
	var right := box_receiver(base + Vector2(50, 0), Vector2(40, 40), Color.WHITE, null, tex_normal(8, 1.0))
	for n in [left, flat, right]:
		n.specular_strength = 0.0
	_cell_index = 9
	c = cell("same left-facing map:\nrotated 180 / flip_h / scale 2 / reference")
	var base2 := cell_center(c) + Vector2(20, 10)
	var l2 := point_light(base2 + Vector2(-130, 0), 200.0, 0.6, Color.WHITE, 60.0)
	l2.falloff = 0.0
	var rot := box_receiver(base2 + Vector2(-50, 0), Vector2(40, 40), Color.WHITE, null, tex_normal(8, -1.0))
	rot.rotation = PI
	var flip := box_receiver(base2, Vector2(40, 40), Color.WHITE, null, tex_normal(8, -1.0))
	flip.flip_h = true
	var big := box_receiver(base2 + Vector2(50, 0), Vector2(20, 20), Color.WHITE, null, tex_normal(8, -1.0))
	big.scale = Vector2(2, 2)
	var ref_left := box_receiver(base2 + Vector2(-50, 50), Vector2(40, 40), Color.WHITE, null, tex_normal(8, -1.0))
	for n in [rot, flip, big, ref_left]:
		n.specular_strength = 0.0
	await frames(1)
	var img := await capture()
	var l_lum := lum(img, left.position)
	var f_lum := lum(img, flat.position)
	var r_lum := lum(img, right.position)
	# Absolute N.L expectations: the tiles sit 80 / 130 / 180 px from the light, so a
	# relative "facing is brighter" would pass on distance alone with the maps ignored.
	check_approx(case_name, "left-facing normal, light 80 px to the left: N.L 0.99",
			_ndotl_lit(-1.0, Vector3(-80, 0, 60), 0.6), l_lum, 0.04)
	check_approx(case_name, "flat tile, light 130 px to the left: N.L = height term 0.42",
			_ndotl_lit(0.0, Vector3(-130, 0, 60), 0.6), f_lum, 0.04)
	check_approx(case_name, "right-facing normal, light 180 px to the left: faces away, ambient",
			_ndotl_lit(1.0, Vector3(-180, 0, 60), 0.6), r_lum, 0.04)
	check_true(case_name, "flat receiver without a normal map is lit", f_lum > AMBIENT + 0.1)
	# The second cell has its own light at the same relative spot.
	check_approx(case_name, "reference left-facing tile (80 px left, 50 px down): N.L 0.89",
			_ndotl_lit(-1.0, Vector3(-80, -50, 60), 0.6), lum(img, ref_left.position), 0.04)
	check_approx(case_name, "node rotated 180: the normal turns with it (now faces away, ambient)",
			_ndotl_lit(1.0, Vector3(-80, 0, 60), 0.6), lum(img, rot.position), 0.04)
	check_approx(case_name, "flip_h mirrors the normal (faces away, ambient)",
			_ndotl_lit(1.0, Vector3(-130, 0, 60), 0.6), lum(img, flip.position), 0.04)
	check_approx(case_name, "node scaled x2: still N.L of the unscaled normal (180 px left: 0.90)",
			_ndotl_lit(-1.0, Vector3(-180, 0, 60), 0.6), lum(img, big.position), 0.04)
	# Light moves to the right: the pair swaps.
	l.position = base + Vector2(130, 0)
	img = await capture()
	check_approx(case_name, "light from the right: right-facing normal 80 px away: N.L 0.99",
			_ndotl_lit(1.0, Vector3(80, 0, 60), 0.6), lum(img, right.position), 0.04)
	check_approx(case_name, "light from the right: flat tile 130 px away: 0.42",
			_ndotl_lit(0.0, Vector3(130, 0, 60), 0.6), lum(img, flat.position), 0.04)
	check_approx(case_name, "light from the right: left-facing normal faces away, ambient",
			_ndotl_lit(-1.0, Vector3(180, 0, 60), 0.6), lum(img, left.position), 0.04)


## Without a specular map the Blinn-Phong lobe falls back to pow(N.L, 1 + shininess x k)
## (lit_shade.gdshaderinc); PBR ignores the dial.
func _specular_nomap() -> void:
	var case_name := "specular_no_map"
	# Row 4 of the grid: nothing else lights this far down (the normal-map cells' range-200
	# lights reach into row 2).
	_cell_index = 26
	var c := cell("no specular map, light 40 px off-centre:\nstrength 1 (N.L lobe) / strength 0")
	var base := cell_center(c) + Vector2(0, 10)
	var on := box_receiver(base + Vector2(-60, 0), Vector2(50, 50))
	var off := box_receiver(base + Vector2(60, 0), Vector2(50, 50))
	on.specular_strength = 1.0
	on.specular_k = 2.0
	off.specular_strength = 0.0
	# Same geometry as the specular_k cell: lights 40 px above their tile, range 100, so
	# the other tile (126 px away) is out of reach.
	for n in [on, off]:
		var l := point_light(n.position + Vector2(0, -40), 100.0, 0.4, Color.WHITE, 60.0)
		l.falloff = 0.0
	await frames(1)
	var img := await capture()
	var ndotl := 60.0 / sqrt(40.0 * 40.0 + 60.0 * 60.0)   # 0.832
	var diffuse := AMBIENT + 0.4 * ndotl * diffuse_scale()
	check_approx(case_name, "strength 0: diffuse only (N.L 0.83)", diffuse, lum(img, off.position), TOL)
	if model == 0:
		check_approx(case_name, "strength 1, k 2 (Blinn-Phong): + 0.4 x N.L^3 fallback lobe",
				diffuse + 0.4 * pow(ndotl, 3.0), lum(img, on.position), TOL)
	else:
		check_approx(case_name, "strength 1 (PBR): the dial is inert, diffuse only", diffuse, lum(img, on.position), TOL)


func _specular() -> void:
	var case_name := "specular"
	var spec := white()
	# Each sprite has its own light (range 60, 80 px apart) so nothing bleeds.
	_cell_index = 12
	var c := cell("specular map, light overhead:\nstrength 0 / strength 1")
	var base := cell_center(c) + Vector2(0, 10)
	var s0 := box_receiver(base + Vector2(-40, 0), Vector2(50, 50), Color.WHITE, null, null, spec)
	var s1 := box_receiver(base + Vector2(40, 0), Vector2(50, 50), Color.WHITE, null, null, spec)
	s0.specular_strength = 0.0
	s1.specular_strength = 1.0
	for n in [s0, s1]:
		var l := point_light(n.position, 60.0, 0.4, Color.WHITE, 100.0)
		l.falloff = 0.0
	# Lobe width: the light sits 40 px above each sprite (height 60), so n.h = 0.957.
	_cell_index = 13
	c = cell("specular_k 2 (wide lobe) / 64 (tight),\nlight 40 px off-centre")
	var base2 := cell_center(c) + Vector2(0, 10)
	var k2 := box_receiver(base2 + Vector2(-60, 0), Vector2(50, 50), Color.WHITE, null, null, spec)
	var k64 := box_receiver(base2 + Vector2(60, 0), Vector2(50, 50), Color.WHITE, null, null, spec)
	k2.specular_strength = 1.0
	k2.specular_k = 2.0
	k64.specular_strength = 1.0
	k64.specular_k = 64.0
	for n in [k2, k64]:
		var l := point_light(n.position + Vector2(0, -40), 100.0, 0.4, Color.WHITE, 60.0)
		l.falloff = 0.0
	# Control: the same setup on a bare Sprite2D with a raw material (no pool involved),
	# so a pooling regression and a shading regression read apart.
	var ctrl := Sprite2D.new()
	ctrl.texture = canvas_tex(tex_sized(Vector2(50, 50)), null, spec)
	ctrl.material = receiver_material()
	ctrl.material.set_shader_parameter("specular_strength", 1.0)
	ctrl.material.set_shader_parameter("has_specular_map", true)
	ctrl.position = base2 + Vector2(0, 70)
	add_child(ctrl)
	var ctrl_light := point_light(ctrl.position, 40.0, 0.4, Color.WHITE, 100.0)
	ctrl_light.falloff = 0.0
	await frames(1)
	var img := await capture()
	check(case_name, "specular map on the CanvasTexture sets has_specular_map", true,
			s1.material.get_shader_parameter("has_specular_map"))
	check(case_name, "specular_strength proxied onto the runtime material", 1.0,
			float(s1.material.get_shader_parameter("specular_strength")))
	var ldir := Vector3(0.0, 40.0, 60.0).normalized()
	var h := (ldir + Vector3(0, 0, 1)).normalized()
	if model == 0:
		check_approx(case_name, "control: bare Sprite2D, raw material, strength 1 under an overhead light = 0.85",
				AMBIENT + 0.8, lum(img, ctrl.position), 0.06)
		check_approx(case_name, "specular_strength 0 under an overhead light: ambient + diffuse", AMBIENT + 0.4,
				lum(img, s0.position), 0.05)
		check_approx(case_name, "specular_strength 1: ambient + diffuse + a full half-vector highlight", AMBIENT + 0.8,
				lum(img, s1.position), 0.06)
		var k2_expected := AMBIENT + 0.4 * ldir.z + 0.4 * pow(h.z, 1.0 + 2.0)
		var k64_expected := AMBIENT + 0.4 * ldir.z + 0.4 * pow(h.z, 1.0 + 64.0)
		check_approx(case_name, "specular_k 2 off-centre matches the Blinn-Phong lobe", k2_expected, lum(img, k2.position), 0.06)
		check_approx(case_name, "specular_k 64 off-centre: the tight lobe has faded", k64_expected, lum(img, k64.position), 0.06)
		check_gt(case_name, "wide lobe brighter than tight lobe off-centre", lum(img, k2.position), lum(img, k64.position), 0.15)
	else:
		# PBR has no Blinn-Phong dials: strength and k are inert, the dielectric's
		# response is the metallic-roughness model (checked in lighting_model).
		check_approx(case_name, "PBR: specular_strength 1 renders like strength 0 (dial inert)",
				lum(img, s0.position), lum(img, s1.position), 0.03)
		check_approx(case_name, "PBR: the raw-material control matches the pooled LitSprite2D",
				lum(img, s1.position), lum(img, ctrl.position), 0.03)
		check_approx(case_name, "PBR: specular_k 2 renders like specular_k 64 (dial inert)",
				lum(img, k2.position), lum(img, k64.position), 0.03)
		check_approx(case_name, "PBR: rough dielectric off-centre = ambient + 0.96 x diffuse",
				AMBIENT + 0.4 * ldir.z * diffuse_scale(), lum(img, k2.position), 0.05)
	(s0.texture as CanvasTexture).specular_texture = null
	check(case_name, "clearing the specular map at runtime clears has_specular_map", false,
			s0.material.get_shader_parameter("has_specular_map"))
	(s0.texture as CanvasTexture).specular_texture = spec
	check(case_name, "assigning it again sets the flag", true,
			s0.material.get_shader_parameter("has_specular_map"))
	var plain := LitSprite2D.new()
	plain.texture = white()   # not a CanvasTexture
	add_child(plain)
	await frames(1)
	check_true(case_name, "a non-CanvasTexture texture reports no specular map",
			plain.material.get_shader_parameter("has_specular_map") != true)
	plain.queue_free()


func _bare_receivers() -> void:
	var case_name := "bare_receivers"
	_cell_index = 17   # far from the normal-map row's lights (range 200)
	var c := cell("bare receivers under one light:\nLitSprite2D / Sprite2D / Polygon2D")
	var base := cell_center(c) + Vector2(0, 10)
	var l := point_light(base, 200.0, 0.5, Color.WHITE, 300.0)
	l.falloff = 0.0
	var ref := box_receiver(base + Vector2(-70, 0), Vector2(50, 50))
	ref.specular_strength = 0.0
	var bare := Sprite2D.new()
	bare.texture = tex_sized(Vector2(50, 50))
	bare.material = receiver_material()
	bare.material.set_shader_parameter("specular_strength", 0.0)
	bare.position = base
	add_child(bare)
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-25, -25), Vector2(25, -25), Vector2(25, 25), Vector2(-25, 25)])
	poly.color = Color.WHITE
	poly.material = receiver_material()
	poly.material.set_shader_parameter("specular_strength", 0.0)
	poly.position = base + Vector2(70, 0)
	add_child(poly)
	await frames(1)
	var img := await capture()
	var ref_lum := lum(img, ref.position)
	check(case_name, "reference LitSprite2D runtime material has specular_strength 0", 0.0,
			float(ref.material.get_shader_parameter("specular_strength")))
	check_true(case_name, "reference LitSprite2D reports no specular map",
			ref.material.get_shader_parameter("has_specular_map") != true)
	check_approx(case_name, "LitSprite2D reference 70 px from the light: ambient + diffuse",
			AMBIENT + 0.5 * 300.0 / sqrt(70.0 * 70.0 + 300.0 * 300.0) * diffuse_scale(), ref_lum, 0.04)
	check_approx(case_name, "plain Sprite2D + receiver material renders like LitSprite2D", ref_lum,
			lum(img, bare.position), 0.04)
	check_approx(case_name, "Polygon2D + receiver material renders like LitSprite2D", ref_lum,
			lum(img, poly.position), 0.04)
	var shared := ref.material
	var unique := ref.make_material_unique()
	check_true(case_name, "make_material_unique returns the node's (now private) material",
			is_same(unique, ref.material) and not LitLightRegistry.pool_is_pooled(unique))
	check_true(case_name, "the pooled material it left is a different object or no longer held",
			not is_same(shared, unique) or not LitLightRegistry.pool_is_pooled(shared))
	unique.set_shader_parameter("emissive_strength", 0.5)
	img = await capture()
	check_gt(case_name, "raw set_shader_parameter on the private material renders", lum(img, ref.position),
			ref_lum, 0.2)
	check_true("luminance_proxy", "LitSprite2D.get_luminance() sees the light at its origin",
			ref.get_luminance() > AMBIENT + 0.2)
	ref.receiver_mask = 2
	check_approx("luminance_proxy", "get_luminance() honours the sprite's receiver_mask", AMBIENT,
			ref.get_luminance(), 0.01)
	ref.receiver_mask = 1
