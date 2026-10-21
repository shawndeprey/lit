extends LitSuiteSection

## Harness self-check plus LitCanvasModulate (ambient / darkness).
##
## Calibrates the pixel probe (an unlit white sprite must read white where the probe
## says it is) so every later section's readbacks can be trusted, then checks the
## ambient contract: a receiver with no light renders albedo x ambient colour x
## energy, the colour tints, the energy scales, the last modulate to enter wins, and
## a native CanvasModulate is diagnosed as a conflict.

var _modulate: LitCanvasModulate


# Enables the editor-only warning refresh hook in game mode.
class _RefreshProbe extends LitCanvasModulate:
	func _refreshes_warnings() -> bool:
		return true


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
	var root := get_tree().get_root()
	var second_warnings := second._get_configuration_warnings()
	check_true("ambient", "multiple modulates raise an editor configuration warning",
			second_warnings.size() > 0)
	check_true("ambient", "the warning names the other modulate's path",
			second_warnings.size() == 1 and String(root.get_path_to(_modulate)) in second_warnings[0])
	check_true("ambient", "the first modulate names the second one too",
			String(root.get_path_to(second)) in "".join(_modulate._get_configuration_warnings()))
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
			_modulate._native_canvas_modulates() == [native])
	var native_warnings := _modulate._get_configuration_warnings()
	check_true("ambient", "conflict shows as a configuration warning", native_warnings.size() > 0)
	check_true("ambient", "the warning names the native node's path",
			native_warnings.size() > 0 and String(root.get_path_to(native)) in native_warnings[0])
	native.queue_free()
	await frames(1)
	check_true("ambient", "no warning once the native CanvasModulate is gone",
			_modulate._get_configuration_warnings().is_empty())

	# One modulate per CanvasLayer: ambient is global, so the last to enter wins on
	# every layer and each modulate must warn about the other.
	c = cell("modulate per CanvasLayer\n(global: last to enter wins everywhere)")
	var base_box := box_receiver(cell_center(c) + Vector2(-70, 0), Vector2(50, 50))
	var layer_a := CanvasLayer.new()
	layer_a.name = "Background"
	layer_a.layer = 1
	add_child(layer_a)
	var mod_a := LitCanvasModulate.new()
	mod_a.name = "ModA"
	mod_a.color = Color(0.3, 0.3, 0.3)
	layer_a.add_child(mod_a)
	var box_a := box_receiver(cell_center(c), Vector2(50, 50), Color.WHITE, layer_a)
	var layer_b := CanvasLayer.new()
	layer_b.name = "Foreground"
	layer_b.layer = 2
	add_child(layer_b)
	var mod_b := LitCanvasModulate.new()
	mod_b.name = "ModB"
	mod_b.color = Color(0.6, 0.6, 0.6)
	layer_b.add_child(mod_b)
	var box_b := box_receiver(cell_center(c) + Vector2(70, 0), Vector2(50, 50), Color.WHITE, layer_b)
	img = await capture()
	check_approx("modulate_scoping", "receiver on CanvasLayer 1 reads the last modulate (0.6)",
			0.6, lum(img, box_a.position), 0.03)
	check_approx("modulate_scoping", "receiver on CanvasLayer 2 reads the same ambient",
			0.6, lum(img, box_b.position), 0.03)
	check_approx("modulate_scoping", "base canvas receiver reads the same ambient",
			0.6, lum(img, base_box.position), 0.03)
	var warn_a := "".join(mod_a._get_configuration_warnings())
	check_true("modulate_scoping", "a modulate under one CanvasLayer warns about the one under another",
			String(root.get_path_to(mod_b)) in warn_a)
	check_true("modulate_scoping", "the warning says ambient is not scoped per CanvasLayer",
			"CanvasLayer" in warn_a)
	check_true("modulate_scoping", "the other layer's modulate warns back",
			String(root.get_path_to(mod_a)) in "".join(mod_b._get_configuration_warnings()))
	for n in [layer_a, layer_b, base_box]:
		n.queue_free()
	await frames(1)

	# Modulates inside a non-editable instance are hidden in the scene dock; the
	# instancing scene's modulate must still name them by path.
	var packed_root := Node2D.new()
	for layer_name in ["Background", "Foreground"]:
		var cl := CanvasLayer.new()
		cl.name = layer_name
		packed_root.add_child(cl)
		cl.owner = packed_root
		var cm := LitCanvasModulate.new()
		cl.add_child(cm)
		cm.owner = packed_root
	var packed := PackedScene.new()
	packed.pack(packed_root)
	packed_root.free()
	var inst := packed.instantiate()
	inst.name = "Backgrounds"
	add_child(inst)
	var inner: Array = []
	for m in get_tree().get_nodes_in_group(LitCanvasModulate.GROUP):
		if inst.is_ancestor_of(m):
			inner.append(m)
	var warn_inst := "".join(_modulate._get_configuration_warnings())
	check_true("modulate_scoping", "two modulates were instanced from the packed scene", inner.size() == 2)
	check_true("modulate_scoping", "both instanced modulates are named by path in the warning",
			inner.size() == 2 and String(root.get_path_to(inner[0])) in warn_inst
			and String(root.get_path_to(inner[1])) in warn_inst)
	inst.queue_free()
	await frames(1)
	check_true("modulate_scoping", "the warning clears once the instance is gone",
			_modulate._get_configuration_warnings().is_empty())

	# Editor refresh push: the dock only re-queries a node whose own warning signal
	# fired, so modulates entering or leaving the tree must dirty every Lit modulate.
	var tree := get_tree()
	var pings: Array = []
	var on_changed := func(n: Node) -> void: pings.append(n)
	tree.edited_scene_root = self
	tree.node_configuration_warning_changed.connect(on_changed)
	var probe_mod := _RefreshProbe.new()
	probe_mod.name = "RefreshProbe"
	add_child(probe_mod)
	await frames(1)
	pings.clear()
	var native2 := CanvasModulate.new()
	add_child(native2)
	await frames(1)
	check_true("modulate_scoping", "a native CanvasModulate entering dirties the Lit modulate's warning",
			probe_mod in pings)
	pings.clear()
	native2.free()
	await frames(1)
	check_true("modulate_scoping", "the native CanvasModulate leaving dirties it again", probe_mod in pings)
	pings.clear()
	var other := LitCanvasModulate.new()
	add_child(other)
	await frames(1)
	check_true("modulate_scoping", "another LitCanvasModulate entering dirties it", probe_mod in pings)
	pings.clear()
	var plain := Node2D.new()
	add_child(plain)
	await frames(1)
	check_true("modulate_scoping", "an unrelated node entering does not", not (probe_mod in pings))
	tree.node_configuration_warning_changed.disconnect(on_changed)
	tree.edited_scene_root = null
	for n in [other, plain, probe_mod]:
		n.queue_free()
	await frames(1)
	_modulate.color = Color(0.2, 0.2, 0.2)

	say("SUITE   project lighting model setting: %d (each section run pins its own model; see model=)" % int(
			_settings_saved.get("lit/render/lighting_model", 0)))
	# Version stamp plumbing.
	check_true("version", "plugin.cfg carries a version", lit_version != "" and lit_version != "0")
	check_true("version", "LitVersionStamp leaves runtime nodes unstamped (editor-only)",
			String(recv.lit_version).is_empty())
