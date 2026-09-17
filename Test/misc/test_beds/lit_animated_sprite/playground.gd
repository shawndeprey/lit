extends Node2D

## LitAnimatedSprite2D playground: a normal-mapped skeleton turning in place on a lit
## crypt floor, with a warm key light circling it so the shading sweeps around the
## turnaround as it plays. Select the Skeleton node in the editor to poke at its Lit
## exports and its SpriteFrames; the keys listed on screen drive the rest at runtime.
##
## `-- capture=PATH` saves one frame to PATH and quits (used to eyeball the scene from
## the command line).

@onready var _sprite: LitAnimatedSprite2D = $Skeleton
@onready var _key: LitPointLight2D = $Lights/KeyLight
@onready var _mouse: LitPointLight2D = $Lights/MouseLight
@onready var _camera: Camera2D = $Camera2D
@onready var _help: Label = $UI/Help

# The key light circles the skeleton on a flattened ring so it reads as walking around
# it on the floor; its `height` keeps it at head height the whole way.
const ORBIT_RADIUS := 260.0
const ORBIT_SECONDS := 6.0
# Rate for spinning the node itself (R), separate from the turnaround animation.
const NODE_SPIN_RATE := 0.8
const SPEED_STEPS := [0.25, 0.5, 1.0, 2.0, 4.0]

var _orbit := true
var _spin_node := false
var _speed_idx := 2
var _t := 0.0
var _capture := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("capture="):
			_capture = arg.substr(8)
	_mouse.enabled = false
	_sprite.speed_scale = SPEED_STEPS[_speed_idx]
	if _capture != "":
		_capture_and_quit()


func _process(delta: float) -> void:
	if _capture == "":
		_t += delta
	if _orbit:
		var a := _t * TAU / ORBIT_SECONDS
		_key.global_position = _sprite.global_position \
				+ Vector2(cos(a) * ORBIT_RADIUS, sin(a) * ORBIT_RADIUS * 0.55)
	if _spin_node:
		_sprite.rotation += NODE_SPIN_RATE * delta
	if _mouse.enabled:
		_mouse.global_position = get_global_mouse_position()
	_refresh_help()
	queue_redraw()


func _draw() -> void:
	draw_circle(to_local(_key.global_position), 5.0, Color(1.0, 0.85, 0.4))
	if _mouse.enabled:
		draw_circle(to_local(_mouse.global_position), 5.0, Color.YELLOW)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom *= 1.1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom /= 1.1
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var frames := _frame_count()
	match event.keycode:
		KEY_SPACE:
			if _sprite.is_playing():
				_sprite.pause()
			else:
				_sprite.play()
		KEY_LEFT, KEY_RIGHT:
			# Step one frame at a time (pauses so the step sticks).
			_sprite.pause()
			if frames > 0:
				var step := 1 if event.keycode == KEY_RIGHT else -1
				_sprite.frame = wrapi(_sprite.frame + step, 0, frames)
		KEY_UP, KEY_DOWN:
			_speed_idx = clampi(_speed_idx + (1 if event.keycode == KEY_UP else -1), 0, SPEED_STEPS.size() - 1)
			_sprite.speed_scale = SPEED_STEPS[_speed_idx]
		KEY_O:
			_orbit = not _orbit
		KEY_M:
			_mouse.enabled = not _mouse.enabled
		KEY_R:
			_spin_node = not _spin_node
			if not _spin_node:
				_sprite.rotation = 0.0
		KEY_F:
			_sprite.flip_h = not _sprite.flip_h
		KEY_H:
			_help.visible = not _help.visible


func _frame_count() -> int:
	if _sprite.sprite_frames == null or not _sprite.sprite_frames.has_animation(_sprite.animation):
		return 0
	return _sprite.sprite_frames.get_frame_count(_sprite.animation)


func _refresh_help() -> void:
	if not _help.visible:
		return
	var state := "playing" if _sprite.is_playing() else "paused"
	_help.text = "\n".join([
		"LitAnimatedSprite2D playground",
		"",
		"Space    play / pause  (%s)" % state,
		"Left/Right  step one frame  (frame %d / %d)" % [_sprite.frame, _frame_count()],
		"Up/Down  animation speed  (x%s)" % String.num(_sprite.speed_scale, 2),
		"O        key light circles the skeleton  [%s]" % _onoff(_orbit),
		"M        white light follows the mouse  [%s]" % _onoff(_mouse.enabled),
		"R        spin the node itself  [%s]" % _onoff(_spin_node),
		"F        flip_h  [%s]" % _onoff(_sprite.flip_h),
		"Wheel    zoom",
		"H        hide this",
	])


func _onoff(v: bool) -> String:
	return "on" if v else "off"


func _capture_and_quit() -> void:
	# A dozen frames: enough for the receiver shaders to compile and the light data to
	# settle before the grab.
	for i in 12:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_capture)
	print("PLAYGROUND CAPTURE ", "ok " if err == OK else "failed %d " % err, _capture)
	get_tree().quit()
