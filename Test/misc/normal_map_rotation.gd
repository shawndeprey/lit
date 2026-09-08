extends Node2D

## Normal-map rotation check: every dome shares one hemisphere normal map under a fixed
## directional light, so each copy should shade identically (lit side toward the light)
## however its node is rotated or mirrored; only the red notch (texture-up) should turn.
## The spinning skull should keep its lit side toward the light like the static one.
## Toggle the mouse-driven point light to probe any direction. `-- capture=PATH` saves
## one deterministic frame (spinners pinned at 180 degrees) and quits; `camrot=DEG`
## rotates the camera so the whole scene turns on screen with the light.

@onready var _spinner: LitSprite2D = $Rows/Spinner
@onready var _skull: Node2D = $Skulls/Spinning
@onready var _point: LitPointLight2D = $Lights/LitPointLight2D
@onready var _directional: LitDirectionalLight2D = $Lights/LitDirectionalLight2D
@onready var _toggle: CheckButton = $UI/MouseLightToggle
@onready var _camera: Camera2D = $Camera2D

const SPIN_RATE := 0.6

var _t := 0.0
var _capture := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("capture="):
			_capture = arg.substr(8)
		elif arg.begins_with("camrot="):
			_camera.ignore_rotation = false
			_camera.rotation_degrees = float(arg.substr(7))
	_toggle.toggled.connect(_on_toggle)
	_on_toggle(false)
	if _capture != "":
		_t = PI / SPIN_RATE
		_capture_and_quit()


func _process(delta: float) -> void:
	if _capture == "":
		_t += delta
	_spinner.rotation = _t * SPIN_RATE
	_skull.rotation = _spinner.rotation
	if _point.enabled:
		_point.global_position = get_global_mouse_position()
	queue_redraw()


func _draw() -> void:
	if _point.enabled:
		draw_circle(to_local(_point.global_position), 6.0, Color.YELLOW)


func _on_toggle(mouse_light: bool) -> void:
	_point.enabled = mouse_light
	_directional.enabled = not mouse_light


func _capture_and_quit() -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_capture)
	print("NMR capture=%s" % _capture)
	get_tree().quit()
