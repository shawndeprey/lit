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


func drive_sun(light: DirectionalLight2D) -> Dictionary:
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
	light.set_max_distance(2048.0)
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
		"max_distance": light.get_max_distance(),
	}
