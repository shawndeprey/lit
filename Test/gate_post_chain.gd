extends Node2D

## Post-chain hash gate: a deterministic procedural base image run through the
## LitPostProcess chain (built from LitPostEffect child nodes) with passes at
## non-default values, captured and hashed. Catches wrong-shader, wrong-param, and
## wrong-order regressions in the chain.
##
## Every TIME-animated knob is frozen (speeds 0); Film Grain has no freeze knob
## (fract(TIME) reseeds every frame) and stays disabled - its wiring is identical
## table code, covered by review.
##
## Usage:
##   godot --path . res://Test/gate_post_chain.tscn -- out=PATH [subset=display]
##   subset=display enables only the display-medium tail (order-sensitivity check);
##   default enables every deterministic pass.
##
## Baselines (RX 7900 XTX, 1920x1080, 2026-08-01; hashes are machine-local - compare
## pre/post within one machine, re-baseline only with an intended visual change):
##   all     c38752ba5c32f7bdbf0a1d9f0af405b4
##   display 9d3fc542807fe787ba25e89dc611c823

var _out := ""
var _subset := "all"


func _ready() -> void:
	var vp := get_viewport_rect().size

	# Base image: gradient + checker + discs, enough edges and hues for the outline,
	# halftone, dither, and grading passes to bite. Pure pixel math, no randomness.
	var img := Image.create(320, 180, false, Image.FORMAT_RGBA8)
	for y in 180:
		for x in 320:
			var c := Color(float(x) / 320.0, float(y) / 180.0, 1.0 - float(x) / 320.0)
			if (x / 20 + y / 20) % 2 == 0:
				c = c.lightened(0.25)
			var dx := x - 240
			var dy := y - 60
			if dx * dx + dy * dy < 900:
				c = Color(1.0, 0.9, 0.2)
			var ex := x - 80
			var ey := y - 120
			if ex * ex + ey * ey < 400:
				c = Color(0.1, 0.1, 0.12)
			img.set_pixel(x, y, c)
	var spr := Sprite2D.new()
	spr.texture = ImageTexture.create_from_image(img)
	spr.centered = false
	spr.scale = vp / Vector2(320, 180)
	add_child(spr)

	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"out":
				_out = kv[1]
			"subset":
				_subset = kv[1]

	add_child(_build_chain())
	if _out != "":
		_capture.call_deferred()


func _build_chain() -> LitPostProcess:
	var post := LitPostProcess.new()
	var display_only := _subset == "display"
	if not display_only:
		var threshold := LitPostThreshold.new()
		threshold.cutoff = 0.12
		post.add_child(threshold)
		var bloom := LitPostBloom.new()
		bloom.threshold = 0.5
		bloom.intensity = 1.2
		bloom.radius = 5.5
		post.add_child(bloom)
		var halation := LitPostHalation.new()
		halation.threshold = 0.45
		halation.intensity = 1.1
		halation.tint = Color(0.9, 0.35, 0.15)
		post.add_child(halation)
		var glitch := LitPostGlitch.new()
		glitch.intensity = 0.6
		glitch.block_size = 18.0
		glitch.rgb_shift = 6.0
		glitch.speed = 0.0                 # frozen: deterministic capture
		post.add_child(glitch)
		var grade := LitPostColorGrade.new()
		grade.exposure = 1.25
		grade.contrast = 1.15
		grade.saturation = 0.8
		grade.tint = Color(0.95, 0.9, 1.0)
		post.add_child(grade)
		var lut := LitPostLut.new()
		lut.preset = LitPostLut.LutPreset.TEAL_ORANGE
		lut.amount = 0.7
		post.add_child(lut)
		var pixelate := LitPostPixelate.new()
		pixelate.pixel_size = 3.0
		post.add_child(pixelate)
		var posterize := LitPostPosterize.new()
		posterize.levels = 6.0
		posterize.strength = 0.8
		post.add_child(posterize)
		var outline := LitPostOutline.new()
		outline.color = Color(0.1, 0.0, 0.2)
		outline.thickness = 1.5
		outline.threshold = 0.15
		outline.strength = 0.9
		post.add_child(outline)
		var halftone := LitPostHalftone.new()
		halftone.dot_size = 7.0
		halftone.angle = 25.0
		halftone.amount = 0.5
		post.add_child(halftone)
		var dither := LitPostDither.new()
		dither.levels = 5.0
		dither.pattern_scale = 2.0
		dither.strength = 0.6
		post.add_child(dither)
		var leaks := LitPostLightLeaks.new()
		leaks.intensity = 0.8
		leaks.speed = 0.0                  # frozen: deterministic capture
		leaks.color1 = Color(1.0, 0.4, 0.1)
		post.add_child(leaks)
	var letterbox := LitPostLetterbox.new()
	letterbox.size = 0.09
	letterbox.softness = 0.02
	post.add_child(letterbox)
	var lens := LitPostLensDistortion.new()
	lens.amount = 0.3
	lens.zoom = 1.05
	post.add_child(lens)
	var vhs := LitPostVhs.new()
	vhs.wobble_strength = 3.0
	vhs.wobble_speed = 0.0                 # frozen: deterministic capture
	vhs.chroma_shift = 3.0
	vhs.bleed = 0.6
	vhs.grain = 0.0                        # TIME-noise off: deterministic capture
	# Tracking band interior is raw-TIME noise (unfreezable, like Film Grain); off.
	vhs.tracking_strength = 0.0
	vhs.tracking_speed = 0.0
	vhs.roll_strength = 0.0                # frozen: deterministic capture
	post.add_child(vhs)
	var crt := LitPostCrt.new()
	crt.curvature = 0.3
	crt.scanline_strength = 0.4
	crt.scanline_count = 200.0
	crt.mask_strength = 0.35
	crt.brightness = 1.3
	post.add_child(crt)
	var aberration := LitPostAberration.new()
	aberration.amount = 4.0
	post.add_child(aberration)
	var vignette := LitPostVignette.new()
	vignette.strength = 0.5
	vignette.softness = 0.4
	post.add_child(vignette)
	var focus := LitPostFocus.new()
	focus.amount = -0.4
	focus.radius = 2.5
	focus.dream = 0.3
	post.add_child(focus)
	return post


func _capture() -> void:
	# Deterministic captures start after the launch precompile takeover, if one ran.
	var mgr := get_node_or_null("/root/LitManager")
	if mgr != null and mgr.precompiler != null:
		if mgr.precompiler.is_processing():
			await mgr.precompiler.finished
		while get_tree().root.get_node_or_null("LitPrecompileOverlay") != null:
			await RenderingServer.frame_post_draw
	for i in 8:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out)
	print("POSTGATE subset=%s saved=%s" % [_subset, _out])
	get_tree().quit()
