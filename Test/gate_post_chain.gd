extends Node2D

## Post-chain hash gate: a deterministic procedural base image run through the
## LitPostProcess chain with passes at non-default values, captured and hashed.
## Catches wrong-shader, wrong-param, and wrong-order regressions in the chain.
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
		post.threshold_enabled = true
		post.threshold_cutoff = 0.12
		post.bloom_enabled = true
		post.bloom_threshold = 0.5
		post.bloom_intensity = 1.2
		post.bloom_radius = 5.5
		post.halation_enabled = true
		post.halation_threshold = 0.45
		post.halation_intensity = 1.1
		post.halation_tint = Color(0.9, 0.35, 0.15)
		post.glitch_enabled = true
		post.glitch_intensity = 0.6
		post.glitch_block_size = 18.0
		post.glitch_rgb_shift = 6.0
		post.glitch_speed = 0.0            # frozen: deterministic capture
		post.grade_enabled = true
		post.exposure = 1.25
		post.contrast = 1.15
		post.saturation = 0.8
		post.tint = Color(0.95, 0.9, 1.0)
		post.lut_enabled = true
		post.lut_preset = LitPostProcess.LutPreset.TEAL_ORANGE
		post.lut_amount = 0.7
		post.pixelate_enabled = true
		post.pixelate_size = 3.0
		post.posterize_enabled = true
		post.posterize_levels = 6.0
		post.posterize_strength = 0.8
		post.outline_enabled = true
		post.outline_color = Color(0.1, 0.0, 0.2)
		post.outline_thickness = 1.5
		post.outline_threshold = 0.15
		post.outline_strength = 0.9
		post.halftone_enabled = true
		post.halftone_dot_size = 7.0
		post.halftone_angle = 25.0
		post.halftone_amount = 0.5
		post.dither_enabled = true
		post.dither_levels = 5.0
		post.dither_scale = 2.0
		post.dither_strength = 0.6
		post.leaks_enabled = true
		post.leaks_intensity = 0.8
		post.leaks_speed = 0.0             # frozen: deterministic capture
		post.leaks_color1 = Color(1.0, 0.4, 0.1)
	post.letterbox_enabled = true
	post.letterbox_size = 0.09
	post.letterbox_softness = 0.02
	post.lens_enabled = true
	post.lens_amount = 0.3
	post.lens_zoom = 1.05
	post.vhs_enabled = true
	post.vhs_wobble_strength = 3.0
	post.vhs_wobble_speed = 0.0            # frozen: deterministic capture
	post.vhs_chroma_shift = 3.0
	post.vhs_bleed = 0.6
	post.vhs_grain = 0.0                   # TIME-noise off: deterministic capture
	# Tracking band interior is raw-TIME noise (unfreezable, like Film Grain); off.
	post.vhs_tracking_strength = 0.0
	post.vhs_tracking_speed = 0.0
	post.vhs_roll_strength = 0.0           # frozen: deterministic capture
	post.crt_enabled = true
	post.crt_curvature = 0.3
	post.crt_scanline_strength = 0.4
	post.crt_scanline_count = 200.0
	post.crt_mask_strength = 0.35
	post.crt_brightness = 1.3
	post.aberration_enabled = true
	post.aberration_amount = 4.0
	post.vignette_enabled = true
	post.vignette_strength = 0.5
	post.vignette_softness = 0.4
	post.focus_enabled = true
	post.focus_amount = -0.4
	post.focus_radius = 2.5
	post.focus_dream = 0.3
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
