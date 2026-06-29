@tool
@icon("res://addons/lit/icons/lit_post_process.svg")
extends CanvasLayer
class_name LitTintBeams

## Drives the volumetric colour-beam pass (Tier 2 of the stained-glass effect).
##
## A fullscreen ColorRect with lit_post_beams.gdshader, plus the per-frame job of telling
## that shader where the lights are. Post shaders can't read the packed light-data texture,
## so this node gathers the lit_lights group, converts each light to screen-UV, and pushes a
## compact array (position/direction, colour*energy, type) as uniforms.
##
## Placement: put this ABOVE your Lit receivers (so it reads the lit frame via
## hint_screen_texture) and below your UI — same rule as LitPostProcess. If you also run a
## LitPostProcess chain, place this before it so beams are part of the image the chain then
## grades/blooms. Requires a LitTintBuffer in the scene to supply the tint buffer.

const BEAM_SHADER := preload("res://addons/lit/shaders/lit_post_beams.gdshader")
const MAX_BEAM_LIGHTS := 8

@export var enabled: bool = true:
	set(value):
		enabled = value
		_rebuild()

@export_group("Beams")
## Brightness of the shafts added onto the frame.
@export_range(0.0, 4.0, 0.01, "or_greater") var intensity: float = 0.6:
	set(value):
		intensity = value
		_apply_params()
## March steps per pixel toward each light. Higher = smoother, costlier.
@export_range(4, 96) var steps: int = 32:
	set(value):
		steps = value
		_apply_params()
## How far directional beams reach across the screen, in screen widths.
@export_range(0.1, 2.0, 0.01) var directional_reach: float = 1.0:
	set(value):
		directional_reach = value
		_apply_params()
## Tint-buffer density below this adds no glow (kills faint haze).
@export_range(0.0, 0.5, 0.005) var density_threshold: float = 0.02:
	set(value):
		density_threshold = value
		_apply_params()
## How saturated the shafts are. 1 = full glass hue; lower reads as pale, airy light.
@export_range(0.0, 1.0, 0.01) var saturation: float = 0.6:
	set(value):
		saturation = value
		_apply_params()

var _material: ShaderMaterial
var _rect: ColorRect
var _built := false


func _ready() -> void:
	_rebuild()


func _process(_delta: float) -> void:
	if not enabled or _material == null:
		return
	_push_lights()


func _rebuild() -> void:
	# Tear down any existing pass, then build a fresh fullscreen ColorRect if enabled.
	if _rect != null and is_instance_valid(_rect):
		_rect.queue_free()
	_rect = null
	_material = null
	_built = false

	if not enabled:
		return

	_material = ShaderMaterial.new()
	_material.shader = BEAM_SHADER

	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.material = _material
	add_child(_rect, false, Node.INTERNAL_MODE_BACK)

	_built = true
	_apply_params()


func _apply_params() -> void:
	if _material == null:
		return
	_material.set_shader_parameter("beam_intensity", intensity)
	_material.set_shader_parameter("beam_steps", steps)
	_material.set_shader_parameter("beam_directional_reach", directional_reach)
	_material.set_shader_parameter("beam_density_threshold", density_threshold)
	_material.set_shader_parameter("beam_saturation", saturation)


## Gather up to MAX_BEAM_LIGHTS lights, convert to screen-UV, and push to the shader.
func _push_lights() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var vp_size: Vector2 = vp.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return
	var canvas_xform := vp.get_global_canvas_transform() * vp.get_canvas_transform()

	var uvs: Array = []
	var colors: Array = []
	var types: Array = []

	for node in get_tree().get_nodes_in_group("lit_lights"):
		if uvs.size() >= MAX_BEAM_LIGHTS:
			break
		if not is_instance_valid(node) or not node.enabled or not node.is_visible_in_tree():
			continue

		if node is LitDirectionalLight2D:
			# A directional's incoming direction is its local +X (see the node docs). Convert
			# the world direction into screen space and store as a unit vector; the shader
			# marches along it. Colour premultiplied by energy.
			var dir_light := node as LitDirectionalLight2D
			var world_dir: Vector2 = dir_light.global_transform.x.normalized()
			var screen_dir: Vector2 = canvas_xform.basis_xform(world_dir).normalized()
			uvs.append(screen_dir)
			colors.append(Vector3(dir_light.color.r, dir_light.color.g, dir_light.color.b) * dir_light.energy)
			types.append(1)
		elif node is LitPointLight2D or node is LitSpotLight2D:
			# Point and spot share no common typed subclass beyond Node2D, but both expose
			# color/energy/global_position. Read position off the Node2D cast and pull
			# color/energy dynamically so one branch covers both.
			var pos_light := node as Node2D
			var screen_px: Vector2 = canvas_xform * pos_light.global_position
			uvs.append(screen_px / vp_size)
			var col: Color = pos_light.get("color")
			var en: float = pos_light.get("energy")
			colors.append(Vector3(col.r, col.g, col.b) * en)
			types.append(0)

	var count := uvs.size()
	# Pad to fixed array length; the shader only reads [0, count).
	while uvs.size() < MAX_BEAM_LIGHTS:
		uvs.append(Vector2.ZERO)
		colors.append(Vector3.ZERO)
		types.append(0)

	_material.set_shader_parameter("beam_light_count", count)
	_material.set_shader_parameter("beam_light_uv", uvs)
	_material.set_shader_parameter("beam_light_color", colors)
	_material.set_shader_parameter("beam_light_type", types)
