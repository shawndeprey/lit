extends Node

@onready var torch_light: PointLight2D = null
@onready var named_child: PointLight2D = $PointLight2D
@onready var nested_light: PointLight2D = $Props/PointLight2D
@onready var unique_light: PointLight2D = %PointLight2D

var vis_changes := 0
# A PointLight2D mention in a comment stays untouched.
var query_type := "PointLight2D"


func _on_light_vis() -> void:
	vis_changes += 1


func spawn_light() -> Node:
	return PointLight2D.new()


func is_env(node: Node) -> bool:
	return node is CanvasModulate


func sun_of(node: Node) -> DirectionalLight2D:
	return node.get_node_or_null("Sun") as DirectionalLight2D


class InnerSprite extends Sprite2D:
	pass
