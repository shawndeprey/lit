@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends Node2D
class_name LitPostEffect

## Base class for one post-processing pass.
##
## Each effect is a lightweight Node2D child of a LitPostProcess chain (Node2D purely
## for the visibility contract - the `visible` property and scene-tree eye; every
## other inherited 2D property is hidden from the inspector). While the pass
## is active (this node and the host both visible, and this node parented under the
## host), the effect spawns its machinery internally: a CanvasLayer holding a
## fullscreen ColorRect with the pass shader. The layer boundary makes the pass
## re-read the accumulated screen via hint_screen_texture, and the host assigns layer
## numbers from the child order, so the chain renders in tree order: reorder the
## children to reorder the passes.
##
## While inactive, the machinery is torn down entirely - a disabled pass holds no
## canvas, so it costs the renderer nothing (an attached CanvasLayer costs render-thread
## time every frame even when hidden and empty, which is why the pass machinery is
## per-activation rather than always-alive). The ShaderMaterial is created once and
## kept across toggles, so parameters persist and re-enabling never recompiles.
## Toggle the node's `visible` (the scene-tree eye) to enable or disable the pass;
## hiding the host LitPostProcess disables the whole chain.
##
## Effects only render under a LitPostProcess parent; anywhere else the node shows a
## configuration warning and stays inert. Stateful effects can override
## _effect_process() to track data over time (the base class only enables processing
## when a subclass overrides it, and it runs only while the pass is active).
##
## Subclasses override _shader(), _rank() (default insertion slot), and _param_map()
## (shader uniform -> property name), plus _apply_extra_params() for uniforms derived
## rather than mirrored from a property. Export setters call apply_params().
##
## Custom effects: extend this class in your own script and it's a first-class pass.
## The minimum is a class_name, a _shader() override returning a canvas_item shader
## that reads the frame via a `hint_screen_texture` sampler, and _param_map() entries
## for your exported knobs (with a class_name, your effect also appears in the "Add
## Effect" menu under Custom). The "New Custom Effect..." item in that menu generates
## a working starter script + shader to build from.

var _host: LitPostProcess = null
var _mat: ShaderMaterial = null       # created on first activation, kept across toggles
var _pass_layer: CanvasLayer = null   # exists only while the pass is active
var _pass_index: int = 0              # chain position, assigned by the host


func _ready() -> void:
	_refresh()


func _process(delta: float) -> void:
	call("_effect_process", delta)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PARENTED:
			_host = get_parent() as LitPostProcess
			update_configuration_warnings()
		NOTIFICATION_UNPARENTED:
			_host = null
			update_configuration_warnings()
			_refresh()
		NOTIFICATION_ENTER_TREE:
			_refresh()
		NOTIFICATION_VISIBILITY_CHANGED:
			_refresh()


func _get_configuration_warnings() -> PackedStringArray:
	if _host == null:
		return ["This effect only renders as a child of a LitPostProcess node."]
	return []


# The Node2D base is only here for the visibility contract (`visible`, the scene-tree
# eye, visibility_changed); none of its 2D surface applies to a fullscreen pass, so
# hide everything but `visible` from the inspector. Storage usage is untouched.
const _HIDDEN_BASE_PROPS := ["position", "rotation", "scale", "skew", "transform",
	"z_index", "z_as_relative", "y_sort_enabled", "show_behind_parent", "top_level",
	"clip_children", "light_mask", "visibility_layer", "modulate", "self_modulate",
	"texture_filter", "texture_repeat", "material", "use_parent_material"]


func _validate_property(property: Dictionary) -> void:
	if property.name in _HIDDEN_BASE_PROPS:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Push the exported parameters onto the pass material: the _param_map() mirrors plus
## any derived uniforms from _apply_extra_params(). Safe to call any time; parameters
## stick to the cached material across enable/disable toggles.
func apply_params() -> void:
	if _mat == null:
		return
	var map := _param_map()
	for uniform in map:
		_mat.set_shader_parameter(uniform, get(map[uniform]))
	_apply_extra_params(_mat)


## Create or destroy the pass machinery to match the active state. Called on
## parenting, tree entry, visibility changes, and by the host when its own visibility
## flips (a CanvasLayer doesn't propagate visibility to child CanvasLayers, so the
## host fans this out).
func _refresh() -> void:
	var active := is_inside_tree() and _host != null and visible and _host.visible
	# Processing tracks activity too: a hidden stateful effect gets zero per-frame
	# callbacks, not an early-out.
	set_process(active and has_method("_effect_process"))
	if active == (_pass_layer != null):
		return
	if active:
		if _mat == null:
			_mat = ShaderMaterial.new()
			_mat.shader = _shader()
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)   # cover the viewport
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE     # never eat UI input
		rect.material = _mat
		_pass_layer = CanvasLayer.new()
		_pass_layer.layer = _layer_value()
		_pass_layer.add_child(rect)
		add_child(_pass_layer, false, Node.INTERNAL_MODE_BACK)
		apply_params()
	else:
		remove_child(_pass_layer)
		_pass_layer.free()
		_pass_layer = null


## The host's chain walk assigns each effect its position; active passes re-layer
## immediately, inactive ones apply it on their next activation.
func _set_pass_index(index: int) -> void:
	_pass_index = index
	if _pass_layer != null:
		_pass_layer.layer = _layer_value()


func _layer_value() -> int:
	return (_host.layer if _host != null else 0) + _pass_index + 1


# --- Subclass contract ---------------------------------------------------------

## The pass's canvas_item shader.
func _shader() -> Shader:
	return null


## Canonical default slot in the chain, used only when inserting via
## LitPostProcess.add_effect() or the inspector's "Add Effect" button. The actual draw
## order is the child order. Built-in passes use 10..200; the 1000 default appends
## custom effects at the end of the chain. See LitPostProcess for the pipeline
## rationale.
func _rank() -> int:
	return 1000


## shader uniform -> exported property name, applied by apply_params().
func _param_map() -> Dictionary:
	return {}


## Override for uniforms derived from properties rather than mirrored (e.g. the LUT
## pass's active texture).
func _apply_extra_params(_mat_out: ShaderMaterial) -> void:
	pass
