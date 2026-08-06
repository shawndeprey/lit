@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostAutoExposure

## Eye adaptation: reacts to changes in scene brightness the way eyes do. A stable
## scene rests at the authored look, a flash drags its surroundings down, and
## lasting changes become the new normal over acclimate_time.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_auto_exposure.gdshader")
const REDUCE_SHADER := preload("res://addons/lit/shaders/post/lit_post_auto_exposure_reduce.gdshader")
const HIST_SHADER := preload("res://addons/lit/shaders/post/lit_post_auto_exposure_hist.gdshader")
const ADAPT_SHADER := preload("res://addons/lit/shaders/post/lit_post_auto_exposure_adapt.gdshader")

const _REDUCE_SIZE := Vector2i(64, 36)   # must match RW/RH in the hist/adapt shaders
const _HIST_SIZE := Vector2i(64, 6)      # must match BINS/GROUPS in the hist/adapt shaders

## How strongly the effect is applied overall. 1.0 = full effect, 0.0 = off, and
## values in between are a partial blend (animate this from code to fade the whole
## effect in or out). Higher = more auto-exposure. Lower = less.
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(value):
		amount = value
		apply_params()
## Where the screen rests when the lighting isn't changing, as a multiple of the
## scene's natural brightness. 1.0 = exactly as you lit it (the effect is
## invisible at rest). Lower = rests darker than your authored scene (0.5 = about
## half as bright). Higher = rests brighter (2.0 = about twice). Flash reactions
## happen on top of this resting point.
@export_range(0.01, 2.0, 0.01) var target_level: float = 1.0:
	set(value):
		target_level = value
		apply_params()
## A constant brighten/darken bias on top of the automatic result, if you want the
## game to run a bit brighter or darker than the effect would choose on its own.
## 0 = neutral. Higher (+1 = twice as bright) = always settles brighter. Lower
## (-1 = half as bright) = always settles darker.
@export_range(-2.0, 2.0, 0.01) var exposure_compensation: float = 0.0:
	set(value):
		exposure_compensation = value
		apply_params()
## The darkest the effect may make the screen when reacting to bright light: this
## is how hard a flash can crush everything around it. At -2.5 the surroundings
## can sink to roughly 1/5 of normal brightness. Lower (more negative) = flashes
## darken the world harder. Higher (toward 0) = gentler darkening; 0 = the effect
## never darkens at all.
@export_range(-4.0, 0.0, 0.01) var min_exposure: float = -2.5:
	set(value):
		min_exposure = value
		apply_params()
## The most the effect may brighten a dark scene, like eyes opening up in the
## dark. At 1.5 shadows can be lifted to roughly 3x brightness. Higher = dark
## scenes get boosted more (too high and night stops looking like night). Lower
## (toward 0) = less boosting; 0 = the effect never brightens at all.
@export_range(0.0, 4.0, 0.01) var max_exposure: float = 1.5:
	set(value):
		max_exposure = value
		apply_params()
## How many seconds the reaction takes when the scene suddenly gets BRIGHTER (the
## screen dims in response, like being dazzled by a flash). Human eyes take about
## 0.7-1.0 seconds. Lower = snaps dark almost instantly when a flash hits.
## Higher = reacts slowly, so short flashes barely register.
@export_range(0.05, 5.0, 0.01) var light_adapt_time: float = 0.85:
	set(value):
		light_adapt_time = value
		apply_params()
## How many seconds the screen takes to brighten back up after the bright light
## goes away (like waiting for your eyes to readjust in a dim room). Lower = quick
## recovery. Higher = you stay "blinded" longer after a flash. Feels most natural
## a few times longer than Light Adapt Time.
@export_range(0.05, 10.0, 0.01) var dark_adapt_time: float = 3.0:
	set(value):
		dark_adapt_time = value
		apply_params()
## How many seconds a LASTING lighting change takes to become the new "normal".
## If a light turns on and stays on, the reaction fades out over this time and the
## scene goes back to looking exactly as authored. Higher = the darkened/boosted
## reaction lingers longer. Lower = new lighting is accepted almost immediately.
## Short flashes end before this matters.
@export_range(0.5, 30.0, 0.1) var acclimate_time: float = 6.0:
	set(value):
		acclimate_time = value
		apply_params()
## How much the middle of the screen matters when judging scene brightness.
## Higher = mostly the center counts, so a bright light at the screen edge barely
## triggers a reaction. Lower = the whole screen counts equally, so edge lights
## react just as strongly as centered ones.
@export_range(0.0, 1.0, 0.01) var center_weight: float = 0.6:
	set(value):
		center_weight = value
		apply_params()
## How much of the screen's darkest area to ignore when judging brightness. At 0.7
## the darkest 70% of the screen is ignored, so the reaction follows the lights,
## not the darkness between them. Higher = only the very brightest spots drive the
## reaction. Lower = big dark areas count too, making the effect brighten dark
## scenes more aggressively.
@export_range(0.0, 0.95, 0.01) var histogram_low: float = 0.7:
	set(value):
		histogram_low = value
		apply_params()
