extends Node2D

## Functional shadow-algorithm test bed: the cinderskull with its occluder, one white
## point light to its left, a plain floor receiver. One knob at a time, so algorithm
## behavior is actually visible and comparable.
##
## Manual use: run the scene (F6) and press 1 (Raymarched), 2 (Cone Traced),
## 3 (Stochastic); [ / ] adjust source radius, - / = adjust samples. The HUD shows the
## current settings.
##
## Automated use (screenshots), after "--" on the CLI:
##   algo=raymarch|cone|stochastic   out=PATH (capture one frame, then quit)
##   radius=N   samples=N   jitter=X   hardness=X

const ALGO_IDS := {"raymarch": 0, "cone": 1, "stochastic": 2}
const ALGO_NAMES := ["raymarch", "cone", "stochastic"]

# Launch-time settings, editable on the scene's root node in the inspector. CLI args
# (after "--") override them, so automation keeps working. Future launch-time toggles
# for this test bed belong in this group.
@export_group("Launch Options")
## Shadow algorithm the scene starts on; keys 1/2/3 still switch live.
@export var shadow_algorithm: LitPointLight2D.ShadowAlgorithm = LitPointLight2D.ShadowAlgorithm.RAYMARCHED
## Source disc radius the light starts with (cone/stochastic).
@export_range(0.0, 256.0, 0.5, "or_greater") var source_radius: float = 32.0
## Sample count the light starts with (stochastic).
@export_range(1, 32) var shadow_samples: int = 8
## Jitter the light starts with (stochastic).
@export_range(0.0, 1.0) var shadow_jitter: float = 1.0
## Hardness the light starts with (raymarched: softness; others: contrast).
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5

var _light: LitPointLight2D
var _hud: Label
var _out := ""


func _ready() -> void:
	var vp := get_viewport_rect().size

	var canvas_modulate := LitCanvasModulate.new()
	canvas_modulate.color = Color(0.06, 0.06, 0.07)
	add_child(canvas_modulate)

	# Floor: full-screen neutral receiver the shadow falls on.
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

	# The skull, set up like the Test scene's Skeleton: LitSprite2D at 5x scale with
	# diffuse/normal/specular and the small base occluder that casts its shadow.
	var skull := LitSprite2D.new()
	var ct := CanvasTexture.new()
	ct.diffuse_texture = load("res://Test/cinderskull_preview.png")
	ct.normal_texture = load("res://Test/cinderskull_preview_n.png")
	ct.specular_texture = load("res://Test/cinderskull_preview_s.png")
	skull.texture = ct
	skull.position = Vector2(vp.x * 0.62, vp.y * 0.5)
	skull.scale = Vector2(5, 5)
	add_child(skull)

	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-5.2, 7.2), Vector2(6.4, 7.2), Vector2(2.8, 12.6), Vector2(-2.0, 12.6)])
	occ.occluder = poly
	occ.position = Vector2(-1.0, -0.2)
	skull.add_child(occ)

	# The one light: white, to the left of the skull.
	_light = LitPointLight2D.new()
	_light.position = Vector2(vp.x * 0.25, vp.y * 0.5)
	_light.color = Color.WHITE
	_light.energy = 1.5
	_light.range = 1200.0
	_light.falloff = 0.6
	# High enough that the flat (un-normal-mapped) floor stays visibly lit across the
	# whole scene; the shadow march is screen-space, so height only affects shading.
	_light.height = 220.0
	_light.shadow_enabled = true
	_light.shadow_algorithm = shadow_algorithm
	_light.source_radius = source_radius
	_light.shadow_samples = shadow_samples
	_light.shadow_jitter = shadow_jitter
	_light.shadow_hardness = shadow_hardness
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

	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"algo":
				if ALGO_IDS.has(kv[1]):
					_light.shadow_algorithm = ALGO_IDS[kv[1]]
			"out":
				_out = kv[1]
			"radius":
				_light.source_radius = float(kv[1])
			"samples":
				_light.shadow_samples = int(kv[1])
			"jitter":
				_light.shadow_jitter = float(kv[1])
			"hardness":
				_light.shadow_hardness = float(kv[1])

	_update_hud()
	if _out != "":
		_capture.call_deferred()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1:
			_light.shadow_algorithm = LitPointLight2D.ShadowAlgorithm.RAYMARCHED
		KEY_2:
			_light.shadow_algorithm = LitPointLight2D.ShadowAlgorithm.CONE_TRACED
		KEY_3:
			_light.shadow_algorithm = LitPointLight2D.ShadowAlgorithm.STOCHASTIC
		KEY_BRACKETLEFT:
			_light.source_radius = maxf(_light.source_radius - 8.0, 0.0)
		KEY_BRACKETRIGHT:
			_light.source_radius += 8.0
		KEY_MINUS:
			_light.shadow_samples = maxi(_light.shadow_samples - 4, 1)
		KEY_EQUAL:
			_light.shadow_samples = mini(_light.shadow_samples + 4, 32)
		_:
			return
	_update_hud()


func _update_hud() -> void:
	_hud.text = "[1/2/3] algo %s   [ ] source_radius %.0f   -/= samples %d   hardness %.2f" % [
		ALGO_NAMES[_light.shadow_algorithm], _light.source_radius,
		_light.shadow_samples, _light.shadow_hardness]


func _capture() -> void:
	# Several frames so the registry's receiver-variant swap lands before the capture.
	for i in 5:
		await RenderingServer.frame_post_draw
	_hud.visible = false
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out)
	print("FUNCTEST algo=%s radius=%.1f samples=%d saved=%s" % [
		ALGO_NAMES[_light.shadow_algorithm], _light.source_radius,
		_light.shadow_samples, _out])
	get_tree().quit()
