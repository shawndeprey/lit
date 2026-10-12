class_name RangeDemo extends Node2D

const COLOR_INTERVAL: float = 0.5
const NONE: int = 4096

@onready var light: LitPointLight2D = $Lights/LitSpotLight2D
@onready var pairs: Array = [[light, $Lights/FloorLight], [$Lights/LitSpotLight2D2, $Lights/FloorLight2]]
@onready var checkboxes: Array[Node] = $UILayer/UI.get_children()
@onready var fps: Label = $UILayer/Fps
var accumulator: float = 0.0

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for box in checkboxes:
		box.toggled.connect(_apply_ranges.unbind(1))
	_apply_ranges()

func _process(delta: float) -> void:
	for p in pairs: p[1].color = p[0].color
	fps.text = "FPS: %d" % Engine.get_frames_per_second()
	accumulator += delta
	if accumulator < COLOR_INTERVAL: return
	accumulator = 0.0
	for p in pairs:
		create_tween().tween_property(p[0], "color", Color.from_hsv(randf(), 1.0, 1.0), COLOR_INTERVAL)

func _apply_ranges() -> void:
	var zs: Array[int] = []
	var layers: Array[int] = []
	for box in checkboxes:
		if box.button_pressed:
			(zs if is_z(box) else layers).append(get_truthy_val(box))
	for p in pairs:
		p[0].range_z_min = zs.min() if zs else NONE
		p[0].range_z_max = zs.max() if zs else NONE
		p[0].range_layer_min = layers.min() if layers else NONE
		p[0].range_layer_max = layers.max() if layers else NONE
	for box in checkboxes:
		var v := get_truthy_val(box)
		var lo: int = light.range_z_min if is_z(box) else light.range_layer_min
		var hi: int = light.range_z_max if is_z(box) else light.range_layer_max
		box.set_pressed_no_signal(v >= lo and v <= hi)

func is_z(box: Node) -> bool: return String(box.name).begins_with("Z")
func get_truthy_val(box: Node) -> int: return int(String(box.name).substr(1 if is_z(box) else 5))
