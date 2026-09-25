extends LitSuiteSection

## LitAnimatedSprite2D: pre-wiring (receiver material, empty SpriteFrames, seeded
## proxies), lighting that follows the frame on screen (CanvasTexture normal maps per
## frame, AtlasTexture frames over one CanvasTexture sheet), playback under Lit, the
## has_specular_map flag tracking frame steps / animation switches / SpriteFrames swaps
## / live texture edits, pooled materials re-keying per node, an owned occluder
## driving the self-exclusion tier, and shadow_ignore_mask on the node (rx variant,
## private material, the rendered exemption).

const RxRegistryScript := preload("res://addons/lit/runtime/registry/rx_registry.gd")
const AMBIENT := 0.05


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_prewiring()
	await _frame_lighting()
	await _specular_tracking()
	await _occluder()
	await _shadow_ignore()


func _prewiring() -> void:
	var case_name := "animated_prewiring"
	var fresh := LitAnimatedSprite2D.new()
	check_true(case_name, "fresh node carries a ShaderMaterial on the fast tier",
			fresh.material is ShaderMaterial
			and LitShaderLibrary.flags_of((fresh.material as ShaderMaterial).shader) == 0)
	check_true(case_name, "fresh node carries an empty SpriteFrames (so the panel opens)",
			fresh.sprite_frames != null)
	check(case_name, "receiver_mask seeded on the material", 1,
			int((fresh.material as ShaderMaterial).get_shader_parameter("receiver_mask")))
	check_proxies(case_name, fresh)
	fresh.free()


func _frames_with_normals() -> SpriteFrames:
	var sf := SpriteFrames.new()
	var size := Vector2(60, 60)
	# Frame 0: CanvasTexture facing left. Frame 1: facing right. Frame 2: AtlasTexture
	# over a two-frame sheet whose right half faces right. Frame 3: plain ImageTexture.
	sf.add_frame(&"default", canvas_tex(tex_sized(size), tex_normal(8, -1.0)))
	sf.add_frame(&"default", canvas_tex(tex_sized(size), tex_normal(8, 1.0)))
	var sheet := CanvasTexture.new()
	sheet.diffuse_texture = tex_sized(Vector2(120, 60))
	sheet.normal_texture = tex_fn(16, 8, func(x, _y):
		return LitSuiteSection.normal_color(-1.0) if x < 8 else LitSuiteSection.normal_color(1.0))
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(60, 0, 60, 60)
	sf.add_frame(&"default", atlas)
	sf.add_frame(&"default", tex_sized(size))
	sf.set_animation_speed(&"default", 30.0)
	return sf


func _frame_lighting() -> void:
	var case_name := "animated_frame_lighting"
	var c := cell("frames: left-facing / right-facing /\natlas over sheet / plain, light from the left")
	var base := cell_center(c) + Vector2(20, 10)
	# Range 200: the twin 300 px below is out of reach (and vice versa), so each sprite
	# sees exactly its own light.
	var l := point_light(base + Vector2(-150, 0), 200.0, 0.6, Color.WHITE, 60.0)
	l.falloff = 0.0
	var a := LitAnimatedSprite2D.new()
	a.sprite_frames = _frames_with_normals()
	a.position = base
	a.specular_strength = 0.0
	add_child(a)
	# A LitSprite2D twin with the same left-facing map pins the expected value.
	var twin := box_receiver(base + Vector2(0, 300), Vector2(60, 60), Color.WHITE, null, tex_normal(8, -1.0))
	twin.specular_strength = 0.0
	var twin_light := point_light(twin.position + Vector2(-150, 0), 200.0, 0.6, Color.WHITE, 60.0)
	twin_light.falloff = 0.0
	await frames(1)
	var img := await capture()
	var f0 := lum(img, a.position)
	check_approx(case_name, "frame 0 (CanvasTexture facing the light) matches a LitSprite2D twin",
			lum(img, twin.position), f0, 0.04)
	a.frame = 1
	img = await capture()
	var f1 := lum(img, a.position)
	check_lt(case_name, "frame 1 (facing away) is darker than frame 0", f1, f0, 0.1)
	a.frame = 3
	img = await capture()
	var f3 := lum(img, a.position)
	check_between(case_name, "frame 3 (no normal map) sits between the two", f3, f1 + 0.02, f0 - 0.02)
	a.frame = 2
	img = await capture()
	check_approx(case_name, "frame 2 (AtlasTexture region over a CanvasTexture sheet) reads its region's normal",
			f1, lum(img, a.position), 0.05)
	# Playback advances frames under Lit.
	a.frame = 0
	a.play(&"default")
	# Playback runs on the animation's own clock: a second frame index within 1 s.
	var seen := {}
	var t0 := Time.get_ticks_msec()
	while seen.size() < 2 and Time.get_ticks_msec() - t0 < 1000:
		seen[a.frame] = true
		await get_tree().process_frame
	check_true(case_name, "play() advances frames (a second frame index appears within 1 s)", seen.size() >= 2)
	a.stop()
	a.frame = 0
	a.flip_h = true
	img = await capture()
	check_lt(case_name, "flip_h on frame 0 mirrors the normal (darker)", lum(img, a.position), f0, 0.08)
	a.flip_h = false


