extends LitSuiteSection

## Post processing: LitPostProcess hosting every built-in LitPostEffect, each pass
## enabled on a deterministic base image and verified to change it in its own way
## (and to restore the base when hidden), chain order by child order, add_effect
## rank slotting, host visibility disabling the chain, parameters persisting across
## toggles, host layer changes re-layering the passes, effects outside a host staying
## inert with a configuration warning, a custom LitPostEffect subclass, and the
## stateful Auto Exposure pass adapting over time.

const AREA := Rect2(20, 90, 1360, 950)
const InvertEffect := preload("res://Test/test_suite/post_process/invert_effect.gd")

var _post: LitPostProcess
var _base: Image
var _base_sprite: Sprite2D
var _hidden := {}


func run() -> void:
	env(Color(1, 1, 1))   # post passes read the screen; lighting is not the subject here
	label("post-processing: every effect toggled on this base image, one at a time", Vector2(24, 74))
	_build_base()
	_post = LitPostProcess.new()
	_post.name = "Post"
	add_child(_post)
	await frames(2)
	_base = await capture()
	await _effects()
	await _chain()
	await _custom()
	await _auto_exposure()


func _build_base() -> void:
	# Gradient + checker + a bright disc + a dark disc: edges, hues, highlights.
	var img := Image.create(340, 238, false, Image.FORMAT_RGBA8)
	for y in 238:
		for x in 340:
			var c := Color(float(x) / 340.0, float(y) / 238.0, 1.0 - float(x) / 340.0)
			@warning_ignore("integer_division")
			if (x / 20 + y / 20) % 2 == 0:
				c = c.lightened(0.25)
			var dx := x - 250
			var dy := y - 80
			if dx * dx + dy * dy < 900:
				c = Color(1.0, 0.95, 0.6)
			var ex := x - 90
			var ey := y - 160
			if ex * ex + ey * ey < 500:
				c = Color(0.05, 0.05, 0.07)
			img.set_pixel(x, y, c)
	_base_sprite = Sprite2D.new()
	_base_sprite.texture = ImageTexture.create_from_image(img)
	_base_sprite.centered = false
	_base_sprite.position = AREA.position
	_base_sprite.scale = AREA.size / Vector2(340, 238)
	add_child(_base_sprite)


# World-space helpers for landmarks in the base image.
func _pt(px: float, py: float) -> Vector2:
	return AREA.position + Vector2(px, py) * AREA.size / Vector2(340, 238)


func _effect_changes(fx: LitPostEffect, case_name: String, what: String, min_diff := 0.01) -> Image:
	_post.add_effect(fx)
	await frames(2)
	var img := await capture()
	var diff := image_diff(_base, img, AREA)
	check_gt(case_name, "%s changes the image" % what, diff, min_diff)
	check_true(case_name, "%s pass shader compiled (uniforms visible)" % what,
			fx._mat != null and fx._mat.shader != null and fx._mat.shader.get_shader_uniform_list().size() > 0)
	return img


func _effect_off(fx: LitPostEffect, case_name: String, what: String) -> void:
	fx.visible = false
	await frames(2)
	var img := await capture()
	check_lt(case_name, "%s hidden restores the base image" % what, image_diff(_base, img, AREA), 0.006)
	check_true(case_name, "%s hidden tears its pass layer down" % what, fx._pass_layer == null)
	_hidden[fx] = true


