extends Sprite2D

@export var speed := 2.5


func spin(delta: float) -> void:
	rotation += speed * delta
