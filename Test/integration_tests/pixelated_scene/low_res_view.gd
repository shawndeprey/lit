extends CanvasLayer

@export var target: Node2D

@onready var _world: SubViewport = $World/SubViewport
@onready var _player: SubViewport = $Player/SubViewport

func _ready() -> void:
	show()
	_world.world_2d = get_viewport().world_2d
	_player.world_2d = get_viewport().world_2d
	get_viewport().canvas_cull_mask = 1

func _process(_delta: float) -> void:
	var root := get_viewport()
	var screen := root.get_visible_rect().size
	var center := (Vector2(_world.size) / 2.0).floor()
	var cell := target.position.floor()
	_world.canvas_transform = Transform2D(0.0, center - cell)
	_player.canvas_transform = Transform2D(0.0, center - target.position.round())
	root.canvas_transform = _world.canvas_transform.scaled(screen / Vector2(_world.size))
	$Player.position = screen / 2.0 - center * $Player.scale
	$World.position = $Player.position - (target.position - cell) * $World.scale