func _effects() -> void:
	var img: Image
	var img2: Image
	var c: Color

	var threshold := LitPostThreshold.new()
	threshold.cutoff = 0.5
	img = await _effect_changes(threshold, "fx_threshold", "Threshold")
	# Below the cutoff goes black (through a 0.05 soft knee), above keeps its colour.
	var crushed := 0
	var below := 0
	var kept := 0
	var above := 0
	for i in 200:
		@warning_ignore("integer_division")
		var p := _pt(10 + (i % 20) * 16, 10 + (i / 20) * 22)
		var ct := probe(img, p, 0)
		var cbt := probe(_base, p, 0)
		var luma_b := cbt.r * 0.2126 + cbt.g * 0.7152 + cbt.b * 0.0722
		if luma_b < 0.4:
			below += 1
			if ct.r + ct.g + ct.b < 0.06:
				crushed += 1
		elif luma_b > 0.6:
			above += 1
			if absf(ct.r - cbt.r) < 0.03 and absf(ct.g - cbt.g) < 0.03 and absf(ct.b - cbt.b) < 0.03:
				kept += 1
	check("fx_threshold", "Threshold blacks out every sample below the cutoff (%d samples)" % below, below, crushed)
	check("fx_threshold", "Threshold keeps every sample above the cutoff unchanged (%d samples)" % above, above, kept)
	check_gt("fx_threshold", "Threshold keeps pixels above the cutoff unchanged", float(kept), 20.0)
	await _effect_off(threshold, "fx_threshold", "Threshold")

	var bloom := LitPostBloom.new()
	bloom.threshold = 0.3
	bloom.intensity = 2.0
	bloom.radius = 6.0
	img = await _effect_changes(bloom, "fx_bloom", "Bloom")
	check_gt("fx_bloom", "Bloom brightens around the bright disc", lum(img, _pt(250, 120)), lum(_base, _pt(250, 120)), 0.05)
	bloom.threshold = 0.99
	await frames(2)
	img = await capture()
	check_approx("fx_bloom", "threshold 0.99 (above the brightest luma): nothing glows beside the disc",
			lum(_base, _pt(250, 120)), lum(img, _pt(250, 120)), 0.02)
	bloom.threshold = 0.3
	bloom.intensity = 0.0
	await frames(2)
	img = await capture()
	check_lt("fx_bloom", "intensity 0 is identity", image_diff(_base, img, AREA), 0.006)
	# Intensity 0.6 keeps the glow off the clamp so the reach difference stays visible.
	bloom.intensity = 0.6
	bloom.radius = 0.5
	await frames(2)
	img = await capture()
	var tight_glow := lum(img, _pt(90, 160))   # dark disc centre: only spread light reaches it
	bloom.radius = 8.0
	await frames(2)
	img = await capture()
	check_gt("fx_bloom", "radius 8 (mips 1.6..8) spreads glow into the dark disc, radius 0.5 (mips 0.1..0.5) does not",
			lum(img, _pt(90, 160)), tight_glow, 0.02)
	bloom.intensity = 2.0
	await _effect_off(bloom, "fx_bloom", "Bloom")

	var halation := LitPostHalation.new()
	halation.threshold = 0.3
	halation.intensity = 2.0
	halation.radius = 6.0
	halation.tint = Color(1.0, 0.1, 0.05)
	img = await _effect_changes(halation, "fx_halation", "Halation")
	c = probe(img, _pt(250, 120))
	var cb := probe(_base, _pt(250, 120))
	check_gt("fx_halation", "Halation bleeds its red tint around the highlight", c.r - c.b, cb.r - cb.b, 0.05)
	halation.threshold = 0.99
	await frames(2)
	img = await capture()
	c = probe(img, _pt(250, 120))
	check_approx("fx_halation", "threshold 0.99: no halo beside the disc (red-blue split as the base)", cb.r - cb.b, c.r - c.b, 0.02)
	halation.threshold = 0.3
	halation.intensity = 0.0
	await frames(2)
	img = await capture()
	check_lt("fx_halation", "intensity 0 is identity", image_diff(_base, img, AREA), 0.006)
	halation.intensity = 2.0
	await _effect_off(halation, "fx_halation", "Halation")

	var glitch := LitPostGlitch.new()
	glitch.intensity = 1.0
	glitch.block_size = 24.0
	glitch.rgb_shift = 12.0
	glitch.speed = 0.0
	img = await _effect_changes(glitch, "fx_glitch", "Glitch")
	img2 = await capture()
	check_lt("fx_glitch", "speed 0 freezes the pattern (two frames identical)", image_diff(img, img2, AREA), 0.003)
	glitch.intensity = 0.0
	glitch.rgb_shift = 32.0
	await frames(2)
	img = await capture()
	var gr := _channel_diff(_base, img, AREA, 0)
	var gg := _channel_diff(_base, img, AREA, 1)
	var gb := _channel_diff(_base, img, AREA, 2)
	check_true("fx_glitch", "rgb_shift 32 alone splits red/blue more than green (%.3f / %.3f / %.3f)" % [gr, gg, gb],
			gr > gg * 1.3 or gb > gg * 1.3)
	glitch.rgb_shift = 0.0
	await frames(2)
	img = await capture()
	var calm := image_diff(_base, img, AREA)
	check_lt("fx_glitch", "intensity 0 and rgb_shift 0: no tearing (near identity)", calm, 0.01)
	glitch.intensity = 1.0
	await frames(2)
	img = await capture()
	check_gt("fx_glitch", "intensity 1 tears 24 px slices (image moves vs the calm frame)", image_diff(_base, img, AREA), calm, 0.01)
	glitch.speed = 30.0
	await frames(2)
	img = await capture()
	await get_tree().create_timer(0.12).timeout
	img2 = await capture()
	check_gt("fx_glitch", "speed 30 reshuffles the slices over 0.12 s", image_diff(img, img2, AREA), 0.003)
	await _effect_off(glitch, "fx_glitch", "Glitch")

	var grade := LitPostColorGrade.new()
	grade.exposure = 2.0
	img = await _effect_changes(grade, "fx_color_grade", "Color Grade (exposure 2)")
	check_gt("fx_color_grade", "exposure 2 brightens the mid grey", lum(img, _pt(170, 119)), lum(_base, _pt(170, 119)), 0.1)
	grade.exposure = 1.0
	grade.saturation = 0.0
	await frames(2)
	img = await capture()
	c = probe(img, _pt(60, 60))
	check_approx("fx_color_grade", "saturation 0 makes a coloured spot grey (r = b)", c.r, c.b, 0.03)
	grade.saturation = 1.0
	grade.tint = Color(1.0, 0.4, 0.4)
	await frames(2)
	img = await capture()
	c = probe(img, _pt(170, 119))
	cb = probe(_base, _pt(170, 119))
	check_gt("fx_color_grade", "red tint raises red over green", c.r - c.g, cb.r - cb.g, 0.1)
	grade.tint = Color.WHITE
	grade.contrast = 3.0
	await frames(2)
	img = await capture()
	# (c - 0.5) * 3 + 0.5 (lit_post_grade.gdshader): the bright disc clamps up, the dark
	# disc clamps down, so their spread widens; identity would leave it unchanged.
	check_gt("fx_color_grade", "contrast 3 widens the bright-disc / dark-disc spread",
			lum(img, _pt(250, 80)) - lum(img, _pt(90, 160)),
			lum(_base, _pt(250, 80)) - lum(_base, _pt(90, 160)), 0.05)
	await _effect_off(grade, "fx_color_grade", "Color Grade")

	var lut := LitPostLut.new()
	lut.preset = LitPostLut.LutPreset.SEPIA
	img = await _effect_changes(lut, "fx_lut", "LUT (sepia)")
	c = image_mean(img, AREA)
	cb = image_mean(_base, AREA)
	check_gt("fx_lut", "sepia LUT warms the image (r - b up)", c.r - c.b, cb.r - cb.b, 0.05)
	# Every baked-in preset grades the image, each in its own way.
	var graded: Array = []
	for preset in LitPostLut.LutPreset.values():
		if preset == LitPostLut.LutPreset.NEUTRAL:
			continue
		lut.preset = preset
		await frames(2)
		img = await capture()
		var preset_name: String = LitPostLut.LutPreset.keys()[preset]
		check_gt("fx_lut", "%s preset changes the image" % preset_name, image_diff(_base, img, AREA), 0.01)
		var distinct := true
		for other in graded:
			distinct = distinct and image_diff(other, img, AREA) > 0.005
		check_true("fx_lut", "%s preset differs from the presets before it" % preset_name, distinct)
		graded.append(img)
	lut.preset = LitPostLut.LutPreset.NEUTRAL
	await frames(2)
	img = await capture()
	check_lt("fx_lut", "neutral LUT is (near) identity", image_diff(_base, img, AREA), 0.02)
	lut.preset = LitPostLut.LutPreset.SEPIA
	lut.custom_texture = LitPostLut.PRESET_LUTS[LitPostLut.LutPreset.NEUTRAL]
	await frames(2)
	img = await capture()
	check_lt("fx_lut", "custom_texture overrides the preset (neutral custom over sepia)", image_diff(_base, img, AREA), 0.02)
	lut.custom_texture = null
	lut.amount = 0.0
	await frames(2)
	img = await capture()
	check_lt("fx_lut", "amount 0 is identity", image_diff(_base, img, AREA), 0.006)
	lut.amount = 1.0
	await _effect_off(lut, "fx_lut", "LUT")

	var pixelate := LitPostPixelate.new()
	pixelate.pixel_size = 24.0
	img = await _effect_changes(pixelate, "fx_pixelate", "Pixelate")
	# 24 px blocks: points 12 px apart land in one block half the time and read identical.
	var same := 0
	var same_base := 0
	for i in 60:
		@warning_ignore("integer_division")
		var p := Vector2(60 + (i % 12) * 100, 200 + (i / 12) * 150)
		var q := p + Vector2(12, 0)
		if absf(probe(img, p, 0).r - probe(img, q, 0).r) < 0.003:
			same += 1
		if absf(probe(_base, p, 0).r - probe(_base, q, 0).r) < 0.003:
			same_base += 1
	check_gt("fx_pixelate", "Pixelate makes neighbouring samples identical (of 60 pairs)", float(same), float(same_base), 15.0)
	await _effect_off(pixelate, "fx_pixelate", "Pixelate")

	var posterize := LitPostPosterize.new()
	posterize.levels = 2.0
	img = await _effect_changes(posterize, "fx_posterize", "Posterize")
	var distinct := {}
	for i in 40:
		var p := _pt(10 + i * 8, 200)
		distinct[snappedf(probe(img, p, 0).r, 0.05)] = true
	check_lt("fx_posterize", "2 levels: at most a few distinct red values across a gradient row", float(distinct.size()), 5.0)
	var full_post := image_diff(_base, img, AREA)
	posterize.strength = 0.0
	await frames(2)
	img = await capture()
	check_lt("fx_posterize", "strength 0 is identity", image_diff(_base, img, AREA), 0.006)
	posterize.strength = 0.5
	await frames(2)
	img = await capture()
	check_between("fx_posterize", "strength 0.5 blends halfway (diff vs base between 30% and 70% of full strength)",
			image_diff(_base, img, AREA), full_post * 0.3, full_post * 0.7)
	posterize.strength = 1.0
	await _effect_off(posterize, "fx_posterize", "Posterize")

	var outline := LitPostOutline.new()
	outline.color = Color.BLACK
	outline.thickness = 3.0
	outline.threshold = 0.05
	outline.strength = 1.0
	img = await _effect_changes(outline, "fx_outline", "Outline")
	check_lt("fx_outline", "Outline darkens the bright disc's edge", lum(img, _pt(250, 50)), lum(_base, _pt(250, 50)), 0.1)
	outline.color = Color(1.0, 0.0, 0.0)
	await frames(2)
	img = await capture()
	c = probe(img, _pt(250, 50))
	check_gt("fx_outline", "outline colour red: the inked edge reads red over green", c.r, c.g, 0.2)
	outline.color = Color.BLACK
	await frames(2)
	img = await capture()
	var beyond := _pt(250, 50) + Vector2(0, -7)   # 7 screen px outside the disc's top edge
	var thin := lum(img, beyond)
	outline.thickness = 8.0
	await frames(2)
	img = await capture()
	check_lt("fx_outline", "thickness 8 inks further out than 3 (7 px outside the edge darkens)", lum(img, beyond), thin, 0.05)
	outline.thickness = 3.0
	await _effect_off(outline, "fx_outline", "Outline")

	var halftone := LitPostHalftone.new()
	halftone.dot_size = 14.0
	halftone.amount = 1.0
	img = await _effect_changes(halftone, "fx_halftone", "Halftone")
	check_gt("fx_halftone", "Halftone adds dot texture to the flat bright disc",
			image_variance(img, Rect2(_pt(232, 62), Vector2(36, 36))), image_variance(_base, Rect2(_pt(232, 62), Vector2(36, 36))), 0.002)
	halftone.ink_color = Color(1.0, 0.0, 0.0)
	halftone.paper_color = Color(0.0, 0.0, 1.0)
	await frames(2)
	img = await capture()
	var off_segment := 0
	for i in 30:
		if probe(img, _pt(10 + i * 10, 150), 0).g > 0.08:
			off_segment += 1
	check("fx_halftone", "ink red on paper blue: every sample lies on the red-blue segment (no green, 30 samples)", 0, off_segment)
	halftone.ink_color = Color.BLACK
	halftone.paper_color = Color.WHITE
	halftone.angle = 45.0
	await frames(2)
	img2 = await capture()
	halftone.angle = 0.0
	await frames(2)
	img = await capture()
	check_gt("fx_halftone", "angle 45 rotates the dot screen (differs from angle 0)", image_diff(img, img2, AREA), 0.01)
	halftone.amount = 0.0
	await frames(2)
	img = await capture()
	check_lt("fx_halftone", "amount 0 is identity", image_diff(_base, img, AREA), 0.006)
	halftone.amount = 1.0
	await _effect_off(halftone, "fx_halftone", "Halftone")

	var dither := LitPostDither.new()
	dither.levels = 2.0
	dither.pattern_scale = 4.0
	dither.strength = 1.0
	img = await _effect_changes(dither, "fx_dither", "Dither")
	check_gt("fx_dither", "Dither adds pattern to the gradient", image_variance(img, Rect2(_pt(120, 100), Vector2(60, 40))),
			image_variance(_base, Rect2(_pt(120, 100), Vector2(60, 40))), 0.002)
	dither.monochrome = true
	await frames(2)
	img = await capture()
	var tinted := 0
	for i in 30:
		c = probe(img, _pt(10 + i * 10, 100), 0)
		if absf(c.r - c.g) > 0.02 or absf(c.g - c.b) > 0.02:
			tinted += 1
	check("fx_dither", "monochrome: every sample is grey (30 samples)", 0, tinted)
	dither.monochrome = false
	dither.strength = 0.0
	await frames(2)
	img = await capture()
	check_lt("fx_dither", "strength 0 is identity", image_diff(_base, img, AREA), 0.006)
	dither.strength = 1.0
	await _effect_off(dither, "fx_dither", "Dither")

	var letterbox := LitPostLetterbox.new()
	letterbox.size = 0.15
	letterbox.softness = 0.0
	img = await _effect_changes(letterbox, "fx_letterbox", "Letterbox")
	check_approx("fx_letterbox", "top band is black", 0.0, lum(img, Vector2(700, 100)), 0.03)
	check_approx("fx_letterbox", "the middle is untouched", lum(_base, Vector2(700, 540)), lum(img, Vector2(700, 540)), 0.03)
	letterbox.color = Color(0.3, 0.0, 0.0)
	await frames(2)
	img = await capture()
	check_approx("fx_letterbox", "band colour follows the export", 0.3, probe(img, Vector2(700, 100)).r, 0.03)
	letterbox.color = Color.BLACK
	letterbox.softness = 0.1
	await frames(2)
	img = await capture()
	# bar = 1 - smoothstep(size, size + softness, edge distance): the feather runs from
	# y 162 to 270 px, so mid-feather (y 216) is half bar, half image.
	check_between("fx_letterbox", "softness 0.1: mid-feather reads between black and the base",
			lum(img, Vector2(700, 216)), 0.03, lum(_base, Vector2(700, 216)) - 0.03)
	letterbox.softness = 0.0
	await _effect_off(letterbox, "fx_letterbox", "Letterbox")

	var lens := LitPostLensDistortion.new()
	lens.amount = 1.5
	lens.edge_color = Color(1.0, 0.0, 0.0)
	img = await _effect_changes(lens, "fx_lens_distortion", "Lens Distortion")
	c = probe(img, Vector2(40, 110))
	check_gt("fx_lens_distortion", "corners show the edge colour", c.r, c.g, 0.2)
	lens.amount = 0.0
	lens.zoom = 2.0
	await frames(2)
	img = await capture()
	check_approx("fx_lens_distortion", "zoom 2 with no warp: 300 px right of centre shows what sat 150 px right",
			lum(_base, Vector2(960 + 150, 540)), lum(img, Vector2(960 + 300, 540)), 0.05)
	lens.zoom = 1.0
	lens.amount = 1.5
	await _effect_off(lens, "fx_lens_distortion", "Lens Distortion")

	var vhs := LitPostVhs.new()
	vhs.wobble_strength = 0.0
	vhs.wobble_speed = 0.0
	vhs.chroma_shift = 16.0
	vhs.bleed = 0.0
	vhs.grain = 0.0
	vhs.tracking_strength = 0.0
	vhs.roll_strength = 0.0
	img = await _effect_changes(vhs, "fx_vhs", "VHS (chroma shift alone)")
	var vr := _channel_diff(_base, img, AREA, 0)
	var vg := _channel_diff(_base, img, AREA, 1)
	var vb := _channel_diff(_base, img, AREA, 2)
	check_true("fx_vhs", "chroma_shift 16 alone splits red/blue more than green (%.3f / %.3f / %.3f)" % [vr, vg, vb],
			vr > vg * 1.3 or vb > vg * 1.3)
	vhs.chroma_shift = 0.0
	vhs.grain = 1.0
	await frames(2)
	img = await capture()
	check_gt("fx_vhs", "grain 1 alone adds noise to the flat bright disc",
			image_variance(img, Rect2(_pt(240, 70), Vector2(20, 20)), 1), image_variance(_base, Rect2(_pt(240, 70), Vector2(20, 20)), 1), 0.002)
	vhs.grain = 0.0
	vhs.bleed = 1.0
	await frames(2)
	img = await capture()
	check_gt("fx_vhs", "bleed 1 alone smears the chroma (image changes)", image_diff(_base, img, AREA), 0.005)
	vhs.bleed = 0.0
	for pair in [["wobble_strength", 8.0], ["roll_strength", 1.0]]:
		vhs.set(pair[0], pair[1])
		await frames(2)
		img = await capture()
		check_gt("fx_vhs", "%s %.0f alone changes the image" % [pair[0], pair[1]], image_diff(_base, img, AREA), 0.01)
		vhs.set(pair[0], 0.0)
	# The band rolls on TIME: locate it in the capture (half-width 130 px).
	vhs.tracking_strength = 1.0
	await frames(2)
	img = await capture()
	var rows := _row_diff_profile(_base, img)
	var peak_row := 0
	for i in rows.size():
		if rows[i] > rows[peak_row]:
			peak_row = i
	var far_sum := 0.0
	var far_n := 0
	for i in rows.size():
		if absi(i - peak_row) * ROW_STEP > 200:
			far_sum += rows[i]
			far_n += 1
	var far := far_sum / maxf(float(far_n), 1.0)
	check_gt("fx_vhs", "tracking_strength 1 alone: a damaged band exists somewhere on screen (peak row change at y %d px)" % (ROW_TOP + peak_row * ROW_STEP),
			rows[peak_row], 0.05)
	check_lt("fx_vhs", "tracking band is a band: rows over 200 px from its peak change under a quarter as much",
			far, rows[peak_row] * 0.25)
	vhs.tracking_strength = 0.0
	await _effect_off(vhs, "fx_vhs", "VHS")

	var crt := LitPostCrt.new()
	crt.curvature = 0.0
	crt.scanline_strength = 1.0
	crt.scanline_count = 120.0
	crt.mask_strength = 0.0
	crt.aberration = 0.0
	crt.vignette = 0.0
	img = await _effect_changes(crt, "fx_crt", "CRT")
	check_gt("fx_crt", "scanlines add vertical texture to the flat bright disc",
			image_variance(img, Rect2(_pt(240, 70), Vector2(20, 20)), 1), image_variance(_base, Rect2(_pt(240, 70), Vector2(20, 20)), 1), 0.002)
	crt.scanline_strength = 0.0
	crt.brightness = 2.0
	await frames(2)
	img = await capture()
	check_gt("fx_crt", "brightness 2 alone lifts the mid grey", lum(img, _pt(170, 119)), lum(_base, _pt(170, 119)), 0.1)
	crt.brightness = 1.0
	crt.mask_strength = 1.0
	await frames(2)
	img = await capture()
	check_gt("fx_crt", "mask_strength 1 alone adds the aperture grille to the flat disc",
			image_variance(img, Rect2(_pt(240, 70), Vector2(20, 20)), 1), image_variance(_base, Rect2(_pt(240, 70), Vector2(20, 20)), 1), 0.002)
	crt.mask_strength = 0.0
	crt.aberration = 8.0
	await frames(2)
	img = await capture()
	var ar := _channel_diff(_base, img, AREA, 0)
	var ag := _channel_diff(_base, img, AREA, 1)
	var ab := _channel_diff(_base, img, AREA, 2)
	check_true("fx_crt", "aberration 8 alone splits red/blue more than green (%.3f / %.3f / %.3f)" % [ar, ag, ab],
			ar > ag * 1.3 or ab > ag * 1.3)
	crt.aberration = 0.0
	crt.vignette = 1.0
	await frames(2)
	img = await capture()
	check_lt("fx_crt", "vignette 1 alone darkens the corner", lum(img, Vector2(60, 130)), lum(_base, Vector2(60, 130)), 0.1)
	check_approx("fx_crt", "vignette 1: the centre stays near the base", lum(_base, Vector2(700, 565)), lum(img, Vector2(700, 565)), 0.08)
	crt.vignette = 0.0
	crt.curvature = 1.0
	await frames(2)
	img = await capture()
	check_lt("fx_crt", "curvature 1 alone warps the corner off screen (black)", lum(img, Vector2(40, 110)), 0.05)
	crt.curvature = 0.0
	await _effect_off(crt, "fx_crt", "CRT")

	var aberration := LitPostAberration.new()
	aberration.amount = 16.0
	aberration.edge_falloff = 0.0
	img = await _effect_changes(aberration, "fx_aberration", "Chromatic Aberration")
	var dr := _channel_diff(_base, img, AREA, 0)
	var dg := _channel_diff(_base, img, AREA, 1)
	var db := _channel_diff(_base, img, AREA, 2)
	check_true("fx_aberration", "aberration moves the red/blue channels more than green (%.3f / %.3f / %.3f)" % [dr, dg, db],
			dr > dg * 1.3 or db > dg * 1.3)
	aberration.edge_falloff = 6.0
	await frames(2)
	img = await capture()
	var centre_split := _channel_diff(_base, img, Rect2(Vector2(860, 440), Vector2(200, 200)), 0)
	var corner_split := _channel_diff(_base, img, Rect2(AREA.position, Vector2(200, 200)), 0)
	check_lt("fx_aberration", "edge_falloff 6 concentrates the split at the edges (centre red diff under half the corner's)",
			centre_split, corner_split * 0.5)
	aberration.edge_falloff = 0.0
	await _effect_off(aberration, "fx_aberration", "Chromatic Aberration")

	var leaks := LitPostLightLeaks.new()
	leaks.intensity = 2.0
	leaks.speed = 0.0
	img = await _effect_changes(leaks, "fx_light_leaks", "Light Leaks")
	check_gt("fx_light_leaks", "Light Leaks brighten the image", image_mean(img, AREA).get_luminance(), image_mean(_base, AREA).get_luminance(), 0.02)
	leaks.color1 = Color(0.0, 1.0, 0.0)
	leaks.color2 = Color(0.0, 1.0, 0.0)
	await frames(2)
	img = await capture()
	var m := image_mean(img, AREA)
	var mb := image_mean(_base, AREA)
	check_gt("fx_light_leaks", "green leak colours raise the mean green", m.g, mb.g, 0.02)
	check_approx("fx_light_leaks", "green leak colours leave red alone", mb.r, m.r, 0.02)
	check_approx("fx_light_leaks", "green leak colours leave blue alone", mb.b, m.b, 0.02)
	leaks.texture = tex_solid(4, Color(1.0, 0.0, 0.0))
	await frames(2)
	img = await capture()
	check_gt("fx_light_leaks", "an assigned leak texture replaces the procedural leak (red now rises)", image_mean(img, AREA).r, mb.r, 0.02)
	check_approx("fx_light_leaks", "textured leak: green back at the base", mb.g, image_mean(img, AREA).g, 0.02)
	leaks.texture = null
	await _effect_off(leaks, "fx_light_leaks", "Light Leaks")

	var grain := LitPostFilmGrain.new()
	grain.intensity = 0.5
	grain.size = 2.0
	img = await _effect_changes(grain, "fx_film_grain", "Film Grain")
	check_gt("fx_film_grain", "grain adds noise to the flat bright disc",
			image_variance(img, Rect2(_pt(240, 70), Vector2(20, 20)), 1), image_variance(_base, Rect2(_pt(240, 70), Vector2(20, 20)), 1), 0.002)
	var disc := Rect2(_pt(240, 70), Vector2(20, 20))
	grain.luminance_response = 0.0
	await frames(2)
	img = await capture()
	# Mono grain scales every channel by one noise value, so (r - g) barely moves on the
	# (1, 0.95, 0.6) disc; coloured grain sparkles per channel.
	var mono_chroma := _chroma_variance(img, disc)
	var flat_grain := image_variance(img, disc, 1)
	grain.colored = true
	await frames(2)
	img = await capture()
	check_gt("fx_film_grain", "colored grain: per-channel sparkle (chroma variance well above mono's)",
			_chroma_variance(img, disc), maxf(mono_chroma * 3.0, 0.0003))
	grain.colored = false
	grain.luminance_response = 1.0
	await frames(2)
	img = await capture()
	check_lt("fx_film_grain", "luminance_response 1 fades the grain on the near-white disc", image_variance(img, disc, 1), flat_grain * 0.6)
	grain.luminance_response = 0.5
	await _effect_off(grain, "fx_film_grain", "Film Grain")

	var vignette := LitPostVignette.new()
	vignette.strength = 1.0
	vignette.softness = 0.5
	img = await _effect_changes(vignette, "fx_vignette", "Vignette")
	check_lt("fx_vignette", "corner darker than the base", lum(img, Vector2(60, 130)), lum(_base, Vector2(60, 130)), 0.1)
	check_approx("fx_vignette", "centre near the base", lum(_base, Vector2(700, 565)), lum(img, Vector2(700, 565)), 0.08)
	await _effect_off(vignette, "fx_vignette", "Vignette")

	var focus := LitPostFocus.new()
	focus.amount = -1.0
	focus.radius = 6.0
	focus.dream = 0.0
	img = await _effect_changes(focus, "fx_focus", "Focus (blur)")
	var checker := Rect2(_pt(20, 20), Vector2(150, 100))
	var disc_rect := Rect2(_pt(232, 62), Vector2(36, 36))
	var blur6 := image_variance(img, checker)
	var dream0 := image_mean(img, disc_rect).get_luminance()
	check_lt("fx_focus", "blur lowers the checker's variance", blur6, image_variance(_base, checker) * 0.8)
	focus.radius = 1.0
	await frames(2)
	img = await capture()
	check_gt("fx_focus", "radius 1 blurs less than radius 6 (more checker variance left)", image_variance(img, checker), blur6 * 1.2)
	focus.radius = 6.0
	focus.dream = 1.0
	await frames(2)
	img = await capture()
	check_gt("fx_focus", "dream 1 lifts the highlights (bright disc region brighter than dream 0)",
			image_mean(img, disc_rect).get_luminance(), dream0, 0.02)
	focus.dream = 0.0
	focus.amount = 1.0
	await frames(2)
	img = await capture()
	# original + (original - blurred) * amount: edges overshoot, so the checker's variance
	# rises (blur lowered it).
	check_gt("fx_focus", "sharpen raises the checker's variance", image_variance(img, Rect2(_pt(20, 20), Vector2(150, 100))),
			image_variance(_base, Rect2(_pt(20, 20), Vector2(150, 100))) * 1.05)
	await _effect_off(focus, "fx_focus", "Focus")


