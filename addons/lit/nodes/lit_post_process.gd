@tool
extends CanvasLayer
class_name LitPostProcess

## Post-processing chain (plan §7.5, D8).
##
## A CanvasLayer that builds an ordered chain of fullscreen passes as its INTERNAL
## children — one child CanvasLayer per enabled pass, each holding a fullscreen
## ColorRect with that pass's shader, reading the frame via hint_screen_texture.
##
## Chaining WITHOUT BackBufferCopy (deviation from plan D8, same result): sampling
## hint_screen_texture reads the screen as drawn so far, and the per-pass CanvasLayer
## boundary forces each pass to re-read the accumulated result, so passes compose in
## order. The generated children are internal (not saved to the scene) and rebuilt
## from the enabled-pass toggles.
##
## Placement: set this node's `layer` ABOVE your Lit receivers and BELOW your UI /
## menus (e.g. 99 in a project that reserves high layers for post). Pass child-layers
## increment from this node's `layer`, so wherever you park it, passes stay above it
## and in order.
##
## Phase 5(a)/(b): Color Grade, Threshold, Vignette. Bloom arrives in 5(c).
##
## Passes run in a fixed canonical order regardless of inspector order:
## threshold -> grade -> vignette (bloom will slot before grade). Lower-layer
## passes render first, so each reads the accumulated result of the ones before it.

const GRADE_SHADER := preload("res://addons/lit/shaders/lit_post_grade.gdshader")
const THRESHOLD_SHADER := preload("res://addons/lit/shaders/lit_post_threshold.gdshader")
const VIGNETTE_SHADER := preload("res://addons/lit/shaders/lit_post_vignette.gdshader")
const PASS_META := "lit_post_pass"

@export_group("Threshold")
@export var threshold_enabled: bool = false:
	set(value):
		threshold_enabled = value
		_rebuild()
## Luma below this fades to black (with a short soft knee); brighter pixels pass.
@export_range(0.0, 1.0, 0.01) var threshold_cutoff: float = 0.5:
	set(value):
		threshold_cutoff = value
		_apply_params()

@export_group("Color Grade")
@export var grade_enabled: bool = false:
	set(value):
		grade_enabled = value
		_rebuild()                 # toggling a pass changes the chain structure
@export_range(0.0, 4.0, 0.01, "or_greater") var exposure: float = 1.0:
	set(value):
		exposure = value
		_apply_params()            # parameter tweak: push to the live material
@export_range(0.0, 4.0, 0.01, "or_greater") var contrast: float = 1.0:
	set(value):
		contrast = value
		_apply_params()
@export_range(0.0, 2.0, 0.01, "or_greater") var saturation: float = 1.0:
	set(value):
		saturation = value
		_apply_params()
@export var tint: Color = Color.WHITE:
	set(value):
		tint = value
		_apply_params()

@export_group("Vignette")
@export var vignette_enabled: bool = false:
	set(value):
		vignette_enabled = value
		_rebuild()
## How dark the edges get (0 = none, 1 = corners crushed to black).
@export_range(0.0, 1.0, 0.01) var vignette_strength: float = 0.4:
	set(value):
		vignette_strength = value
		_apply_params()
## Feather width of the vignette ramp (0 = tight to the corners, 1 = from center).
@export_range(0.0, 1.0, 0.01) var vignette_softness: float = 0.5:
	set(value):
		vignette_softness = value
		_apply_params()

# Generated pass materials, kept so parameter edits push without a rebuild.
var _threshold_material: ShaderMaterial
var _grade_material: ShaderMaterial
var _vignette_material: ShaderMaterial
# The base `layer` the current chain was built against, so an inspector edit to the
# node's layer can re-sync the pass child-layers live (editor only).
var _built_layer: int = 0


func _ready() -> void:
	_rebuild()
	set_process(Engine.is_editor_hint())


func _process(_delta: float) -> void:
	# Editor-only: keep pass layers ordered relative to the node if `layer` is edited.
	if layer != _built_layer:
		_rebuild()


## Tear down the generated pass chain and rebuild it from the enabled toggles.
func _rebuild() -> void:
	if not is_inside_tree():
		return
	for child in get_children(true):        # include_internal: our passes are internal
		if child.has_meta(PASS_META):
			remove_child(child)
			child.queue_free()
	_threshold_material = null
	_grade_material = null
	_vignette_material = null

	# Fixed canonical order: threshold -> grade -> vignette (bloom slots before grade
	# in 5(c)). Lower-layer passes render first, so each reads the prior result.
	var index := 0
	if threshold_enabled:
		_threshold_material = _make_pass(THRESHOLD_SHADER, index)
		index += 1
	if grade_enabled:
		_grade_material = _make_pass(GRADE_SHADER, index)
		index += 1
	if vignette_enabled:
		_vignette_material = _make_pass(VIGNETTE_SHADER, index)
		index += 1

	_built_layer = layer
	_apply_params()


## Build one pass: an internal child CanvasLayer (for ordering + the per-pass screen
## re-read) holding a fullscreen, input-transparent ColorRect with the pass shader.
## Returns the pass material so callers can push parameters to it later.
func _make_pass(shader: Shader, index: int) -> ShaderMaterial:
	var pass_layer := CanvasLayer.new()
	pass_layer.layer = layer + index + 1    # above this node's base layer, in order
	pass_layer.set_meta(PASS_META, true)

	var mat := ShaderMaterial.new()
	mat.shader = shader

	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)   # cover the viewport
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE     # never eat UI input
	rect.material = mat

	pass_layer.add_child(rect)
	add_child(pass_layer, false, Node.INTERNAL_MODE_BACK)
	return mat


## Push current parameters onto the generated pass materials (no rebuild needed).
func _apply_params() -> void:
	if _threshold_material != null:
		_threshold_material.set_shader_parameter("cutoff", threshold_cutoff)
	if _grade_material != null:
		_grade_material.set_shader_parameter("exposure", exposure)
		_grade_material.set_shader_parameter("contrast", contrast)
		_grade_material.set_shader_parameter("saturation", saturation)
		_grade_material.set_shader_parameter("tint", tint)
	if _vignette_material != null:
		_vignette_material.set_shader_parameter("strength", vignette_strength)
		_vignette_material.set_shader_parameter("softness", vignette_softness)
