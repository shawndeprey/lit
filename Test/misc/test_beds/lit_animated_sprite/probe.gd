extends SceneTree

## Probe for the LitAnimatedSprite2D assessment: does an AnimatedSprite2D carrying the
## Lit receiver material honor CanvasTexture normal maps the same way Sprite2D does,
## for the two frame shapes SpriteFrames actually produces?
##   A. plain ImageTexture frame               (no normal map: mid brightness)
##   B. CanvasTexture frame, normal facing LEFT  (toward the light: bright)
##   C. CanvasTexture frame, normal facing RIGHT (away from the light: dark)
##   D. AtlasTexture frame whose `atlas` is a CanvasTexture sheet, region = the
##      RIGHT-facing half                       (must match C)
##   E. CanvasTexture frame whose diffuse and normal are AtlasTextures into sheets
##      (the "wrap each frame" shape), right-facing half (must match C)
## Every shape also gets a Sprite2D twin at the identical position, captured on a
## second frame with the AnimatedSprite2D row hidden, so each AnimatedSprite2D must
## match its twin exactly (same texture, material, and light geometry).
## One white LitPointLight2D sits far to the left of every sprite. Prints the mean
## colour at each sprite's center for both rows and PASS/FAIL, saves both PNGs next
## to this file.
## Run (windowed, Forward+):
##   /Applications/Godot.app/Contents/MacOS/Godot --path . \
##       --script res://Test/misc/test_beds/lit_animated_sprite/probe.gd

const SIZE := 96
const OUT_ANIM := "res://Test/misc/test_beds/lit_animated_sprite/probe_out_animated.png"
const OUT_TWIN := "res://Test/misc/test_beds/lit_animated_sprite/probe_out_sprite2d.png"

var _frame := 0
var _nodes := {}   # label -> AnimatedSprite2D
var _twins := {}   # label -> Sprite2D at the same position
var _root2d: Node2D


func _initialize() -> void:
	_root2d = Node2D.new()
	root.add_child.call_deferred(_root2d)
	_build.call_deferred()
	process_frame.connect(_tick)


func _solid(w: int, h: int, c: Color) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


# Normal-map colour for a unit normal (Godot 2D: R = +X right, G = +Y up, B = +Z).
func _ncol(nx: float) -> Color:
	var n := Vector3(nx, 0.0, 1.0).normalized()
	return Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5)


func _diffuse_sheet() -> ImageTexture:
	var img := Image.create(SIZE * 2, SIZE, false, Image.FORMAT_RGBA8)
	img.fill_rect(Rect2i(0, 0, SIZE, SIZE), Color(1.0, 0.3, 0.3))
	img.fill_rect(Rect2i(SIZE, 0, SIZE, SIZE), Color.WHITE)
	return ImageTexture.create_from_image(img)


# Two-frame sheet: left half faces LEFT, right half faces RIGHT.
func _normal_sheet() -> ImageTexture:
	var img := Image.create(SIZE * 2, SIZE, false, Image.FORMAT_RGBA8)
	img.fill_rect(Rect2i(0, 0, SIZE, SIZE), _ncol(-1.0))
	img.fill_rect(Rect2i(SIZE, 0, SIZE, SIZE), _ncol(1.0))
	return ImageTexture.create_from_image(img)


func _receiver_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
	return mat


func _anim(label: String, tex: Texture2D, pos: Vector2) -> AnimatedSprite2D:
	var sf := SpriteFrames.new()
	sf.add_frame("default", tex)
	var a := AnimatedSprite2D.new()
	a.name = label
	a.sprite_frames = sf
	a.material = _receiver_material()
	a.position = pos
	_root2d.add_child(a)
	_nodes[label] = a
	var t := Sprite2D.new()
	t.name = label + "_twin"
	t.texture = tex
	t.material = _receiver_material()
	t.position = pos
	t.visible = false
	_root2d.add_child(t)
	_twins[label] = t
	return a