func _specular_tracking() -> void:
	var case_name := "animated_specular_flag"
	var white8 := tex_solid(8, Color.WHITE)
	var ct_spec := canvas_tex(white8, null, white8)
	var ct_plain := canvas_tex(white8)
	var sheet := canvas_tex(tex_sized(Vector2(16, 8)), null, tex_sized(Vector2(16, 8)))
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(8, 0, 8, 8)
	var sf := SpriteFrames.new()
	sf.add_frame(&"default", ct_spec)
	sf.add_frame(&"default", ct_plain)
	sf.add_frame(&"default", atlas)
	sf.add_frame(&"default", white8)
	sf.add_animation(&"bare")
	sf.add_frame(&"bare", white8)
	var c := cell("specular flag tracking\n(A: frame 0 spec, B: frame 1 plain)")
	var a := LitAnimatedSprite2D.new()
	a.sprite_frames = sf
	a.scale = Vector2(6, 6)
	var b := LitAnimatedSprite2D.new()
	b.sprite_frames = sf
	b.frame = 1
	b.scale = Vector2(6, 6)
	place(a, c, Vector2(-40, 10), 6.0)
	place(b, c, Vector2(40, 10), 6.0)
	await frames(1)
	check(case_name, "A on frame 0 (specular CanvasTexture): flag on", true, _spec(a))
	check(case_name, "B on frame 1 (plain CanvasTexture): flag off", false, _spec(b))
	check_true(case_name, "different specular state re-keys A and B to different pool entries",
			not is_same(a.material, b.material))
	a.frame = 1
	check(case_name, "A stepped to frame 1: flag off", false, _spec(a))
	check_true(case_name, "identical content now shares one pooled material", is_same(a.material, b.material))
	a.frame = 2
	check(case_name, "A on frame 2 (AtlasTexture over a specular sheet): flag on", true, _spec(a))
	a.frame = 3
	check(case_name, "A on frame 3 (plain ImageTexture): flag off", false, _spec(a))
	a.frame = 1
	ct_plain.specular_texture = white8
	check(case_name, "specular map assigned on the current frame's CanvasTexture: flag on", true, _spec(a))
	ct_plain.specular_texture = null
	check(case_name, "specular map cleared again: flag off", false, _spec(a))
	a.frame = 0
	a.animation = &"bare"
	check(case_name, "animation switched to a plain frame set: flag off", false, _spec(a))
	a.animation = &"default"
	check(case_name, "animation switched back to frame 0: flag on", true, _spec(a))
	sf.set_frame(&"default", 0, ct_plain)
	check(case_name, "frame 0 replaced with a plain texture (panel edit): flag off", false, _spec(a))
	sf.set_frame(&"default", 0, ct_spec)
	check(case_name, "frame 0 restored: flag on", true, _spec(a))
	var other := SpriteFrames.new()
	other.add_frame(&"default", ct_plain)
	a.sprite_frames = other
	check(case_name, "SpriteFrames swapped for a plain set: flag off", false, _spec(a))
	a.sprite_frames = null
	check(case_name, "SpriteFrames cleared: flag off, no error", false, _spec(a))
	a.sprite_frames = sf


func _spec(n: LitAnimatedSprite2D) -> bool:
	return (n.material as ShaderMaterial).get_shader_parameter("has_specular_map") == true


