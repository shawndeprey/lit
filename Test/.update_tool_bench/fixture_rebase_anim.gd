extends AnimatedSprite2D

@export var bob := 1.5


func bob_step(delta: float) -> void:
	position.y += bob * delta
