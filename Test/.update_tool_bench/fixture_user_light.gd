extends LitPointLight2D

@export var intensity := 1.0


func pulse() -> void:
	energy = intensity