func _occluder() -> void:
	var case_name := "animated_owned_occluder"
	var c := cell("owned occluder: self rects,\nfull tier, private material")
	# A floor under the cell and a light above the sprite: the sprite's own occluder
	# must shadow the floor but not the sprite itself, until self_shadow says otherwise.
	floor_receiver(Rect2(cell_pos(c), CELL))
	var a := LitAnimatedSprite2D.new()
	var sf := SpriteFrames.new()
	sf.add_frame(&"default", tex_sized(Vector2(60, 120)))
	a.sprite_frames = sf
	a.specular_strength = 0.0
	place(a, c, Vector2(0, 10))
	occluder(Vector2(0, 20), Vector2(40, 10), a)
	var l := point_light(a.position + Vector2(0, -70), 200.0, 0.8, Color.WHITE, 100.0)
	l.falloff = 0.0
	l.shadow_enabled = true
	l.shadow_hardness = 1.0
	await frames(2)
	var img := await capture()
	var on_sprite := a.position + Vector2(0, 50)   # 30 px below its occluder, still on the sprite
	var on_floor := a.position + Vector2(0, 80)    # past the sprite's bottom edge (60)
	var lit_on_sprite := lum(img, on_sprite)
	check_gt(case_name, "self-exclusion rendered: the sprite below its own occluder stays lit while the floor behind it is shadowed",
			lit_on_sprite, lum(img, on_floor), 0.2)
	check(case_name, "one self rect pushed", 1, int(a.material.get_shader_parameter("self_rect_count")))
	check(case_name, "tiered to the full (self-exclusion) shader", LitShaderLibrary.F_SELF_EXCL,
			LitShaderLibrary.flags_of(a.material.shader) & LitShaderLibrary.TIER_MASK)
	check_true(case_name, "material left the pool (per-node rects)", not LitLightRegistry.pool_is_pooled(a.material))
	a.self_shadow = true
	await frames(2)
	check(case_name, "self_shadow = true drops to the fast tier", 0,
			LitShaderLibrary.flags_of(a.material.shader) & LitShaderLibrary.TIER_MASK)
	img = await capture()
	check_lt(case_name, "self_shadow = true rendered: the sprite darkens under its own occluder", lum(img, on_sprite),
			lit_on_sprite, 0.15)
	# get_luminance(): a light 80 px above adds energy x (1 - 80 / 200) to the sample.
	var lum_before := a.get_luminance()
	point_light(a.global_position + Vector2(0, -80), 200.0, 0.5, Color.WHITE, 100.0)
	await frames(1)
	check_approx("luminance_proxy", "get_luminance() on the animated node: a light 80 px above adds 0.5 x 0.6",
			0.3, a.get_luminance() - lum_before, 0.02)


func _shadow_ignore() -> void:
	var case_name := "animated_shadow_ignore"
	var c := cell("shadow_ignore_mask: A (mask 2) ignores the\nmask-2 caster, B (mask 0) is shadowed")
	var sprites := group("RxSprites")
	var casters := group("RxCasters")
	var sf := SpriteFrames.new()
	sf.add_frame(&"default", tex_sized(Vector2(60, 60)))
	var a := LitAnimatedSprite2D.new()
	a.sprite_frames = sf
	a.specular_strength = 0.0
	a.shadow_ignore_mask = 2   # set before entering the tree, as a loaded scene does
	place(a, c, Vector2(45, -45), 1.0, sprites)
	var b := LitAnimatedSprite2D.new()
	b.sprite_frames = sf
	b.specular_strength = 0.0
	b.receiver_mask = 2
	place(b, c, Vector2(45, 45), 1.0, sprites)
	# One light per row (light_mask / receiver_mask pairs) and a mask-2 caster in between.
	for row in [[a, 1], [b, 2]]:
		var y: float = (row[0] as Node2D).position.y
		var l := point_light(Vector2(cell_center(c).x - 100, y), 300.0, 1.0, Color.WHITE, 150.0)
		l.light_mask = row[1]
		l.falloff = 0.0
		l.shadow_enabled = true
		l.shadow_mask = 3
		occluder(Vector2(cell_center(c).x - 40, y), Vector2(40, 100), casters, 2)
	await frames(4)
	var img := await capture()
	var lit_a := lum(img, a.position)
	check_gt(case_name, "A (shadow_ignore_mask 2) ignores the mask-2 caster", lit_a, AMBIENT, 0.2)
	check_lt(case_name, "B (mask 0) is shadowed by it: under a quarter of A", lum(img, b.position), lit_a * 0.25)
	check_true(case_name, "A is on an _rx variant", LitShaderLibrary.flags_of(a.material.shader) & LitShaderLibrary.F_RX != 0)
	check_true(case_name, "A's material is private", not LitLightRegistry.pool_is_pooled(a.material))
	check(case_name, "rx_mask landed on A's material", 2, int(a.material.get_shader_parameter("rx_mask")))
	check(case_name, "A is registered with its mask", 2, int(RxRegistryScript.nodes().get(a, 0)))
	a.shadow_ignore_mask = 0
	await frames(4)
	img = await capture()
	check_lt(case_name, "mask cleared: A is shadowed, under a quarter of its lit reading", lum(img, a.position), lit_a * 0.25)
	check_true(case_name, "cleared mask leaves the _rx variant", LitShaderLibrary.flags_of(a.material.shader) & LitShaderLibrary.F_RX == 0)
	check_true(case_name, "cleared mask unregisters A", not RxRegistryScript.nodes().has(a))
	a.shadow_ignore_mask = 2
	await frames(4)
	img = await capture()
	check_gt(case_name, "mask set again at runtime: A ignores the caster again", lum(img, a.position), AMBIENT, 0.2)