## Variance of (r - g) over a rect: zero for grey noise, positive for coloured noise.
func _chroma_variance(img: Image, rect: Rect2, step := 1) -> float:
	var p0 := to_px(rect.position, img)
	var p1 := to_px(rect.end, img)
	var vals: Array[float] = []
	var y := int(p0.y)
	while y < int(p1.y):
		var x := int(p0.x)
		while x < int(p1.x):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				var px := img.get_pixel(x, y)
				vals.append(px.r - px.g)
			x += step
		y += step
	if vals.is_empty():
		return 0.0
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= float(vals.size())
	var acc := 0.0
	for v in vals:
		acc += (v - mean) * (v - mean)
	return acc / float(vals.size())


func _channel_diff(a: Image, b: Image, rect: Rect2, ch: int, step := 4) -> float:
	var p0 := to_px(rect.position, a)
	var p1 := to_px(rect.end, a)
	var sum := 0.0
	var n := 0
	var y := int(p0.y)
	while y < int(p1.y):
		var x := int(p0.x)
		while x < int(p1.x):
			if x >= 0 and y >= 0 and x < a.get_width() and y < a.get_height() and x < b.get_width() and y < b.get_height():
				sum += absf(a.get_pixel(x, y)[ch] - b.get_pixel(x, y)[ch])
				n += 1
			x += step
		y += step
	return 0.0 if n == 0 else sum / float(n)


