@tool
extends Label
## Shows the Light's current range so inspector edits and the Cycle animation both read on screen.

@export var light: Node2D
@export var layer_mode: bool = false


func _process(_delta: float) -> void:
	if light == null:
		return
	if layer_mode:
		text = _layer_text(light.range_layer_min, light.range_layer_max)
	else:
		text = _z_text(light.range_z_min, light.range_z_max)


func _z_text(lo: int, hi: int) -> String:
	var lights := "lights every z_index"
	if lo == hi:
		lights = "lights z_index %d only" % lo
	elif lo > -4096 or hi < 4096:
		lights = "lights z_index %d to %d" % [lo, hi]
	return "range_z_min  %d\nrange_z_max  %d\n%s" % [lo, hi, lights]


func _layer_text(lo: int, hi: int) -> String:
	var lights := "lights every CanvasLayer"
	if lo == 0 and hi == 0:
		pass
	elif lo == hi:
		lights = "lights CanvasLayer %d only" % lo
	elif lo < 0 and hi == 0:
		lights = "lights the base canvas only"
	else:
		lights = "lights CanvasLayer %d to %d" % [lo, hi]
	return "range_layer_min  %d\nrange_layer_max  %d\n%s" % [lo, hi, lights]
