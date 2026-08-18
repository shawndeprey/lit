extends Node2D

## Interactive gutcheck for the luminance API: the point light follows the mouse and
## the label reads the skull's LitSprite2D.get_luminance() live, so dragging the light
## around (and behind occluders) shows falloff and shadow occlusion in the number.

@onready var _skull: LitSprite2D = $Skeleton/LitSprite2D
@onready var _light: LitPointLight2D = $Lights/LitPointLight2D
@onready var _label: Label = $UI/LuminanceLabel


func _process(_delta: float) -> void:
	_light.global_position = get_global_mouse_position()
	_label.text = "Skull luminance: %.3f" % _skull.get_luminance()
