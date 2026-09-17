extends LitSuiteSection

## Light textures (cookies) on point and spot lights: the texture shapes the light
## (alpha masks, RGB tints), NATIVE vs FIT_RANGE sizing, texture_scale, texture_offset
## (the cookie slides while falloff stays centred), rotation with the node, falloff 0
## leaving the shape to the texture, composition with a spot cone, and two different
## cookies packed into the shared atlas at once.

const AMBIENT := 0.1
const TOL := 0.03

var _half_left: ImageTexture    # left half opaque white, right half transparent
var _half_top: ImageTexture     # top half opaque white, bottom half transparent
var _red_left: ImageTexture     # left half opaque red


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_half_left = tex_fn(64, 64, func(x, _y): return Color(1, 1, 1, 1) if x < 32 else Color(0, 0, 0, 0))
	_half_top = tex_fn(64, 64, func(_x, y): return Color(1, 1, 1, 1) if y < 32 else Color(0, 0, 0, 0))
	_red_left = tex_fn(64, 64, func(x, _y): return Color(1, 0, 0, 1) if x < 32 else Color(0, 0, 0, 0))
	name_texture(_half_left, "half_left")
	name_texture(_half_top, "half_top")
	name_texture(_red_left, "red_left")
	label("point light + cookie (left half opaque): sizing, scale, offset, rotation, tint",
			Vector2(24, 74))
	label("spot light + cookie (top half opaque): cone composes with the texture", Vector2(704, 544))
	label("two cookies at once (atlas)", Vector2(24, 544))
	floor_receiver(Rect2(20, 90, 1360, 430))
	floor_receiver(Rect2(20, 560, 660, 480))
	floor_receiver(Rect2(700, 560, 680, 480))
	await frames(2)
	await _point_cookie()
	await _spot_cookie()
	await _atlas()


func _lit_at(d: float, energy: float, height: float) -> float:
	return AMBIENT + energy * height / sqrt(d * d + height * height) * diffuse_scale()


func _point_cookie() -> void:
	var case_name := "cookie_point"
	var center := Vector2(400, 300)
	var l := point_light(center, 400.0, 0.5, Color.WHITE, 300.0)
	l.falloff = 0.0
	l.texture = _half_left
	l.texture_size_mode = LitPointLight2D.TextureSizeMode.NATIVE
	l.texture_scale = 4.0   # 64 px cookie -> 256 px footprint
	await frames(1)
	var img := await capture()
	var left := center + Vector2(-64, 0)
	var right := center + Vector2(64, 0)
	var far_left := center + Vector2(-200, 0)
	check_approx(case_name, "inside the opaque half: lit (falloff 0, elevation only)",
			_lit_at(64.0, 0.5, 300.0), lum(img, left), TOL)
	check_approx(case_name, "inside the transparent half: ambient (alpha masks the light)", AMBIENT,
			lum(img, right), TOL)
	check_approx(case_name, "outside the NATIVE footprint (200 px, within range): ambient", AMBIENT,
			lum(img, far_left), TOL)
	l.texture_scale = 8.0
	img = await capture()
	check_gt(case_name, "texture_scale 8: 200 px is now inside the footprint", lum(img, far_left),
			AMBIENT, 0.2)
	l.texture_scale = 1.0
	l.texture_size_mode = LitPointLight2D.TextureSizeMode.FIT_RANGE
	img = await capture()
	check_gt(case_name, "FIT_RANGE: the cookie spans the range (200 px lit)", lum(img, far_left),
			AMBIENT, 0.2)
	check_approx(case_name, "FIT_RANGE: transparent half still masks", AMBIENT, lum(img, right), TOL)
	l.texture_size_mode = LitPointLight2D.TextureSizeMode.NATIVE
	l.texture_scale = 4.0

	l.texture_offset = Vector2(100, 0)
	img = await capture()
	check_gt(case_name, "texture_offset (100, 0): the opaque half slides over the right probe",
			lum(img, right), AMBIENT, 0.2)
	check_approx(case_name, "texture_offset: falloff and shading stay centred (right probe = 64 px)",
			_lit_at(64.0, 0.5, 300.0), lum(img, right), TOL)
	l.texture_offset = Vector2.ZERO

	l.rotation = PI
	img = await capture()
	check_gt(case_name, "rotated 180: the opaque half is on the right", lum(img, right), AMBIENT, 0.2)
	check_approx(case_name, "rotated 180: the left probe is now masked", AMBIENT, lum(img, left), TOL)
	l.rotation = 0.0

	l.falloff = 1.0
	img = await capture()
	check_approx(case_name, "falloff 1 attenuates inside the cookie",
			AMBIENT + 0.5 * (300.0 / sqrt(64.0 * 64.0 + 300.0 * 300.0)) * (1.0 - 64.0 / 400.0) * diffuse_scale(),
			lum(img, left), TOL)
	l.falloff = 0.0

	l.texture = _red_left
	img = await capture()
	var c := probe(img, left)
	check_approx(case_name, "red cookie tints: red channel lit", _lit_at(64.0, 0.5, 300.0), c.r, TOL)
	check_approx(case_name, "red cookie tints: green channel ambient", AMBIENT, c.g, TOL)
	l.texture = null
	img = await capture()
	check_gt(case_name, "texture cleared: the right probe is lit again", lum(img, right), AMBIENT, 0.2)
	l.texture = _half_left
	# Pixel edits repack: the atlas listens to the texture's `changed` signal, so an
	# ImageTexture.update() with the halves swapped flips the masked side.
	var original := _half_left.get_image()
	var mirrored := tex_fn(64, 64, func(x, _y): return Color(1, 1, 1, 1) if x >= 32 else Color(0, 0, 0, 0)).get_image()
	_half_left.update(mirrored)
	await frames(2)
	img = await capture()
	check_gt(case_name, "ImageTexture.update() repacks the atlas: the right probe lights up", lum(img, right), AMBIENT, 0.2)
	check_approx(case_name, "ImageTexture.update() repacks the atlas: the left probe is masked now", AMBIENT, lum(img, left), TOL)
	_half_left.update(original)
	await frames(2)
	# lit/quality/cookie_atlas_max_size: a 128 px cookie (texture_scale 2) packs under a
	# 256 px cap and masks like the 64 px ones do. The over-cap fallback (analytic falloff
	# plus a Lit warning) is left unexercised so a green run stays warning-free.
	var big := tex_fn(128, 128, func(x, _y): return Color(1, 1, 1, 1) if x < 64 else Color(0, 0, 0, 0))
	var saved_max = ProjectSettings.get_setting("lit/quality/cookie_atlas_max_size", 1024)
	set_setting("lit/quality/cookie_atlas_max_size", 256)
	l.texture = big
	l.texture_scale = 2.0
	await frames(2)
	img = await capture()
	check_approx(case_name, "cookie_atlas_max_size 256: a 128 px cookie packs and masks the right probe", AMBIENT, lum(img, right), TOL)
	set_setting("lit/quality/cookie_atlas_max_size", saved_max)
	l.texture = _half_left
	l.texture_scale = 4.0
	await frames(2)


