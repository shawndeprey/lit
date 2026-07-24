extends Node2D

## Y-sort shadow test bed: wall + cinderskull + floor. Arrows move the skull; Y
## toggles lit/render/y_sorting. CLI (after "--"): out=PATH skullx=N skully=N
## ysort=on|off algo=raymarch|cone|stochastic band=N

const ALGO_IDS := {"raymarch": 0, "cone": 1, "stochastic": 2}

const WALL_POS := Vector2(960, 560)      # the wall's base line
const LIGHT_POS := Vector2(400, 260)

var _skull: Node2D
var _light: LitPointLight2D
var _hud: Label
var _out := ""


func _ready() -> void:
	var vp := get_viewport_rect().size

	var canvas_modulate := LitCanvasModulate.new()
	canvas_modulate.color = Color(0.06, 0.06, 0.07)
	add_child(canvas_modulate)

	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var white := ImageTexture.create_from_image(img)

	var floor_spr := Sprite2D.new()
	floor_spr.texture = white
	floor_spr.modulate = Color(0.75, 0.73, 0.7)
	floor_spr.position = vp * 0.5
	floor_spr.scale = vp
	var mat := ShaderMaterial.new()
	mat.shader = load("res://addons/lit/shaders/lit_receiver_fast.gdshader")
	floor_spr.material = mat
	add_child(floor_spr)

	var props := Node2D.new()
	props.name = "Props"
	add_child(props)

	var wall := Node2D.new()
	wall.name = "Wall"
	wall.position = WALL_POS
	props.add_child(wall)
	var wall_spr := LitSprite2D.new()
	var wall_ct := CanvasTexture.new()
	wall_ct.diffuse_texture = white
	wall_spr.texture = wall_ct
	wall_spr.modulate = Color(0.55, 0.58, 0.7)
	wall_spr.position = Vector2(0, -110)
	wall_spr.scale = Vector2(48, 220)
	wall.add_child(wall_spr)
	var wall_occ := LightOccluder2D.new()
	var wall_poly := OccluderPolygon2D.new()
	wall_poly.polygon = PackedVector2Array([
		Vector2(-14, 0), Vector2(14, 0), Vector2(14, -200), Vector2(-14, -200)])
	wall_occ.occluder = wall_poly
	wall.add_child(wall_occ)

	_skull = Node2D.new()
	_skull.name = "Skull"
	_skull.position = Vector2(1160, 480)
	_skull.scale = Vector2(4, 4)
	props.add_child(_skull)
	var skull_spr := LitSprite2D.new()
	var ct := CanvasTexture.new()
	ct.diffuse_texture = load("res://Test/cinderskull_preview.png")
	ct.normal_texture = load("res://Test/cinderskull_preview_n.png")
	ct.specular_texture = load("res://Test/cinderskull_preview_s.png")
	skull_spr.texture = ct
	skull_spr.position = Vector2(0, -11)
	_skull.add_child(skull_spr)
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-5.2, 7.2), Vector2(6.4, 7.2), Vector2(2.8, 12.6), Vector2(-2.0, 12.6)])
	occ.occluder = poly
	occ.position = Vector2(-1.0, -0.2)
	skull_spr.add_child(occ)

	_light = LitPointLight2D.new()
	_light.position = LIGHT_POS
	_light.color = Color.WHITE
	_light.energy = 1.5
	_light.range = 1600.0
	_light.falloff = 0.6
	_light.height = 220.0
	_light.shadow_enabled = true
	_light.shadow_hardness = 0.6
	add_child(_light)

	var ui := CanvasLayer.new()
	ui.layer = 128
	add_child(ui)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hud.add_theme_constant_override("outline_size", 6)
	_hud.position = Vector2(14, 12)
	ui.add_child(_hud)

	var ysort_on := true
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"out":
				_out = kv[1]
			"skullx":
				_skull.position.x = float(kv[1])
			"skully":
				_skull.position.y = float(kv[1])
			"ysort":
				ysort_on = kv[1] != "off"
			"band":
				ProjectSettings.set_setting("lit/render/y_sort_smoothing", float(kv[1]))
			"algo":
				if ALGO_IDS.has(kv[1]):
					_light.shadow_algorithm = ALGO_IDS[kv[1]]
					_light.source_radius = 24.0
					_light.shadow_samples = 8
					_light.shadow_jitter = 0.35
					_light.shadow_hardness = 0.5
	ProjectSettings.set_setting("lit/render/y_sorting", ysort_on)

	_update_hud()
	if _out != "":
		_capture.call_deferred()


func _process(dt: float) -> void:
	var v := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if v != Vector2.ZERO:
		_skull.position += v * 300.0 * dt
		_update_hud()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_Y:
		ProjectSettings.set_setting("lit/render/y_sorting",
				not bool(ProjectSettings.get_setting("lit/render/y_sorting", false)))
		_update_hud()


func _update_hud() -> void:
	_hud.text = "arrows: move skull (%.0f, %.0f)   [Y] lit y_sorting %s   wall base y %.0f" % [
		_skull.position.x, _skull.position.y,
		"ON" if bool(ProjectSettings.get_setting("lit/render/y_sorting", false)) else "off",
		WALL_POS.y]


func _probe(img: Image, at: Vector2, half: int = 8) -> float:
	var sum := 0.0
	var n := 0
	for y in range(int(at.y) - half, int(at.y) + half):
		for x in range(int(at.x) - half, int(at.x) + half):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			sum += c.r * 0.299 + c.g * 0.587 + c.b * 0.114
			n += 1
	return sum / float(maxi(n, 1))


func _capture() -> void:
	for i in 8:
		await RenderingServer.frame_post_draw
	_hud.visible = false
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out)
	var head := _skull.position + Vector2(0.0, -64.0)
	print("YSORTTEST skull=(%.0f,%.0f) ysort=%s head_lum=%.3f floor_shadow_lum=%.3f floor_lit_lum=%.3f saved=%s" % [
		_skull.position.x, _skull.position.y,
		ProjectSettings.get_setting("lit/render/y_sorting", false),
		_probe(img, head), _probe(img, Vector2(1060, 600)), _probe(img, Vector2(700, 700)),
		_out])
	get_tree().quit()
