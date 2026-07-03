extends CanvasLayer
class_name RainSystem

## Stylized pixel-art rain, fully screen-space and procedural so it always
## renders regardless of camera position. Drive it all with `intensity`.

## 0.0 = clear, 1.0 = downpour
@export_range(0.0, 1.0) var intensity: float = 0.6 : set = set_intensity
## Streak lean; negative leans left. Feeds the streak shader `slant`.
@export_range(-0.6, 0.6) var wind: float = 0.18 : set = set_wind
## How fast streaks fall.
@export var fall_speed: float = 1.6
@export var lightning_enabled: bool = true
## min / max seconds between strikes (scaled by intensity)
@export var lightning_interval: Vector2 = Vector2(6.0, 18.0)

@onready var rain: ColorRect = $Screen/Rain
@onready var droplets: ColorRect = $Screen/Droplets
@onready var fog: ColorRect = $Screen/Fog
@onready var flash: ColorRect = $Screen/Flash

var _lightning_timer: float = 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	add_to_group("rain_system")
	get_viewport().size_changed.connect(_update_aspect)
	set_intensity(intensity)
	set_wind(wind)
	_update_aspect()
	_schedule_lightning()

func _update_aspect() -> void:
	if not is_inside_tree() or not is_instance_valid(rain):
		return
	var vp := get_viewport().get_visible_rect().size
	if vp.y > 0.0 and rain.material:
		rain.material.set_shader_parameter("aspect", vp.x / vp.y)

func set_wind(v: float) -> void:
	wind = v
	if is_inside_tree() and is_instance_valid(rain) and rain.material:
		rain.material.set_shader_parameter("slant", wind)

func set_intensity(v: float) -> void:
	intensity = clampf(v, 0.0, 1.0)
	if not is_inside_tree():
		return
	if is_instance_valid(rain) and rain.material:
		rain.material.set_shader_parameter("intensity", intensity)
		rain.material.set_shader_parameter("fall_speed", fall_speed)
	if is_instance_valid(droplets) and droplets.material:
		droplets.material.set_shader_parameter("intensity", intensity)
	if is_instance_valid(fog) and fog.material:
		fog.material.set_shader_parameter("intensity", intensity * 0.7)

func _process(delta: float) -> void:
	if lightning_enabled and intensity > 0.4:
		_lightning_timer -= delta
		if _lightning_timer <= 0.0:
			do_lightning()
			_schedule_lightning()
	if is_instance_valid(flash):
		var c := flash.color
		c.a = maxf(0.0, c.a - delta * 4.0)
		flash.color = c

func _schedule_lightning() -> void:
	var scale := lerpf(2.0, 0.6, intensity)
	_lightning_timer = _rng.randf_range(
		lightning_interval.x * scale, lightning_interval.y * scale)

func do_lightning() -> void:
	if not is_instance_valid(flash):
		return
	flash.color.a = _rng.randf_range(0.55, 0.9)
	var tw := create_tween()
	tw.tween_property(flash, "color:a", 0.0, 0.08)
	tw.tween_property(flash, "color:a", _rng.randf_range(0.3, 0.6), 0.05)
	tw.tween_property(flash, "color:a", 0.0, 0.22)
	lightning_struck.emit()

signal lightning_struck
