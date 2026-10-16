extends Node

@export var lamp: PointLight2D
var lit_lamp: LitPointLight2D


func brightest() -> float:
	var core := lamp.energy if lamp != null else 0.0
	var lit := lit_lamp.energy if lit_lamp != null else 0.0
	return maxf(core, lit)