const ROW_STEP := 4
const ROW_TOP := 60   # below the status bar, whose text changes between captures


## Mean change per screen row (every ROW_STEP px from ROW_TOP), across AREA's width.
func _row_diff_profile(a: Image, b: Image) -> PackedFloat32Array:
	var x0 := int(to_px(AREA.position, a).x)
	var x1 := int(to_px(AREA.end, a).x)
	var out := PackedFloat32Array()
	var y := ROW_TOP
	while y < a.get_height() and y < b.get_height():
		var sum := 0.0
		var n := 0
		var x := x0
		while x < x1:
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
			x += ROW_STEP
		out.append(0.0 if n == 0 else sum / float(n * 3))
		y += ROW_STEP
	return out


func _chain() -> void:
	var case_name := "post_chain"
	# Order: letterbox then lens distortion bends the bars; lens then letterbox keeps them straight.
	var letterbox := LitPostLetterbox.new()
	letterbox.size = 0.15
	var lens := LitPostLensDistortion.new()
	lens.amount = 1.0
	_post.add_child(letterbox)
	_post.add_child(lens)
	await frames(2)
	var a := await capture()
	_post.move_child(lens, 0)
	await frames(2)
	var b := await capture()
	check_gt(case_name, "child order is the draw order (swapping two passes changes the image)",
			image_diff(a, b, AREA), 0.01)
	check_true(case_name, "pass layers follow the child order", lens._pass_layer.layer < letterbox._pass_layer.layer)
	check(case_name, "pass layer = host layer + index + 1", _post.layer + 1, lens._pass_layer.layer)
	var high := LitPostProcess.new()
	high.layer = 5
	high.visible = false
	add_child(high)
	var high_fx := LitPostVignette.new()
	high.add_effect(high_fx)
	high.visible = true
	await frames(1)
	check(case_name, "a host on layer 5 builds its first pass on layer 6", 6, high_fx._pass_layer.layer)
	high.queue_free()
	await frames(1)
	_post.visible = false
	await frames(2)
	var img := await capture()
	check_lt(case_name, "hidden host disables the whole chain", image_diff(_base, img, AREA), 0.006)
	check_true(case_name, "hidden host tears every pass down", lens._pass_layer == null and letterbox._pass_layer == null)
	letterbox.size = 0.3   # edited while hidden: must land on re-show
	_post.visible = true
	await frames(2)
	img = await capture()
	check_gt(case_name, "host shown again: passes rebuilt", image_diff(_base, img, AREA), 0.01)
	check_approx(case_name, "parameter edited while hidden applies on re-show (band now 30%)", 0.0,
			lum(img, Vector2(700, 300)), 0.05)
	letterbox.queue_free()
	lens.queue_free()
	await frames(1)
	# add_effect slots by rank regardless of insertion order.
	var v := LitPostVignette.new()
	var bl := LitPostBloom.new()
	var lb := LitPostLetterbox.new()
	for fx in [v, bl, lb]:
		fx.visible = false
		_post.add_effect(fx)
	var order: Array = []
	for ch in _post.get_children():
		if ch is LitPostEffect and not _hidden.has(ch):
			order.append(ch)
	check_true(case_name, "add_effect orders by rank: bloom (20) before letterbox (120) before vignette (190)",
			order.size() >= 3 and order[-3] == bl and order[-2] == lb and order[-1] == v)
	# An effect outside a host is inert.
	var stray := LitPostVignette.new()
	stray.strength = 1.0
	add_child(stray)
	await frames(2)
	img = await capture()
	check_true(case_name, "effect outside a LitPostProcess warns", stray._get_configuration_warnings().size() > 0)
	check_true(case_name, "effect outside a host builds no pass", stray._pass_layer == null)
	check_lt(case_name, "and leaves the image alone", image_diff(_base, img, AREA), 0.006)
	stray.queue_free()



