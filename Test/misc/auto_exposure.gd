extends Node2D

## AutoExposure showcase: lights get random colors and flash in a random cascade.

@export var start_delay := 0.5
@export var cascade_window := 4.0
@export var flash_energy := 5.0
@export var flash_range := 1536.0
@export var ramp_up := 0.05
@export var ramp_down := 0.1

var _t := 0.0
var _lights: Array = []   # [light, base energy, base range, flash start time]

func _ready() -> void:
	for light in $Lights.get_children():
		light.color = Color.from_hsv(randf(), randf_range(0.6, 1.0), 1.0)
		_lights.append([light, light.energy, light.range, 0.0])
	$UI/FlashButton.pressed.connect(_start_cascade)
	_start_cascade()

func _start_cascade() -> void:
	for entry in _lights:
		entry[3] = _t + start_delay + randf() * cascade_window

func _process(delta: float) -> void:
	_t += delta
	for entry in _lights:
		var light: Node2D = entry[0]
		var start: float = entry[3]
		var phase := 0.0
		if _t > start and _t < start + ramp_up:
			phase = (_t - start) / ramp_up
		elif _t >= start + ramp_up and _t < start + ramp_up + ramp_down:
			phase = 1.0 - (_t - start - ramp_up) / ramp_down
		var energy: float = lerpf(entry[1], flash_energy, phase)
		var light_range: float = lerpf(entry[2], flash_range, phase)
		if light.energy != energy:
			light.energy = energy
		if light.range != light_range:
			light.range = light_range
