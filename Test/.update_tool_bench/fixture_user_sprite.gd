extends Sprite2D

@export var speed := 1.0


func _process(delta: float) -> void:
	position.x += speed * delta
