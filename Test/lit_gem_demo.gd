extends Node2D

## Gemstone PBR showcase for Lit, with translucency and colored light-through-gem casts.
##
## Gems are authored in the scene (child LitSprite2D nodes under "Gems"); lights are
## authored under "Lights". This script only does runtime work:
##   - forces the PBR lighting model on,
##   - orbits the authored lights so highlights and transmission slide across the gems,
##   - drives the receiver's translucency (the _t transmission map + strength), and
##   - builds the "stained-glass" tint buffer that lets a gem cast a colored glow of the
##     light shining through it onto the floor and other gems.
##
## The tint buffer is a screen-sized SubViewport in which each gem is redrawn flat in its
## body color, masked by its transmission map, so the buffer holds "what color does this
## gem tint light to, and how much." The modified lit_receiver shader samples it during
## its shadow march: where a fragment is shadowed by a gem, the blocked light is recolored
## by that gem instead of going black. Published via the lit_tint_buffer global.

# Mirrors LitManager.LightingModel; the gem look only makes sense in PBR.
const LIT_MODEL_PBR := 1

const GEM_TRANSMISSION_PATH := "res://Test/Gemstone_00_t.png"

@export_group("Wiring")
## Parent whose LitSprite2D children are the gems. Defaults to a sibling "Gems".
@export var gems_root: Node2D
## Parent whose Lit light children get orbited. Defaults to a sibling "Lights".
@export var lights_root: Node2D

@export_group("Motion")
@export var light_speed: float = 1.0
@export var gem_spin: float = 0.15
@export var force_pbr: bool = true

@export_group("Translucency")
## How strongly light bleeds through each gem. Pushed to every gem's receiver material.
@export_range(0.0, 4.0) var transmission_strength: float = 1.6
## Softness of the through-glow past the terminator (0 hard, 1 very soft).
@export_range(0.0, 1.0) var transmission_wrap: float = 0.6
## Master switch for the colored light-through-gem cast (the stained-glass buffer).
@export var colored_casts: bool = true

var _area_center := Vector2(576, 324)
var _area_half := Vector2(540, 300)
var _clock := 0.0

var _transmission_tex: Texture2D

var _gems: Array[Node] = []
# each: { node, center, rx, ry, speed, phase, is_dir, is_spot, dir_speed }
var _lights: Array = []

# --- stained-glass tint buffer ---
var _tint_viewport: SubViewport
var _tint_root: Node2D
var _tint_proxies: Array[Sprite2D] = []   # one flat tinted copy per gem


func _ready() -> void:
	if force_pbr:
		RenderingServer.global_shader_parameter_set("lit_lighting_model", LIT_MODEL_PBR)

	if gems_root == null:
		gems_root = get_node_or_null("../Gems")
	if lights_root == null:
		lights_root = get_node_or_null("../Lights")

	_transmission_tex = load(GEM_TRANSMISSION_PATH) if ResourceLoader.exists(GEM_TRANSMISSION_PATH) else null

	_compute_area()
	_collect_gems()
	_register_lights()
	_apply_transmission_to_gems()
	if colored_casts:
		_build_tint_buffer()
	else:
		RenderingServer.global_shader_parameter_set("lit_tint_enabled", false)


func _exit_tree() -> void:
	# Leave the global in a clean state so other scenes aren't tinted by a stale buffer.
	RenderingServer.global_shader_parameter_set("lit_tint_enabled", false)


func _compute_area() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam:
		_area_center = cam.get_screen_center_position()
		_area_half = get_viewport_rect().size * 0.5 / cam.zoom
	else:
		_area_center = get_viewport_rect().size * 0.5
		_area_half = get_viewport_rect().size * 0.5
	_area_half *= 0.85


func _collect_gems() -> void:
	_gems.clear()
	if gems_root == null:
		return
	for c in gems_root.get_children():
		if c is Sprite2D:
			_gems.append(c)


# Push the translucency settings onto every gem's receiver material. Each gem keeps its
# own ShaderMaterial (authored in the scene), so we set the params per-instance and hand
# it the shared transmission map.
func _apply_transmission_to_gems() -> void:
	for g in _gems:
		var spr := g as Sprite2D
		var mat := spr.material as ShaderMaterial
		if mat == null:
			continue
		mat.set_shader_parameter("transmission_strength", transmission_strength)
		mat.set_shader_parameter("transmission_wrap", transmission_wrap)
		if _transmission_tex:
			mat.set_shader_parameter("transmission_map", _transmission_tex)


