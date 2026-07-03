extends Area2D
class_name RainZone

## Place under roofs / indoors. When a body in the "player" group enters,
## global rain intensity is smoothly scaled by `shelter_amount`.
## 0.0 = fully dry under here, 1.0 = no effect.
@export_range(0.0, 1.0) var shelter_amount: float = 0.0
@export var fade_time: float = 0.5

var _rain: RainSystem
var _prev_intensity: float = -1.0

func _ready() -> void:
	_rain = get_tree().get_first_node_in_group("rain_system") as RainSystem
	body_entered.connect(_on_enter)
	body_exited.connect(_on_exit)

func _on_enter(body: Node) -> void:
	if _rain == null or not body.is_in_group("player"):
		return
	_prev_intensity = _rain.intensity
	var target := _rain.intensity * shelter_amount
	var tw := create_tween()
	tw.tween_method(_rain.set_intensity, _rain.intensity, target, fade_time)

func _on_exit(body: Node) -> void:
	if _rain == null or _prev_intensity < 0.0 or not body.is_in_group("player"):
		return
	var tw := create_tween()
	tw.tween_method(_rain.set_intensity, _rain.intensity, _prev_intensity, fade_time)
	_prev_intensity = -1.0
