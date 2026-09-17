extends LitSuiteSection

## Harness self-check plus LitCanvasModulate (ambient / darkness).
##
## Calibrates the pixel probe (an unlit white sprite must read white where the probe
## says it is) so every later section's readbacks can be trusted, then checks the
## ambient contract: a receiver with no light renders albedo x ambient colour x
## energy, the colour tints, the energy scales, the last modulate to enter wins, and
## a native CanvasModulate is diagnosed as a conflict.

var _modulate: LitCanvasModulate


func run() -> void:
	# A plain sprite ignores Lit entirely: it pins the probe mapping.
	var c := cell("probe calibration\n(unlit white / black sprites)")
	var white_spr := marker(cell_center(c) + Vector2(-50, 0), Vector2(60, 60), Color.WHITE)
	var black_spr := marker(cell_center(c) + Vector2(50, 0), Vector2(60, 60), Color.BLACK)

	# Receivers under ambient only (no light anywhere in this section).
	_modulate = env(Color(0.2, 0.2, 0.2), 1.0)
	c = cell("receiver under ambient 0.2\n(no lights: albedo x ambient)")
	var recv := lit_sprite(white(), cell_center(c), 60.0)
	recv.specular_strength = 0.0
	c = cell("red albedo x ambient")
	var red := lit_sprite(white(), cell_center(c), 60.0)
	red.modulate = Color(1.0, 0.0, 0.0)
	red.specular_strength = 0.0
	c = cell("plain Sprite2D + receiver material\n(same result as LitSprite2D)")
	var bare := Sprite2D.new()
	bare.texture = white()
	bare.material = receiver_material()
	bare.material.set_shader_parameter("specular_strength", 0.0)
	place(bare, c, Vector2.ZERO, 60.0)

	await frames(3)
	var img := await capture()
	check_approx("probe_calibration", "unlit white sprite reads white", 1.0,
			lum(img, white_spr.position), 0.03)
	check_approx("probe_calibration", "unlit black sprite reads black", 0.0,
			lum(img, black_spr.position), 0.03)
	check_true("probe_calibration", "capture is at least 640 px wide", img.get_width() >= 640)

	var lit_level := lum(img, recv.position)
	check_approx("ambient", "white receiver with no light = ambient 0.2", 0.2, lit_level, 0.03)
	var red_c := probe(img, red.position)
	check_approx("ambient", "red receiver: red channel = ambient", 0.2, red_c.r, 0.03)
	check_approx("ambient", "red receiver: green channel 0", 0.0, red_c.g, 0.03)
	check_approx("ambient", "bare Sprite2D on the receiver material matches LitSprite2D",
			lit_level, lum(img, bare.position), 0.02)

	# Colour tint.
	_modulate.color = Color(0.4, 0.2, 0.1)
	img = await capture()
	var tint := probe(img, recv.position)
	check_approx("ambient", "ambient colour tints (0.4, 0.2, 0.1)", Color(0.4, 0.2, 0.1), tint, 0.03)

	# Energy scales.
	_modulate.ambient_energy = 2.0
	img = await capture()
	check_approx("ambient", "ambient_energy 2 doubles the tint", Color(0.8, 0.4, 0.2),
			probe(img, recv.position), 0.04)
	_modulate.ambient_energy = 1.0
	_modulate.color = Color(0.2, 0.2, 0.2)

	# Last modulate to enter the tree wins.
	var second := LitCanvasModulate.new()
	second.color = Color(0.6, 0.6, 0.6)
	add_child(second)
	img = await capture()
	check_approx("ambient", "second LitCanvasModulate (last to enter) wins", 0.6,
			lum(img, recv.position), 0.03)
	check_true("ambient", "multiple modulates raise an editor configuration warning",
			second._get_configuration_warnings().size() > 0)
	second.queue_free()
	await frames(1)
	# Nothing restores on exit by design; re-applying the first one lands its values.
	_modulate.color = Color(0.2, 0.2, 0.2)
	img = await capture()
	check_approx("ambient", "re-applying the first modulate lands its colour", 0.2,
			lum(img, recv.position), 0.03)

	# Native CanvasModulate conflict diagnosis.
	var native := CanvasModulate.new()
	native.color = Color.WHITE
	add_child(native)
	check_true("ambient", "native CanvasModulate is detected as a conflict",
			_modulate._find_native_canvas_modulate())
	check_true("ambient", "conflict shows as a configuration warning",
			_modulate._get_configuration_warnings().size() > 0)
	native.queue_free()
	await frames(1)
	check_true("ambient", "no warning once the native CanvasModulate is gone",
			_modulate._get_configuration_warnings().is_empty())

	print("SUITE   project lighting model setting: %d (each section run pins its own model; see model=)" % int(
			_settings_saved.get("lit/render/lighting_model", 0)))
	# Version stamp plumbing.
	check_true("version", "plugin.cfg carries a version", lit_version != "" and lit_version != "0")
	check_true("version", "LitVersionStamp leaves runtime nodes unstamped (editor-only)",
			String(recv.lit_version).is_empty())
