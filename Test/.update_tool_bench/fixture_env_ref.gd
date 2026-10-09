extends Node

@export var env: CanvasModulate
@export var lamp: PointLight2D
@export var sun: DirectionalLight2D
@export var env_path: NodePath
@export var any_node: Node
@export var scripted: PointLight2D
@export var lamps: Array[PointLight2D] = []
@export var by_name: Dictionary[String, PointLight2D] = {}
@export var keyed: Dictionary[CanvasModulate, int] = {}


func ambient() -> Color:
	return env.color if env != null else Color.BLACK
