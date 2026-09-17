extends SceneTree

## Headless gate: LitAnimatedSprite2D pre-wiring and frame-driven specular tracking.
## The specular flag must follow the frame on screen through frame steps, animation
## switches, SpriteFrames swaps, live CanvasTexture edits, and AtlasTexture-over-
## CanvasTexture sheet frames; pooled materials must re-key per node instead of
## bleeding. Count-guarded: EXPECTED checks must execute.
## Run: godot --headless --path . --script res://Test/gate_animated_sprite.gd

const EXPECTED := 19

var _frame := 0
var _checks := 0
var _fails := 0

var _a: LitAnimatedSprite2D
var _b: LitAnimatedSprite2D
var _ct_spec: CanvasTexture        # frame 0: CanvasTexture with a specular map
var _ct_plain: CanvasTexture       # frame 1: CanvasTexture without one
var _sheet_spec: CanvasTexture     # frame 2: AtlasTexture over a specular-mapped sheet
var _frames: SpriteFrames


func _initialize() -> void:
	var mgr := root.get_node_or_null("LitManager")
	if mgr != null:
		mgr.set_process(false)

	var white := _solid(8, 8)
	_ct_spec = CanvasTexture.new()
	_ct_spec.diffuse_texture = white
	_ct_spec.specular_texture = white
	_ct_plain = CanvasTexture.new()
	_ct_plain.diffuse_texture = white
	_sheet_spec = CanvasTexture.new()
	_sheet_spec.diffuse_texture = _solid(16, 8)
	_sheet_spec.specular_texture = _solid(16, 8)
	var atlas := AtlasTexture.new()
	atlas.atlas = _sheet_spec
	atlas.region = Rect2(8, 0, 8, 8)

	_frames = SpriteFrames.new()
	_frames.add_frame(&"default", _ct_spec)
	_frames.add_frame(&"default", _ct_plain)
	_frames.add_frame(&"default", atlas)
	_frames.add_frame(&"default", white)
	_frames.add_animation(&"bare")
	_frames.add_frame(&"bare", white)

	# Pre-wire checks on a fresh, off-tree node.
	var fresh := LitAnimatedSprite2D.new()
	_check(fresh.material is ShaderMaterial \
			and LitShaderLibrary.flags_of((fresh.material as ShaderMaterial).shader) == 0,
			"fresh node carries the fast receiver material")
	_check(fresh.sprite_frames != null, "fresh node carries an empty SpriteFrames")
	_check(int((fresh.material as ShaderMaterial).get_shader_parameter("receiver_mask")) == 1,
			"proxy defaults seeded on the fresh material")
	fresh.free()

	_a = LitAnimatedSprite2D.new()
	_a.name = "A"
	_a.sprite_frames = _frames
	_b = LitAnimatedSprite2D.new()
	_b.name = "B"
	_b.sprite_frames = _frames
	_b.frame = 1
	root.add_child.call_deferred(_a)
	root.add_child.call_deferred(_b)
	process_frame.connect(_tick)


func _solid(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)


func _spec(n: LitAnimatedSprite2D) -> bool:
	return (n.material as ShaderMaterial).get_shader_parameter("has_specular_map") == true


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: " + label)


func _tick() -> void:
	_frame += 1
	var mgr := root.get_node_or_null("LitManager")
	if mgr != null:
		mgr.set_process(false)
	match _frame:
		2:
			_check(_spec(_a), "A on frame 0 (specular CanvasTexture): flag on")
			_check(not _spec(_b), "B on frame 1 (plain CanvasTexture): flag off")
			_check(_a.material != _b.material,
					"different specular state re-keyed A and B to different pool entries")
			_a.frame = 1
			_check(not _spec(_a), "A stepped to frame 1: flag off")
			_check(_a.material == _b.material,
					"identical content now shares one pooled material")
			_a.frame = 2
			_check(_spec(_a), "A on frame 2 (AtlasTexture over specular sheet): flag on")
			_a.frame = 3
			_check(not _spec(_a), "A on frame 3 (plain ImageTexture): flag off")
			# Live edit on the watched CanvasTexture: assigning a specular map must flip
			# the flag through the texture's changed signal, no frame change needed.
			_a.frame = 1
			_ct_plain.specular_texture = _solid(8, 8)
			_check(_spec(_a), "specular map assigned on the current frame's CanvasTexture: flag on")
			_ct_plain.specular_texture = null
			_check(not _spec(_a), "specular map cleared again: flag off")
			# Animation switch to a plain animation, then back.
			_a.frame = 0
			_a.animation = &"bare"
			_check(not _spec(_a), "animation switched to a plain frame set: flag off")
			_a.animation = &"default"
			_check(_spec(_a), "animation switched back to frame 0: flag on")
			# Frame edit in the SpriteFrames itself (the panel's path): replace frame 0.
			_frames.set_frame(&"default", 0, _ct_plain)
			_check(not _spec(_a), "frame 0 replaced with a plain texture: flag off")
			_frames.set_frame(&"default", 0, _ct_spec)
			_check(_spec(_a), "frame 0 restored: flag on")
			# SpriteFrames swap.
			var other := SpriteFrames.new()
			other.add_frame(&"default", _ct_plain)
			_a.sprite_frames = other
			_check(not _spec(_a), "SpriteFrames swapped for a plain set: flag off")
			_a.sprite_frames = null
			_check(not _spec(_a), "SpriteFrames cleared: flag off, no error")
		4:
			_check(_checks == EXPECTED - 1, "check count guard")
			print("PROBE RESULT: %d/%d checks, %d fails" % [_checks - _fails, _checks, _fails])
			quit(1 if _fails > 0 else 0)
