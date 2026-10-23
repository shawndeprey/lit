extends Node

@onready var torch_light: PointLight2D = null
@onready var named_child: PointLight2D = $PointLight2D
@onready var nested_light: PointLight2D = $Props/PointLight2D
@onready var unique_light: PointLight2D = %PointLight2D

var vis_changes := 0
# A PointLight2D mention in a comment stays untouched.
var query_type := "PointLight2D"
var preview_scene := "res://Test/.port_tool_bench/fixture_preview.tscn"


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


func drive_all(light: PointLight2D, cookie: Texture2D) -> Dictionary:
	light.set_enabled(false)
	light.set_color(Color(0.2, 0.4, 0.6))
	light.set_energy(2.5)
	light.set_height(0.75)
	light.set_blend_mode(1)
	light.set_shadow_enabled(true)
	light.set_shadow_color(Color(0.1, 0.2, 0.3, 0.4))
	light.set_item_cull_mask(5)
	light.set_item_shadow_cull_mask(6)
	light.set_z_range_min(-7)
	light.set_z_range_max(9)
	light.set_layer_range_min(-3)
	light.set_layer_range_max(4)
	light.set_texture(cookie)
	light.set_texture_offset(Vector2(3, -5))
	light.set_texture_scale(1.75)
	return {
		"enabled": light.is_enabled(),
		"color": light.get_color(),
		"energy": light.get_energy(),
		"height": light.get_height(),
		"blend_mode": light.get_blend_mode(),
		"shadow_enabled": light.is_shadow_enabled(),
		"shadow_color": light.get_shadow_color(),
		"item_cull_mask": light.get_item_cull_mask(),
		"item_shadow_cull_mask": light.get_item_shadow_cull_mask(),
		"z_range_min": light.get_z_range_min(),
		"z_range_max": light.get_z_range_max(),
		"layer_range_min": light.get_layer_range_min(),
		"layer_range_max": light.get_layer_range_max(),
		"texture": light.get_texture(),
		"texture_offset": light.get_texture_offset(),
		"texture_scale": light.get_texture_scale(),
	}
