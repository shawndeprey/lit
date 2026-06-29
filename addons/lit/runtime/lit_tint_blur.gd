@tool
@icon("res://addons/lit/icons/lit_point_light_2d.svg")
extends Node
class_name LitTintBlur

## Two-pass separable blur over the tint buffer, owned and driven by LitTintBuffer.
##
## Why this exists: the beam post-pass marches a fixed number of samples from each pixel
## toward each light and samples the tint buffer at each step. A small translucent object
## (e.g. a gem at scale 1.0) covers only a few buffer texels, so a sparse march mostly steps
## OVER it and lands on it at just a few ray fractions — echoing the gem's silhouette at
## intervals instead of producing a continuous shaft ("stamped gems with gaps"). Dilating the
## buffer with a Gaussian turns each stamp into a soft patch wider than the march step, so the
## march catches it every time and the beam reads as smooth volumetric haze.
##
## Pipeline: raw tint buffer texture -> [horizontal blur SubViewport] -> [vertical blur
## SubViewport] -> published as the global `lit_tint_buffer_blurred`, which lit_post_beams
## samples instead of the raw `lit_tint_buffer`. The receiver shader keeps using the SHARP
## `lit_tint_buffer` so surface tint stays pinned to the gem's exact shape; only the volumetric
## shafts use the blurred copy, which is exactly where the softness belongs.
##
## This is not a standalone scene node — LitTintBuffer constructs one internally. It has no
## per-scene wiring, so existing scenes get the fix with no changes.

const BLUR_SHADER := preload("res://addons/lit/shaders/lit_tint_blur.gdshader")

# Published global the beam pass reads. Registered by lit_plugin.gd alongside lit_tint_buffer.
const GLOBAL_NAME := "lit_tint_buffer_blurred"

# Kernel controls, surfaced on LitTintBuffer and forwarded here each frame so they stay
# live-tweakable in the inspector. Defaults give a ~12px effective radius, enough to close
# the gaps for gems down to a few pixels without smearing larger panes into mush.
var radius: int = 6
var spread: float = 2.0

var _h_vp: SubViewport       # horizontal pass: reads the raw buffer texture
var _v_vp: SubViewport       # vertical pass: reads the H result, its texture is published
var _h_rect: ColorRect
var _v_rect: ColorRect
var _h_mat: ShaderMaterial
var _v_mat: ShaderMaterial
var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return

	# Two offscreen passes. Each is a SubViewport holding one fullscreen ColorRect running the
	# blur shader. transparent_bg + CLEAR_MODE_ALWAYS so a cleared frame stays (0,0,0,0), the
	# same no-op clear the rest of the tint pipeline relies on. UPDATE_ALWAYS so they re-run
	# every frame as the source buffer changes.
	_h_vp = _make_pass_viewport("TintBlurH")
	_v_vp = _make_pass_viewport("TintBlurV")
	add_child(_h_vp, false, Node.INTERNAL_MODE_BACK)
	add_child(_v_vp, false, Node.INTERNAL_MODE_BACK)

	_h_mat = ShaderMaterial.new()
	_h_mat.shader = BLUR_SHADER
	_h_mat.set_shader_parameter("blur_dir", Vector2(1.0, 0.0))

	_v_mat = ShaderMaterial.new()
	_v_mat.shader = BLUR_SHADER
	_v_mat.set_shader_parameter("blur_dir", Vector2(0.0, 1.0))

	_h_rect = _make_pass_rect(_h_mat)
	_v_rect = _make_pass_rect(_v_mat)
	_h_vp.add_child(_h_rect, false, Node.INTERNAL_MODE_BACK)
	_v_vp.add_child(_v_rect, false, Node.INTERNAL_MODE_BACK)

	# The vertical pass reads the horizontal pass's output texture. Wired once here; the
	# horizontal pass's source (the raw buffer) is set per-frame in update() since that texture
	# is owned by LitTintBuffer.
	_v_mat.set_shader_parameter("source_tex", _h_vp.get_texture())

	_built = true


func _make_pass_viewport(pass_name: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = pass_name
	vp.transparent_bg = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Disable the default 2D canvas transform tracking — these viewports render a fullscreen
	# rect in their own UV space, decoupled from any camera.
	vp.disable_3d = true
	return vp


func _make_pass_rect(mat: ShaderMaterial) -> ColorRect:
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = mat
	return rect


## Driven by LitTintBuffer each frame: keep the passes sized to the buffer, feed the raw
## buffer texture into the horizontal pass, push live kernel params, and publish the result.
func update(source_texture: Texture2D, buffer_size: Vector2i) -> void:
	if not _built or source_texture == null:
		return
	if buffer_size.x <= 0 or buffer_size.y <= 0:
		return

	# Match both passes to the buffer resolution so blur UVs line up 1:1 with the source and
	# downstream SCREEN_UV. A size change (window resize) just resizes the passes.
	if _h_vp.size != buffer_size:
		_h_vp.size = buffer_size
	if _v_vp.size != buffer_size:
		_v_vp.size = buffer_size

	var texel := Vector2(1.0 / float(buffer_size.x), 1.0 / float(buffer_size.y))

	# Horizontal pass reads the raw tint buffer; vertical reads H's output (wired in _build).
	_h_mat.set_shader_parameter("source_tex", source_texture)

	for mat in [_h_mat, _v_mat]:
		mat.set_shader_parameter("texel_size", texel)
		mat.set_shader_parameter("radius", radius)
		mat.set_shader_parameter("spread", spread)

	# Publish the fully-blurred buffer for the beam pass. Done every frame because the
	# SubViewport's backing texture is stable but the global must point at it.
	RenderingServer.global_shader_parameter_set(GLOBAL_NAME, _v_vp.get_texture())