func _build() -> void:
	var vp := root.get_visible_rect().size
	var cm := LitCanvasModulate.new()
	cm.color = Color(0.02, 0.02, 0.02)
	_root2d.add_child(cm)

	var white := _solid(SIZE, SIZE, Color.WHITE)
	# Left half red-tinted, right half white: a frame that samples the wrong half of the
	# sheet betrays itself in the green/blue channels, not just in the normal.
	var white_sheet := _diffuse_sheet()
	var n_left := _solid(SIZE, SIZE, _ncol(-1.0))
	var n_right := _solid(SIZE, SIZE, _ncol(1.0))
	var n_sheet := _normal_sheet()

	var ct_left := CanvasTexture.new()
	ct_left.diffuse_texture = white
	ct_left.normal_texture = n_left
	var ct_right := CanvasTexture.new()
	ct_right.diffuse_texture = white
	ct_right.normal_texture = n_right

	# D: AtlasTexture over a CanvasTexture sheet.
	var ct_sheet := CanvasTexture.new()
	ct_sheet.diffuse_texture = white_sheet
	ct_sheet.normal_texture = n_sheet
	var at_over_ct := AtlasTexture.new()
	at_over_ct.atlas = ct_sheet
	at_over_ct.region = Rect2(SIZE, 0, SIZE, SIZE)

	# E: CanvasTexture whose slots are AtlasTextures into the sheets.
	var at_diff := AtlasTexture.new()
	at_diff.atlas = white_sheet
	at_diff.region = Rect2(SIZE, 0, SIZE, SIZE)
	var at_norm := AtlasTexture.new()
	at_norm.atlas = n_sheet
	at_norm.region = Rect2(SIZE, 0, SIZE, SIZE)
	var ct_of_atlases := CanvasTexture.new()
	ct_of_atlases.diffuse_texture = at_diff
	ct_of_atlases.normal_texture = at_norm

	var y := vp.y * 0.5
	var x0 := vp.x * 0.45
	var step := float(SIZE) * 1.6
	_anim("A_plain", white, Vector2(x0, y))
	_anim("B_ct_left", ct_left, Vector2(x0 + step, y))
	_anim("C_ct_right", ct_right, Vector2(x0 + step * 2, y))
	_anim("D_atlas_over_ct", at_over_ct, Vector2(x0 + step * 3, y))
	_anim("E_ct_of_atlases", ct_of_atlases, Vector2(x0 + step * 4, y))

	var light := LitPointLight2D.new()
	light.position = Vector2(vp.x * 0.05, y)
	light.color = Color.WHITE
	light.energy = 1.0
	light.range = 4000.0
	light.falloff = 0.0
	light.height = 500.0
	_root2d.add_child(light)


func _tick() -> void:
	_frame += 1
	if _frame < 12:
		return
	if _frame == 12:
		_capture.call_deferred()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var anim_vals := _sample(root.get_texture().get_image(), _nodes, OUT_ANIM)
	for label in _nodes:
		_nodes[label].visible = false
		_twins[label].visible = true
	for i in 3:
		await RenderingServer.frame_post_draw
	var twin_vals := _sample(root.get_texture().get_image(), _twins, OUT_TWIN)
	var keys := anim_vals.keys()
	keys.sort()
	for k in keys:
		var v: Color = anim_vals[k]
		var t: Color = twin_vals[k]
		print("PROBE %-18s anim r=%.3f g=%.3f b=%.3f | sprite2d twin r=%.3f g=%.3f b=%.3f"
				% [k, v.r, v.g, v.b, t.r, t.g, t.b])
	var a: float = anim_vals["A_plain"].r
	var b: float = anim_vals["B_ct_left"].r
	var c: float = anim_vals["C_ct_right"].r
	var d: Color = anim_vals["D_atlas_over_ct"]
	var e: Color = anim_vals["E_ct_of_atlases"]
	var fails := 0
	fails += _expect(b > a * 1.5, "B (normal toward light) brighter than A (flat)")
	fails += _expect(c < a * 0.6, "C (normal away) darker than A (flat)")
	fails += _expect(absf(d.r - c) < 0.03, "D (AtlasTexture over CanvasTexture sheet): normal region honored (matches C)")
	fails += _expect(d.g > d.r * 0.9, "D: diffuse region honored (white half, not the red half)")
	for k in keys:
		var v: Color = anim_vals[k]
		var t: Color = twin_vals[k]
		fails += _expect(absf(v.r - t.r) < 0.02 and absf(v.g - t.g) < 0.02 and absf(v.b - t.b) < 0.02,
				"%s: AnimatedSprite2D matches its Sprite2D twin" % k)
	# Documenting the engine limitation rather than asserting it away: report which
	# half E actually sampled.
	var e_region_ok := absf(e.r - c) < 0.03 and e.g > e.r * 0.9
	print("  note: E (CanvasTexture whose slots are AtlasTextures) %s" % (
			"honors the atlas region" if e_region_ok
			else "IGNORES the atlas region (renders the sheet's top-left) - on Sprite2D too"))
	print("PROBE RESULT: %s (%d fails), pngs=%s %s" % ["PASS" if fails == 0 else "FAIL", fails,
			OUT_ANIM, OUT_TWIN])
	quit(1 if fails > 0 else 0)


func _sample(img: Image, nodes: Dictionary, out_path: String) -> Dictionary:
	img.save_png(out_path)
	var vals := {}
	var win := root.get_visible_rect().size
	var sx := float(img.get_width()) / win.x
	var sy := float(img.get_height()) / win.y
	for label in nodes:
		var n: Node2D = nodes[label]
		var cpos := Vector2(n.global_position.x * sx, n.global_position.y * sy)
		var acc := Color(0, 0, 0, 0)
		var cnt := 0
		for dy in range(-6, 7):
			for dx in range(-6, 7):
				acc += img.get_pixel(int(cpos.x) + dx, int(cpos.y) + dy)
				cnt += 1
		vals[label] = acc / cnt
	return vals


func _expect(ok: bool, label: String) -> int:
	print("  %s: %s" % ["ok  " if ok else "FAIL", label])
	return 0 if ok else 1