func _custom() -> void:
	var case_name := "post_custom_effect"
	var fx := InvertEffect.new()
	_post.add_effect(fx)
	await frames(2)
	var img := await capture()
	var p := Vector2(700, 540)
	var cb := probe(_base, p)
	var c := probe(img, p)
	check_approx(case_name, "a LitPostEffect subclass with its own shader runs as a pass (inverted red)", 1.0 - cb.r, c.r, 0.04)
	check_approx(case_name, "inverted green", 1.0 - cb.g, c.g, 0.04)
	check_true(case_name, "custom effects default to the end of the chain (rank 1000)",
			_post.get_child(_post.get_child_count() - 1) == fx)
	fx.amount = 0.0
	fx.apply_params()
	await frames(2)
	img = await capture()
	check_lt(case_name, "_param_map export mirrored through apply_params (amount 0 = identity)", image_diff(_base, img, AREA), 0.006)
	fx.queue_free()


func _auto_exposure() -> void:
	var case_name := "fx_auto_exposure"
	# Eye adaptation reacts to change from a baseline the meter learns on its first
	# valid frame, so the scene is settled before the pass is shown and the change
	# comes afterwards. Scenes stay well above the meter's near-black "blind" level.
	var dim := Color(0.3, 0.3, 0.3)
	var region := Rect2(300, 300, 800, 500)
	var ae := LitPostAutoExposure.new()
	ae.amount = 1.0
	ae.max_exposure = 3.0
	ae.min_exposure = -3.0
	ae.dark_adapt_time = 0.05
	ae.light_adapt_time = 0.05
	ae.acclimate_time = 30.0
	ae.histogram_low = 0.1
	ae.show_meter = true
	ae.visible = false
	_post.add_effect(ae)
	_base_sprite.modulate = dim
	await frames(3)
	var dark := await capture()
	_base_sprite.modulate = Color.WHITE
	await frames(3)
	var bright := await capture()
	# Learn bright, then go dark: the eye opens up.
	ae.visible = true
	await get_tree().create_timer(0.5).timeout
	check_true(case_name, "auto exposure builds its metering viewports while active", ae._reduce_vp != null)
	# show_meter paints the EV bar over SCREEN_UV (0.035..0.335, 0.045..0.067): screen
	# y 49..72, above the base image (black there), so the bar's grey is the only light.
	var img := await capture()
	var c := probe(img, Vector2(400, 70), 1)
	check_gt(case_name, "show_meter draws the EV bar over the black strip above the image", c.r + c.g + c.b, 0.1)
	ae.show_meter = false
	await frames(2)
	img = await capture()
	c = probe(img, Vector2(400, 70), 1)
	check_lt(case_name, "show_meter off: the strip is black again", c.r + c.g + c.b, 0.02)
	ae.show_meter = true
	_base_sprite.modulate = dim
	await get_tree().create_timer(0.4).timeout
	await frames(2)
	img = await capture()
	check_gt(case_name, "after the scene goes dark the eye opens up (brighter than the raw dark base)",
			image_mean(img, region).get_luminance(), image_mean(dark, region).get_luminance(), 0.03)
	# Learn dark, then go bright: the eye squints.
	ae.visible = false
	await frames(3)
	ae.visible = true
	await get_tree().create_timer(0.5).timeout
	_base_sprite.modulate = Color.WHITE
	await get_tree().create_timer(0.3).timeout
	await frames(2)
	img = await capture()
	check_lt(case_name, "after a sudden bright scene the eye squints (dimmer than the raw bright base)",
			image_mean(img, region).get_luminance(), image_mean(bright, region).get_luminance(), 0.03)
	_base_sprite.modulate = dim
	await frames(2)
	ae.visible = false
	await frames(2)
	check_true(case_name, "hidden: metering viewports torn down", ae._reduce_vp == null)
	img = await capture()
	check_lt(case_name, "hidden restores the dark base", image_diff(dark, img, AREA), 0.006)
	_base_sprite.modulate = Color.WHITE
	# Exposure compensation biases the settled exposure: after acclimating on the same
	# bright scene, +1 EV reads brighter than 0 EV.
	await frames(3)
	ae.exposure_compensation = 0.0
	ae.visible = true
	await get_tree().create_timer(0.5).timeout
	await frames(2)
	var settled0 := image_mean(await capture(), region).get_luminance()
	ae.visible = false
	await frames(3)
	ae.exposure_compensation = 1.0
	ae.visible = true
	await get_tree().create_timer(0.5).timeout
	await frames(2)
	var settled1 := image_mean(await capture(), region).get_luminance()
	check_gt(case_name, "exposure_compensation +1 EV: the settled image reads brighter than at 0 EV", settled1, settled0, 0.03)
	ae.exposure_compensation = 0.0
	ae.visible = false
	await frames(2)
