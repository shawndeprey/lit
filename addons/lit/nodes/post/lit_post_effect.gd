@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends CanvasLayer
class_name LitPostEffect

## Base class for one post-processing pass.
##
## Each effect is a CanvasLayer child of a LitPostProcess chain. The layer boundary
## makes the pass re-read the accumulated screen via hint_screen_texture, and the host
## assigns `layer` so the chain renders in its canonical order regardless of child
## order. The effect owns its fullscreen ColorRect and ShaderMaterial and pushes its
## exported parameters to the material when they change. Toggle the node's `visible`
## (the scene-tree eye) to enable or disable the pass; hiding the host LitPostProcess
## disables the whole chain.
##
## Effects only render under a LitPostProcess parent; anywhere else the node shows a
## configuration warning and stays inert. Stateful effects can override
## _effect_process() to track data over time (the base class only enables processing
## when a subclass overrides it).
##
## Subclasses override _shader(), _rank() (canonical chain position), and _param_map()
## (shader uniform -> property name), plus _apply_extra_params() for uniforms derived
## rather than mirrored from a property. Export setters call apply_params().

var _host: LitPostProcess = null
var _rect: ColorRect = null
var _mat: ShaderMaterial = null


func _init() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = _shader()
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)   # cover the viewport
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE     # never eat UI input
	_rect.material = _mat
	_rect.visible = false                                # inert until parented to a host
	add_child(_rect, false, Node.INTERNAL_MODE_BACK)


func _ready() -> void:
	apply_params()
	_sync_host_visibility()
	set_process(has_method("_effect_process"))


func _process(delta: float) -> void:
	if _host != null:
		call("_effect_process", delta)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PARENTED:
			_host = get_parent() as LitPostProcess
			_sync_host_visibility()
			update_configuration_warnings()
		NOTIFICATION_UNPARENTED:
			_host = null
			_sync_host_visibility()
			update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	if _host == null:
		return ["This effect only renders as a child of a LitPostProcess node."]
	return []


func _validate_property(property: Dictionary) -> void:
	# The host assigns `layer` from the canonical chain order; hide it.
	if property.name == "layer":
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Push the exported parameters onto the pass material: the _param_map() mirrors plus
## any derived uniforms from _apply_extra_params().
func apply_params() -> void:
	if _mat == null:
		return
	var map := _param_map()
	for uniform in map:
		_mat.set_shader_parameter(uniform, get(map[uniform]))
	_apply_extra_params(_mat)


## The pass rect lives under this child CanvasLayer, which doesn't inherit the host
## layer's visibility, so the host's visibility is mirrored onto the rect. Both
## switches must be on: the host's `visible` and this effect's own `visible`.
func _sync_host_visibility() -> void:
	if _rect != null:
		_rect.visible = _host != null and _host.visible


# --- Subclass contract ---------------------------------------------------------

## The pass's canvas_item shader.
func _shader() -> Shader:
	return null


## Canonical position in the chain; the host sorts passes by this, ties keep child
## order. See LitPostProcess for the pipeline rationale.
func _rank() -> int:
	return 0


## shader uniform -> exported property name, applied by apply_params().
func _param_map() -> Dictionary:
	return {}


## Override for uniforms derived from properties rather than mirrored (e.g. the LUT
## pass's active texture).
func _apply_extra_params(_mat_out: ShaderMaterial) -> void:
	pass
