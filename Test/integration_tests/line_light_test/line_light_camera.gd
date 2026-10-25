extends Camera2D

## Mouse wheel zooms toward the pointer: the world point under it stays put.

const STEP := 1.15

func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var factor := 0.0
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		factor = STEP
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		factor = 1.0 / STEP
	else:
		return
	var anchor := get_global_mouse_position()
	var old_zoom := zoom
	zoom = (zoom * factor).clamp(Vector2(0.1, 0.1), Vector2(16.0, 16.0))
	global_position += (anchor - global_position) * (Vector2.ONE - old_zoom / zoom)