func _register_lights() -> void:
	_lights.clear()
	if lights_root == null:
		return
	for n in lights_root.get_children():
		var is_dir := n is LitDirectionalLight2D
		var is_spot := n is LitSpotLight2D
		var is_point := n is LitPointLight2D
		if not (is_dir or is_spot or is_point):
			continue
		var center: Vector2 = n.position if not is_dir else _area_center
		_lights.append({
			"node": n,
			"center": center,
			"rx": randf_range(_area_half.x * 0.35, _area_half.x * 0.8),
			"ry": randf_range(_area_half.y * 0.35, _area_half.y * 0.8),
			"speed": randf_range(0.2, 0.55) * (1.0 if randf() > 0.5 else -1.0),
			"phase": randf() * TAU,
			"is_dir": is_dir,
			"is_spot": is_spot,
			"dir_speed": randf_range(0.15, 0.4) * (1.0 if randf() > 0.5 else -1.0),
		})


# =====================================================================================
# Stained-glass tint buffer
# =====================================================================================

# Build a screen-sized SubViewport that re-renders each gem flat in its body color,
# masked by the transmission map, on a transparent background. The receiver samples the
# result during its shadow march. We keep one proxy Sprite2D per gem and sync its
# transform to the real gem every frame.
func _build_tint_buffer() -> void:
	_tint_viewport = SubViewport.new()
	_tint_viewport.size = Vector2i(get_viewport_rect().size)
	_tint_viewport.transparent_bg = true
	_tint_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_tint_viewport.disable_3d = true
	add_child(_tint_viewport)

	# A camera in the SubViewport matching the main camera, so gem screen positions line up
	# with the main view (which is what the receiver samples with SCREEN_UV).
	var cam := Camera2D.new()
	cam.position = _area_center
	_tint_viewport.add_child(cam)
	cam.make_current()

	_tint_root = Node2D.new()
	_tint_viewport.add_child(_tint_root)

	# A tiny shader that outputs the gem's modulate color with the transmission map as
	# alpha: RGB = body color, A = how much this texel tints passing light.
	var tint_shader := Shader.new()
	tint_shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D t_map : hint_default_white;
void fragment() {
	float a = texture(t_map, UV).r;
	// COLOR.rgb carries the gem's modulate; mask coverage by the transmission map and
	// the sprite's own alpha so only the gem footprint paints tint.
	float cov = a * texture(TEXTURE, UV).a;
	COLOR = vec4(COLOR.rgb, cov);
}
"""
	for g in _gems:
		var spr := g as Sprite2D
		var proxy := Sprite2D.new()
		proxy.texture = spr.texture
		proxy.modulate = spr.modulate              # the gem's random body color
		proxy.texture_filter = spr.texture_filter
		var pmat := ShaderMaterial.new()
		pmat.shader = tint_shader
		if _transmission_tex:
			pmat.set_shader_parameter("t_map", _transmission_tex)
		proxy.material = pmat
		_tint_root.add_child(proxy)
		_tint_proxies.append(proxy)

	# Publish the buffer to the receiver shader.
	RenderingServer.global_shader_parameter_set("lit_tint_buffer", _tint_viewport.get_texture())
	RenderingServer.global_shader_parameter_set("lit_tint_enabled", true)


func _sync_tint_proxies() -> void:
	if _tint_root == null:
		return
	for i in _gems.size():
		var gem := _gems[i] as Sprite2D
		var proxy := _tint_proxies[i]
		if not (is_instance_valid(gem) and is_instance_valid(proxy)):
			continue
		proxy.global_position = gem.global_position
		proxy.rotation = gem.rotation
		proxy.scale = gem.scale
		proxy.modulate = gem.modulate


func _process(dt: float) -> void:
	_clock += dt
	for d in _lights:
		var n = d.node
		if not is_instance_valid(n):
			continue
		if d.is_dir:
			n.rotation = d.phase + _clock * d.dir_speed * light_speed
		else:
			var t: float = _clock * d.speed * light_speed + d.phase
			var p: Vector2 = d.center + Vector2(cos(t) * d.rx, sin(t) * d.ry)
			n.position = p
			if d.is_spot:
				n.rotation = (_area_center - p).angle()

	if gem_spin != 0.0:
		for g in _gems:
			if is_instance_valid(g):
				g.rotation += dt * gem_spin

	if colored_casts:
		_sync_tint_proxies()