func _spot_cookie() -> void:
	var case_name := "cookie_spot"
	var center := Vector2(900, 800)
	var s := spot_light(center, 0.0, 400.0, 0.5, Color.WHITE, 300.0)
	s.falloff = 0.0
	s.spot_angle = 60.0
	s.spot_softness = 0.0
	s.texture = _half_top
	s.texture_scale = 4.0
	await frames(1)
	var img := await capture()
	var up := center + Vector2(64, -64)      # 45 deg inside the cone, opaque half
	var down := center + Vector2(64, 64)     # 45 deg inside the cone, transparent half
	var behind := center + Vector2(-64, -64) # opaque half but behind the cone
	check_gt(case_name, "inside the cone and the opaque half: lit", lum(img, up), AMBIENT, 0.2)
	check_approx(case_name, "inside the cone, transparent half: ambient", AMBIENT, lum(img, down), TOL)
	check_approx(case_name, "opaque half but outside the cone: ambient", AMBIENT, lum(img, behind), TOL)
	s.rotation = PI
	img = await capture()
	check_gt(case_name, "rotated 180: cone and cookie turn together (bottom-left probe lit)",
			lum(img, center + Vector2(-64, 64)), AMBIENT, 0.2)
	check_approx(case_name, "rotated 180: top-left is inside the cone but the opaque half moved away",
			AMBIENT, lum(img, behind), TOL)
	check_approx(case_name, "rotated 180: the former lit probe is dark", AMBIENT, lum(img, up), TOL)
	s.rotation = 0.0


func _atlas() -> void:
	var case_name := "cookie_atlas"
	var a := point_light(Vector2(200, 800), 300.0, 0.5, Color.WHITE, 300.0)
	a.falloff = 0.0
	a.texture = _half_left
	a.texture_scale = 4.0
	var b := point_light(Vector2(500, 800), 300.0, 0.5, Color.WHITE, 300.0)
	b.falloff = 0.0
	b.texture = _half_top
	b.texture_scale = 4.0
	await frames(1)
	var img := await capture()
	check_gt(case_name, "light A (left-half cookie): left probe lit", lum(img, a.position + Vector2(-64, 0)),
			AMBIENT, 0.2)
	check_approx(case_name, "light A: right probe masked", AMBIENT, lum(img, a.position + Vector2(64, 0)), TOL)
	check_gt(case_name, "light B (top-half cookie): top probe lit", lum(img, b.position + Vector2(0, -64)),
			AMBIENT, 0.2)
	check_approx(case_name, "light B: bottom probe masked", AMBIENT, lum(img, b.position + Vector2(0, 64)), TOL)
	# Swap textures at runtime: the atlas re-packs.
	a.texture = _half_top
	b.texture = _half_left
	img = await capture()
	check_gt(case_name, "after swapping cookies: A's top probe lit", lum(img, a.position + Vector2(0, -64)),
			AMBIENT, 0.2)
	check_approx(case_name, "after swapping: A's bottom probe masked", AMBIENT,
			lum(img, a.position + Vector2(0, 64)), TOL)
	check_gt(case_name, "after swapping: B's left probe lit", lum(img, b.position + Vector2(-64, 0)),
			AMBIENT, 0.2)
