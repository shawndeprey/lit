extends Node2D

## Interactive gutcheck for the luminance API: the point light follows the mouse and
## the label reads the skull's LitSprite2D.get_luminance() live, so dragging the light
## around (and behind occluders) shows falloff and shadow occlusion in the number.
## The toggle drops the light's channel from the skull's receiver mask: the render and
## the number go dark together, and both return when the mask is restored.

@onready var _skull: LitSprite2D = $Skeleton/LitSprite2D
@onready var _light: LitPointLight2D = $Lights/LitPointLight2D
@onready var _label: Label = $UI/LuminanceLabel
@onready var _toggle: CheckButton = $UI/MaskToggle


func _ready() -> void:
	_toggle.toggled.connect(_on_mask_toggled)


func _process(_delta: float) -> void:
	_light.global_position = get_global_mouse_position()
	_label.text = "Skull luminance: %.3f" % _skull.get_luminance()


func _on_mask_toggled(ignore: bool) -> void:
	var bit := int(_light.light_mask)
	_skull.receiver_mask = (_skull.receiver_mask & ~bit) if ignore else (_skull.receiver_mask | bit)
