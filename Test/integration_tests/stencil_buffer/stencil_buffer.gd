extends Node2D

@onready var _light: LitPointLight2D = $LitPointLight2D
@onready var _camera: Camera2D = $Camera2D
@onready var _label: Label = $UI/Label

func _ready() -> void:
	_update_label()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_light.global_position = get_global_mouse_position()
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom *= 1.1
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom /= 1.1
		_update_label()
	if event is InputEventKey and event.is_pressed() and not event.is_echo() and event.keycode == KEY_S:
		_light.shadow_enabled = not _light.shadow_enabled
		_update_label()

func _update_label() -> void:
	_label.text = "Mouse: light   Wheel: zoom %.2f   S: shadows %s" % [_camera.zoom.x, "on" if _light.shadow_enabled else "off"]
