extends Node2D

const KEYS := {
	KEY_A: Vector2.LEFT, KEY_LEFT: Vector2.LEFT,
	KEY_D: Vector2.RIGHT, KEY_RIGHT: Vector2.RIGHT,
	KEY_W: Vector2.UP, KEY_UP: Vector2.UP,
	KEY_S: Vector2.DOWN, KEY_DOWN: Vector2.DOWN,
}

@export var speed := 40.0

func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	for key in KEYS:
		if Input.is_physical_key_pressed(key):
			dir += KEYS[key]
	position += dir.limit_length() * speed * delta
