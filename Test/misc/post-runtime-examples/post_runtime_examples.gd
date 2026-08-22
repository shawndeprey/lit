extends Node2D

## Wires the texture pre-pass and animates the dissolve and frost stations.

@onready var _dissolve: ShaderMaterial = $GroupDissolve/CanvasGroup.material
@onready var _frost: ShaderMaterial = $ScreenTextureFrost/Skull/Frost.material


func _ready() -> void:
	var skull: LitSprite2D = $PrePassHueShift/Skull
	(skull.texture as CanvasTexture).diffuse_texture = $PrePassHueShift/PrePass.get_texture()


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	_dissolve.set_shader_parameter("threshold", 0.5 + 0.45 * sin(t * 0.8))
	_frost.set_shader_parameter("amount", 0.5 + 0.5 * sin(t * 0.6))
