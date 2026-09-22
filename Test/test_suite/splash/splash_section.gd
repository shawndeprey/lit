extends LitSuiteSection

## LitSplashScreen: builds its logo, background and glitch pass on layer 100, plays on
## autoplay (logo fades in over the black background), skip() ends it early, the
## finished signal fires, and auto_free removes the node. autoplay = false keeps it
## hidden until play().

var _finished_fired := false


func run() -> void:
	var case_name := "splash_screen"
	label("splash screen playing (logo fades in over black), then skipped", Vector2(24, 74))
	var splash := LitSplashScreen.new()
	splash.sfx = null            # no audio: keeps the run silent and short
	splash.fade_in_time = 0.05
	splash.hold_time = 2.0
	splash.fade_out_time = 0.05
	splash.finished.connect(func() -> void: _finished_fired = true)
	add_child(splash)
	await frames(6)
	check(case_name, "splash sits on canvas layer 100", 100, splash.layer)
	check_true(case_name, "autoplay: playing after entering the tree", splash._playing)
	check_true(case_name, "logo TextureRect built with the default logo", splash._logo_rect != null and splash._logo_rect.texture != null)
	check_true(case_name, "glitch pass visible while the intro plays", splash._glitch_pass.visible)
	# Probe pixels only once the glitch pass is hidden: its flicker adds 0.2 anywhere.
	await _glitch_window_closed(splash)
	check_true(case_name, "glitch pass hides itself once its window has passed", not splash._glitch_pass.visible)
	var img := await capture()
	check_gt(case_name, "the logo is drawn over the black background (centre area not black)",
			image_mean(img, Rect2(560, 340, 800, 400)).get_luminance(), 0.0, 0.01)
	check_approx(case_name, "a corner is the background colour (black)", 0.0, lum(img, Vector2(40, 1040)), 0.02)
	splash.skip()
	var waited := 0.0
	while not _finished_fired and waited < 2.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	check_true(case_name, "skip() ends the splash and emits finished", _finished_fired)
	await frames(2)
	check_true(case_name, "auto_free frees the node after finishing", not is_instance_valid(splash))
	var manual := LitSplashScreen.new()
	manual.autoplay = false
	manual.auto_free = false
	manual.sfx = null
	add_child(manual)
	await frames(1)
	check(case_name, "autoplay = false: hidden until play()", false, manual.visible)
	manual.play()
	await frames(1)
	check_true(case_name, "play() starts it", manual._playing and manual.visible)
	manual.skip()
	waited = 0.0
	while is_instance_valid(manual) and manual.visible and waited < 3.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	check_true(case_name, "auto_free = false: node survives, hidden", is_instance_valid(manual) and not manual.visible)
	manual.queue_free()

	# Parameters and input skipping: red background, a solid green logo at 20 % of the
	# screen height, not skippable at first.
	case_name = "splash_parameters"
	var styled := LitSplashScreen.new()
	styled.sfx = null
	styled.background_color = Color(0.2, 0.0, 0.0)
	styled.logo = tex_solid(64, Color(0.0, 1.0, 0.0))
	styled.logo_screen_ratio = 0.2
	styled.fade_in_time = 0.05
	styled.hold_time = 5.0
	styled.fade_out_time = 0.05
	styled.skippable = false
	var styled_done := [false]   # lambdas capture locals by value: an array is shared
	styled.finished.connect(func() -> void: styled_done[0] = true)
	add_child(styled)
	await get_tree().create_timer(0.1).timeout
	await frames(2)
	# Checked against the splash's own clock, not wall time.
	var e: float = styled._elapsed
	if e < styled._glitch_len:
		var k := clampf(e / 0.1, 0.0, 1.0) * clampf((styled._glitch_len - e) / 0.6, 0.0, 1.0)
		check_approx(case_name, "glitch envelope: intensity follows the attack/decay curve (%.2f s in)" % e,
				styled.glitch_strength * k, float(styled._glitch_mat.get_shader_parameter("intensity")), 0.02)
	else:
		check_true(case_name, "glitch envelope: window already over (%.2f s in), pass hidden" % e, not styled._glitch_pass.visible)
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	await frames(3)
	check_true(case_name, "skippable = false: a key press does not end the splash", styled._playing and not styled_done[0])
	key.pressed = false
	Input.parse_input_event(key)
	await _glitch_window_closed(styled)
	check_true(case_name, "glitch envelope: the glitch pass hides itself once its window has passed", not styled._glitch_pass.visible)
	img = await capture()
	check_approx(case_name, "background_color: a corner reads the red background", 0.2, probe(img, Vector2(40, 1040)).r, 0.03)
	var centre := probe(img, Vector2(960, 540))
	check_true(case_name, "custom logo: the centre reads the green logo over the red background", centre.g > 0.5 and centre.r < 0.3)
	# The ratio is of the screen width (0.2 x 1920 = 384 px, square logo: 192 px above
	# the centre); 240 px up is background at 0.2 and inside the logo at 0.6.
	check_lt(case_name, "logo_screen_ratio 0.2: 240 px above the centre is background (a 0.6 logo would cover it)",
			probe(img, Vector2(960, 300)).g, 0.1)
	styled.skippable = true
	key.pressed = true
	Input.parse_input_event(key)
	waited = 0.0
	while not styled_done[0] and waited < 1.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	check_true(case_name, "skippable = true: a key press skips and finishes the splash", styled_done[0])
	await frames(2)
	check_true(case_name, "auto_free after the skip frees the node", not is_instance_valid(styled))


## Waits for the glitch pass to hide (its window is _glitch_len); 3 s cap.
func _glitch_window_closed(splash: LitSplashScreen) -> void:
	var waited := 0.0
	while is_instance_valid(splash) and splash._glitch_pass.visible and waited < 3.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	await frames(2)
