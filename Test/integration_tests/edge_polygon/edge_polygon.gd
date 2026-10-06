extends Node2D

@onready var _light: LitPointLight2D = $LitPointLight2D
@onready var _label: Label = $Label

func _ready() -> void:
	_update_label()

func _process(_delta: float) -> void:
	_light.global_position = get_global_mouse_position()

func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo() and event.keycode == KEY_S:
		_light.shadow_enabled = not _light.shadow_enabled
		_update_label()

func _update_label() -> void:
	_label.text = "Mouse: light   S: shadows %s" % ("on" if _light.shadow_enabled else "off")
