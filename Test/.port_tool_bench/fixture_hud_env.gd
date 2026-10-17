extends Control

@export var env: CanvasModulate
@export var lamp: PointLight2D


func readout() -> String:
	return str(env.color) if env != null else "-"