## Ignores a sliver of the very brightest pixels so a few tiny sparkles or one
## white pixel can't darken the whole screen. At 0.97 the brightest 3% is ignored.
## Higher (toward 1.0) = even tiny bright specks can trigger darkening. Lower =
## more bright pixels get ignored, so only large bright areas cause a reaction.
@export_range(0.05, 1.0, 0.01) var histogram_high: float = 0.97:
	set(value):
		histogram_high = value
		apply_params()
## Shows a debug bar in the top-left of the screen so you can watch the effect
## work. The white needle is what the effect is doing right now: needle right of
## the center tick (blue fill) = brightening the screen, needle left of it
## (orange fill) = darkening it, needle on the tick = doing nothing. If the
## needle moves when a light flashes, the effect is working.
@export var show_meter: bool = false:
	set(value):
		show_meter = value
		apply_params()

var _reduce_vp: SubViewport = null
var _hist_vp: SubViewport = null
var _adapt_vp: Array[SubViewport] = []
var _reduce_mat: ShaderMaterial = null   # persists across toggles, like _mat
var _hist_mat: ShaderMaterial = null
var _adapt_mat: Array[ShaderMaterial] = []
var _flip := false


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 5


func _param_map() -> Dictionary:
	return {"amount": "amount", "show_meter": "show_meter"}


func _apply_extra_params(_mat_out: ShaderMaterial) -> void:
	for mat in _adapt_mat:
		mat.set_shader_parameter("target_level", target_level)
		mat.set_shader_parameter("exposure_compensation", exposure_compensation)
		mat.set_shader_parameter("min_exposure", min_exposure)
		mat.set_shader_parameter("max_exposure", max_exposure)
		mat.set_shader_parameter("light_adapt_time", light_adapt_time)
		mat.set_shader_parameter("dark_adapt_time", dark_adapt_time)
		mat.set_shader_parameter("acclimate_time", acclimate_time)
		mat.set_shader_parameter("histogram_low", histogram_low)
		mat.set_shader_parameter("histogram_high", histogram_high)
	if _hist_mat != null:
		_hist_mat.set_shader_parameter("center_weight", center_weight)


func _refresh() -> void:
	super._refresh()
	_sync_meter()


## Ping-pong: render one adapt viewport from the other's result, pass samples it.
func _effect_process(delta: float) -> void:
	if _reduce_vp == null:
		return
	_flip = not _flip
	var idx := 1 if _flip else 0
	_adapt_mat[idx].set_shader_parameter("delta_t", minf(delta, 0.25))
	_adapt_vp[idx].render_target_update_mode = SubViewport.UPDATE_ONCE
	_mat.set_shader_parameter("exposure_tex", _adapt_vp[idx].get_texture())


func _sync_meter() -> void:
	var active := _pass_layer != null
	if active == (_reduce_vp != null):
		if active:
			_reduce_mat.set_shader_parameter("source_tex", get_viewport().get_texture())
		return
	if not active:
		for vp in [_reduce_vp, _hist_vp] + _adapt_vp:
			remove_child(vp)
			vp.free()
		_reduce_vp = null
		_hist_vp = null
		_adapt_vp.clear()
		# unbind freed viewports; black defaults read as neutral
		_reduce_mat.set_shader_parameter("source_tex", null)
		_hist_mat.set_shader_parameter("reduce_tex", null)
		for mat in _adapt_mat:
			mat.set_shader_parameter("hist_tex", null)
			mat.set_shader_parameter("prev_tex", null)
		_mat.set_shader_parameter("exposure_tex", null)
		return
	if _reduce_mat == null:
		_reduce_mat = ShaderMaterial.new()
		_reduce_mat.shader = REDUCE_SHADER
		_hist_mat = ShaderMaterial.new()
		_hist_mat.shader = HIST_SHADER
		for i in 2:
			var mat := ShaderMaterial.new()
			mat.shader = ADAPT_SHADER
			_adapt_mat.append(mat)
	_reduce_vp = _make_meter_viewport(_REDUCE_SIZE, _reduce_mat)
	_reduce_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_hist_vp = _make_meter_viewport(_HIST_SIZE, _hist_mat)
	_hist_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for i in 2:
		_adapt_vp.append(_make_meter_viewport(Vector2i(2, 1), _adapt_mat[i]))
	_reduce_mat.set_shader_parameter("source_tex", get_viewport().get_texture())
	_hist_mat.set_shader_parameter("reduce_tex", _reduce_vp.get_texture())
	for i in 2:
		_adapt_mat[i].set_shader_parameter("hist_tex", _hist_vp.get_texture())
		_adapt_mat[i].set_shader_parameter("prev_tex", _adapt_vp[1 - i].get_texture())
	apply_params()


func _make_meter_viewport(vp_size: Vector2i, mat: ShaderMaterial) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = vp_size
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.material = mat
	vp.add_child(rect)
	add_child(vp, false, Node.INTERNAL_MODE_BACK)
	return vp
