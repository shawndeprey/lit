extends Node2D

## Lit performance / tech demo.
##
## A self-contained, staged showcase and benchmark for the Lit plugin. Press the
## on-screen button to start: it hides the scene's existing lights, drops in its own
## occluder props, and runs a timed reel that shows one feature at a time (named by an
## on-screen label) while a perf panel reports FPS, frame time, live light count, and
## draw calls.
##
## Everything is spawned at runtime and torn down on stop, so it never touches the saved
## scene. All demo lights run Cone Traced soft shadows (neutral hardness 0.5); a
## dedicated Shadow Algorithms section near the start cycles all three algorithms on a
## dozen colored point lights. The scene's own occluders stay live in the SDF, so the
## saved scene's props cast alongside the demo's circle props.

# Fast variant: the demo's receivers never use self-shadow exclusion. Prop materials
# set self_shadow true so the registry driver keeps them here.
const RECEIVER_SHADER := preload("res://addons/lit/shaders/lit_receiver_fast.gdshader")

const MAX_LIGHTS := 128
const COOKIE_MAX_LIGHTS := 64
const PROP_COUNT := 7
const BRAND := Color("#ffca60")

# The circle props' shared texture: a white disc rendered once into this image size,
# with this radius in texels (the margin keeps the anti-aliased rim off the edge).
const CIRCLE_TEX_SIZE := 64
const CIRCLE_TEX_RADIUS := 30.0

# Light count for the Shadow Algorithms section: enough overlapping casters to read
# the penumbra behavior clearly without burying it.
const ALGO_STAGE_LIGHTS := 12

# Lighting models, mirroring LitManager.LightingModel / LIT_MODEL_* in the receiver shader.
# The PBR stage flips the lit_lighting_model global directly on the RenderingServer for a
# clean runtime toggle, then restores it on teardown so the rest of the reel stays Phong.
const LIT_MODEL_PHONG := 0
const LIT_MODEL_PBR := 1

# Cookie textures for the Light Textures stage; loaded lazily, and the stage falls
# back to plain point lights if none import.
const COOKIE_DIR := "res://Test/textures/cookies/"
const COOKIE_FILES := [
	"cookie_window.png", "cookie_blinds.png", "cookie_canopy.png",
	"cookie_flashlight.png", "cookie_soft_radial.png",
]

# Skull PBR material maps. The diffuse is left untouched; the normal feeds the CanvasTexture
# normal slot, while roughness (derived 1 - specular) and AO (the old _o occlusion map) feed
# the receiver's PBR uniforms. Bone is a dielectric, so metallic stays 0 via the scalar.
# NOTE: import roughness/AO/normal as linear (sRGB unchecked); diffuse stays sRGB.
const SKULL_DIFFUSE_PATH := "res://addons/lit/demo/cinderskull_preview.png"
const SKULL_NORMAL_PATH := "res://addons/lit/demo/cinderskull_preview_n.png"
const SKULL_ROUGHNESS_PATH := "res://addons/lit/demo/cinderskull_preview_r.png"
const SKULL_AO_PATH := "res://addons/lit/demo/cinderskull_preview_o.png"

# --- runtime state ---
var _running := false
var _stage_index := -1
var _stage_time := 0.0
var _clock := 0.0
var _perf_accum := 0.0

# Per-frame render-time sums, so the perf panel shows a window average.
var _perf_frames := 0
var _perf_cpu_sum := 0.0
var _perf_gpu_sum := 0.0

var _white_tex: ImageTexture
var _circle_tex: ImageTexture
var _area_center := Vector2(576, 324)
var _area_half := Vector2(560, 320)

var _lights: Array = []          # each: { node, kind, motion params... }
var _props: Array = []           # each: { root, mat }

# captured scene state, restored on teardown
var _orig_lights: Array = []
var _modulate: Node = null
var _orig_modulate_color := Color.BLACK
var _post: Node = null
var _post_orig := {}

# The lighting model in effect before the demo touched it, captured on start and restored
# on teardown. The PBR stage overrides the live global; everything else runs Phong.
var _orig_lighting_model := LIT_MODEL_PHONG

# Loaded cookie textures.
var _cookie_textures: Array = []

# Lazily-built skull prop maps, shared across the PBR stage's props.
var _skull_diffuse: Texture2D = null
var _skull_normal: Texture2D = null
var _skull_roughness: Texture2D = null
var _skull_ao: Texture2D = null

# True while the PBR stage's skull props stand in for the standard white blocks, so the
# next stage knows to restore the blocks.
var _props_are_skulls := false

# --- UI ---
var _ui: CanvasLayer
var _start_btn: Button
var _restart_btn: Button
var _skip_btn: Button
var _stop_btn: Button
var _feature_lbl: Label
var _desc_lbl: Label
var _counter_lbl: Label
var _perf_lbl: Label

# --- stage table ---
var _stages := [
	{"id": "intro",     "name": "Lit",                       "desc": "Lighting & Performance Demo",          "dur": 3.5,  "auto": true},
	{"id": "point",     "name": "Point Light",               "desc": "One light • full soft shadows",        "dur": 5.0,  "auto": true},
	{"id": "dir",       "name": "Directional Light",         "desc": "A sun - parallel light, sweeping shadows", "dur": 5.0, "auto": true},
	{"id": "spot",      "name": "Spot Light",                "desc": "An aimable cone",                      "dur": 5.0,  "auto": true},
	{"id": "algo_ray",   "name": "Shadows · Raymarched",     "desc": "The classic fast march - stylized penumbra", "dur": 5.0, "auto": true},
	{"id": "algo_cone",  "name": "Shadows · Cone Traced",    "desc": "The default - physical penumbras that widen, umbras that taper closed", "dur": 5.0, "auto": true},
	{"id": "algo_stoch", "name": "Shadows · Stochastic",     "desc": "Ground-truth sampled area shadows",    "dur": 5.0,  "auto": true},
	{"id": "colors",    "name": "Many Colored Lights",       "desc": "Mixed types, every color, all moving", "dur": 6.0,  "auto": true},
	{"id": "shadows",   "name": "Layered Soft Shadows",      "desc": "Overlapping casters, all real-time",   "dur": 6.0,  "auto": true},
	{"id": "negative",  "name": "Negative Lights",           "desc": "Subtract mode carves darkness",        "dur": 5.0,  "auto": true},
	{"id": "masks",     "name": "Light Masks",               "desc": "Lights only touch matching objects",   "dur": 5.5,  "auto": true},
	{"id": "stress",    "name": "Stress Test",               "desc": "Ramping up to 128 lights…",            "dur": 14.0, "auto": true},
	{"id": "cookies",   "name": "Light Textures",            "desc": "Cookie-shaped lights • ramping to 64, full soft shadows", "dur": 14.0, "auto": true},
	{"id": "pbr",       "name": "PBR Materials",             "desc": "Metallic-roughness · normal, roughness & AO maps", "dur": 9.0, "auto": true},
	{"id": "fx_bloom",     "name": "Post FX - Bloom",           "desc": "Glow on the brights",                 "dur": 4.0,  "auto": true},
	{"id": "fx_halation",  "name": "Post FX - Bloom + Halation","desc": "Warm highlight bleed, pure fire",    "dur": 4.5,  "auto": true},
	{"id": "fx_grade",     "name": "Post FX - Color Grade + LUT","desc": "Cinematic color",                     "dur": 4.0,  "auto": true},
	{"id": "fx_crt",    "name": "Post FX - CRT",            "desc": "Curvature, scanlines, shadow mask",    "dur": 4.0,  "auto": true},
	{"id": "fx_vhs",    "name": "Post FX - VHS",            "desc": "Tape wobble & chroma bleed",           "dur": 4.0,  "auto": true},
	{"id": "fx_glitch", "name": "Post FX - Glitch",         "desc": "Datamosh tearing & RGB split",         "dur": 4.0,  "auto": true},
	{"id": "finale",    "name": "Lit",                       "desc": "github.com/shawndeprey/lit",           "dur": 0.0,  "auto": false},
]


# =====================================================================================
# Setup
# =====================================================================================

func _ready() -> void:
	# Vsync off for uncapped frame times; render-time measurement feeds the perf panel
	# the same CPU/GPU ms the stress bench reports.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_white_tex = ImageTexture.create_from_image(img)
	_circle_tex = _make_circle_texture()
	_build_ui()
	_set_ui_state("idle")


# White disc with a 1px anti-aliased rim, shared by every circle prop.
func _make_circle_texture() -> ImageTexture:
	var img := Image.create(CIRCLE_TEX_SIZE, CIRCLE_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var c := Vector2(CIRCLE_TEX_SIZE, CIRCLE_TEX_SIZE) * 0.5
	for y in CIRCLE_TEX_SIZE:
		for x in CIRCLE_TEX_SIZE:
			var d := (Vector2(x + 0.5, y + 0.5) - c).length()
			var a := clampf(CIRCLE_TEX_RADIUS - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 128                        # above the post-process pass layers, so the HUD stays crisp
	add_child(_ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(root)

	_perf_lbl = _make_label(root, 18, Color(0.6, 1.0, 0.7), HORIZONTAL_ALIGNMENT_LEFT)
	_set_rect(_perf_lbl, 0, 0, 0, 0, 16, 14, 250, 200)

	_feature_lbl = _make_label(root, 46, BRAND, HORIZONTAL_ALIGNMENT_CENTER)
	_set_rect(_feature_lbl, 0, 0, 1, 0, 0, 22, 0, 86)

	_desc_lbl = _make_label(root, 21, Color(0.9, 0.92, 0.96), HORIZONTAL_ALIGNMENT_CENTER)
	_set_rect(_desc_lbl, 0, 0, 1, 0, 0, 84, 0, 120)

	_counter_lbl = _make_label(root, 15, Color(0.7, 0.72, 0.8), HORIZONTAL_ALIGNMENT_CENTER)
	_set_rect(_counter_lbl, 0, 0, 1, 0, 0, 120, 0, 144)

	_start_btn = _make_button(root, "▶  Start Performance Demo")
	_set_rect(_start_btn, 0, 1, 0, 1, 16, -58, 340, -16)   # bottom-left
	_start_btn.pressed.connect(_begin)

	_restart_btn = _make_button(root, "⟳  Restart Demo")
	_set_rect(_restart_btn, 0.5, 0.5, 0.5, 0.5, -150, 18, 150, 74)
	_restart_btn.pressed.connect(_on_restart)

	_skip_btn = _make_button(root, "Skip  ▶▶")
	_set_rect(_skip_btn, 1, 1, 1, 1, -150, -58, -16, -16)
	_skip_btn.pressed.connect(_on_skip)

	_stop_btn = _make_button(root, "■  Stop")
	_set_rect(_stop_btn, 0, 1, 0, 1, 16, -58, 150, -16)
	_stop_btn.pressed.connect(_teardown_to_idle)


func _make_label(parent: Control, size: int, color: Color, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _make_button(parent: Control, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 20)
	parent.add_child(b)
	return b


func _set_rect(c: Control, la: float, ta: float, ra: float, ba: float, lo: float, to: float, ro: float, bo: float) -> void:
	c.anchor_left = la; c.anchor_top = ta; c.anchor_right = ra; c.anchor_bottom = ba
	c.offset_left = lo; c.offset_top = to; c.offset_right = ro; c.offset_bottom = bo


func _set_ui_state(state: String) -> void:
	var running := state == "running" or state == "finale"
	_start_btn.visible = state == "idle"
	_restart_btn.visible = state == "finale"
	_skip_btn.visible = state == "running"
	_stop_btn.visible = running
	_feature_lbl.visible = running
	_desc_lbl.visible = running
	_counter_lbl.visible = running
	# Always visible: the demo scene doubles as the manual performance test.
	_perf_lbl.visible = true


# =====================================================================================
# Demo lifecycle
# =====================================================================================

func _begin() -> void:
	_compute_area()
	_capture_scene_state()
	_spawn_props()
	_running = true
	_set_ui_state("running")
	_enter_stage(0)


func _on_restart() -> void:
	_teardown()
	_begin()


func _teardown_to_idle() -> void:
	_teardown()
	_set_ui_state("idle")


func _teardown() -> void:
	_running = false
	_stage_index = -1
	_clear_lights()
	_clear_props()
	for l in _orig_lights:
		if is_instance_valid(l):
			l.enabled = true
	_orig_lights.clear()
	if is_instance_valid(_modulate):
		_modulate.color = _orig_modulate_color
	if is_instance_valid(_post):
		for k in _post_orig:
			_post.set(k, _post_orig[k])
	_post_orig.clear()
	# Put the lighting model back the way the scene had it.
	RenderingServer.global_shader_parameter_set("lit_lighting_model", _orig_lighting_model)
	_props_are_skulls = false


func _capture_scene_state() -> void:
	# The lights already in the scene are the originals; capture before we spawn any.
	_orig_lights = get_tree().get_nodes_in_group("lit_lights").duplicate()
	for l in _orig_lights:
		l.enabled = false

	# Remember the live lighting model so the PBR stage can override it and teardown can
	# put it back. global_shader_parameter_get is editor-only (blocked at runtime), so read
	# the project setting that LitManager publishes from, not the RenderingServer global.
	# Setting the global at runtime is fine; only getting it is blocked.
	_orig_lighting_model = clampi(int(ProjectSettings.get_setting(
		"lit/render/lighting_model", LIT_MODEL_PHONG)), LIT_MODEL_PHONG, LIT_MODEL_PBR)

	var scene := get_tree().current_scene
	_modulate = _find_first(scene, LitCanvasModulate)
	if _modulate:
		_orig_modulate_color = _modulate.color
		_modulate.color = Color(0.02, 0.02, 0.03)   # near-black for max contrast

	_post = _find_first(scene, LitPostProcess)
	if _post:
		for k in ["visible", "bloom_enabled", "grade_enabled", "lut_enabled", "crt_enabled", "vhs_enabled", "glitch_enabled"]:
			_post_orig[k] = _post.get(k)
		_post_all_off()

	# The scene's own occluders (e.g. the skull's LightOccluder2D) stay live in the
	# SDF: the shadow algorithms handle overlapping casters cleanly, so the saved
	# scene's props simply cast alongside the demo's.


func _compute_area() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam:
		_area_center = cam.get_screen_center_position()
		_area_half = get_viewport_rect().size * 0.5 / cam.zoom
	else:
		_area_center = get_viewport_rect().size * 0.5
		_area_half = get_viewport_rect().size * 0.5
	_area_half *= 0.9


func _find_first(node: Node, type) -> Node:
	if node == null:
		return null
	if is_instance_of(node, type):
		return node
	for c in node.get_children():
		var r := _find_first(c, type)
		if r:
			return r
	return null


func _find_all(node: Node, type, acc := []) -> Array:
	if node == null:
		return acc
	if is_instance_of(node, type):
		acc.append(node)
	for c in node.get_children():
		_find_all(c, type, acc)
	return acc


# =====================================================================================
# Props (the demo's own occluders)
# =====================================================================================

func _spawn_props() -> void:
	for i in PROP_COUNT:
		var ang := TAU * float(i) / float(PROP_COUNT)
		var pos := _area_center + Vector2(cos(ang) * _area_half.x * 0.55, sin(ang) * _area_half.y * 0.55)
		_make_prop(pos, randf_range(40.0, 68.0))


# A sphere prop: white disc sprite plus a matching circle occluder polygon. Round
# silhouettes show the algorithms' curved penumbras better than boxes do.
func _make_prop(pos: Vector2, radius: float) -> void:
	var root := Node2D.new()
	root.position = pos
	add_child(root)

	var spr := Sprite2D.new()
	spr.texture = _circle_tex
	spr.scale = Vector2.ONE * (radius / CIRCLE_TEX_RADIUS)
	spr.modulate = Color(0.82, 0.84, 0.92)
	var mat := ShaderMaterial.new()
	mat.shader = RECEIVER_SHADER
	mat.set_shader_parameter("self_shadow", true)
	spr.material = mat
	root.add_child(spr)

	var occ := LightOccluder2D.new()       # sdf_collision defaults true, so it feeds the SDF
	var poly := OccluderPolygon2D.new()
	poly.polygon = _circle_polygon(radius)
	occ.occluder = poly
	root.add_child(occ)

	_props.append({"root": root, "mat": mat})


static func _circle_polygon(radius: float, segments := 20) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segments:
		var a := TAU * float(i) / float(segments)
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts


func _clear_props() -> void:
	for p in _props:
		if is_instance_valid(p.root):
			p.root.queue_free()
	_props.clear()


# Load the cookie textures once; false when none exist.
func _ensure_cookie_textures() -> bool:
	if _cookie_textures.is_empty():
		for f in COOKIE_FILES:
			var path: String = COOKIE_DIR + f
			if ResourceLoader.exists(path):
				_cookie_textures.append(load(path))
	return not _cookie_textures.is_empty()


# Lazily load the skull maps once. Returns false if any required map is missing, so the
# PBR stage can degrade gracefully instead of erroring on a half-installed demo.
func _ensure_skull_textures() -> bool:
	if _skull_diffuse == null and ResourceLoader.exists(SKULL_DIFFUSE_PATH):
		_skull_diffuse = load(SKULL_DIFFUSE_PATH)
	if _skull_normal == null and ResourceLoader.exists(SKULL_NORMAL_PATH):
		_skull_normal = load(SKULL_NORMAL_PATH)
	if _skull_roughness == null and ResourceLoader.exists(SKULL_ROUGHNESS_PATH):
		_skull_roughness = load(SKULL_ROUGHNESS_PATH)
	if _skull_ao == null and ResourceLoader.exists(SKULL_AO_PATH):
		_skull_ao = load(SKULL_AO_PATH)
	return _skull_diffuse != null and _skull_normal != null


# A row of skull props centered in the play area. Each is identical material-wise; the
# point is to see the PBR maps respond to the moving lights, not to vary the material.
func _spawn_skull_grid() -> void:
	if not _ensure_skull_textures():
		# Maps not imported yet: fall back to the old white blocks so the stage still runs.
		_spawn_props()
		return
	var count := 5
	var spacing: float = min(_area_half.x * 2.0 / float(count + 1), 220.0)
	var tex_scale := 3.0  # the maps are 32px; scale up so the surface detail is visible
	for i in count:
		var x := _area_center.x + (float(i) - float(count - 1) * 0.5) * spacing
		var pos := Vector2(x, _area_center.y)
		_make_skull_prop(pos, tex_scale)


func _make_skull_prop(pos: Vector2, tex_scale: float) -> void:
	var root := Node2D.new()
	root.position = pos
	add_child(root)

	# Diffuse + normal ride together on a CanvasTexture: Godot feeds normal_texture into the
	# shader's NORMAL, which the receiver uses in both Phong and PBR. The diffuse is the
	# untouched original art.
	var ctex := CanvasTexture.new()
	ctex.diffuse_texture = _skull_diffuse
	ctex.normal_texture = _skull_normal

	var spr := Sprite2D.new()
	spr.texture = ctex
	spr.scale = Vector2(tex_scale, tex_scale)

	var mat := ShaderMaterial.new()
	mat.shader = RECEIVER_SHADER
	mat.set_shader_parameter("self_shadow", true)
	# PBR material inputs. Roughness and AO are real maps; their scalars stay at 1 so the
	# map drives the value. Metallic is 0 (bone is a dielectric) with no map needed.
	mat.set_shader_parameter("roughness_map", _skull_roughness)
	mat.set_shader_parameter("roughness_value", 1.0)
	mat.set_shader_parameter("ao_map", _skull_ao)
	mat.set_shader_parameter("metallic_value", 0.0)
	spr.material = mat
	root.add_child(spr)

	# Occlude from the SDF using the sprite's footprint so the skulls cast shadows too.
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var tex_size := _skull_diffuse.get_size() * tex_scale
	var hw := tex_size.x * 0.5
	var hh := tex_size.y * 0.5
	poly.polygon = PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])
	occ.occluder = poly
	root.add_child(occ)

	_props.append({"root": root, "mat": mat})


# =====================================================================================
# Lights
# =====================================================================================

func _spawn_light(kind: String, col: Color, hue_cycle := false) -> Dictionary:
	var n
	match kind:
		"cookie":
			# Point light shaped by a random cookie; falloff 0 leaves the falloff to the
			# texture, and the scale range keeps most cookies inside the range circle.
			n = LitPointLight2D.new()
			n.range = randf_range(220, 380)
			n.height = randf_range(12, 26)
			n.falloff = 0.0
			n.texture = _cookie_textures.pick_random()
			n.texture_size_mode = LitPointLight2D.TextureSizeMode.FIT_RANGE
			n.texture_scale = randf_range(0.72, 1.0)
		"spot":
			n = LitSpotLight2D.new()
			n.range = randf_range(280, 460)
			n.spot_angle = randf_range(18, 42)
			n.spot_softness = randf_range(0.45, 0.95)
			n.height = randf_range(20, 60)
		"dir":
			n = LitDirectionalLight2D.new()
			n.height = randf_range(10, 22)
		_:
			n = LitPointLight2D.new()
			n.range = randf_range(220, 380)
			n.height = randf_range(12, 26)
	n.color = col
	n.energy = randf_range(1.3, 2.4)
	n.shadow_enabled = true
	# Explicitly Cone Traced (the node default too, but the demo shouldn't drift if
	# defaults ever move); the Shadow Algorithms section overrides per stage.
	n.shadow_algorithm = LitPointLight2D.ShadowAlgorithm.CONE_TRACED
	n.shadow_hardness = 0.5                # neutral penumbra contrast under the cone default
	add_child(n)

	var d := {
		"node": n, "kind": kind, "base_energy": n.energy,
		"center": _area_center + Vector2(randf_range(-_area_half.x * 0.18, _area_half.x * 0.18), randf_range(-_area_half.y * 0.18, _area_half.y * 0.18)),
		"rx": randf_range(_area_half.x * 0.30, _area_half.x * 0.88),
		"ry": randf_range(_area_half.y * 0.30, _area_half.y * 0.88),
		"speed": randf_range(0.25, 0.9) * (1.0 if randf() > 0.5 else -1.0),
		"phase": randf() * TAU,
		"pulse_speed": (randf_range(1.5, 3.5) if randf() > 0.45 else 0.0),
		"hue": (randf() if hue_cycle else -1.0),
		"dir_speed": randf_range(0.15, 0.4) * (1.0 if randf() > 0.5 else -1.0),
	}
	_lights.append(d)
	return d


func _ensure_count(target: int, kinds: Array, colorful: bool) -> void:
	while _lights.size() < target:
		var kind: String = kinds[_lights.size() % kinds.size()]
		var col := Color.from_hsv(randf(), 0.85, 1.0) if colorful else Color(1.0, 0.94, 0.82)
		_spawn_light(kind, col, colorful)
	while _lights.size() > target:
		var d = _lights.pop_back()
		if is_instance_valid(d.node):
			d.node.queue_free()


func _clear_lights() -> void:
	for d in _lights:
		if is_instance_valid(d.node):
			d.node.queue_free()
	_lights.clear()


func _update_lights() -> void:
	for d in _lights:
		var n = d.node
		if not is_instance_valid(n):
			continue
		if d.kind == "dir":
			n.rotation = d.phase + _clock * d.dir_speed
		else:
			var p: Vector2 = d.center + Vector2(cos(_clock * d.speed + d.phase) * d.rx, sin(_clock * d.speed + d.phase) * d.ry)
			n.position = p
			if d.kind == "spot":
				n.rotation = (_area_center - p).angle()
			elif d.kind == "cookie":
				n.rotation = d.phase + _clock * d.dir_speed   # slow spin
		if d.pulse_speed > 0.0:
			n.energy = d.base_energy * (0.72 + 0.28 * sin(_clock * d.pulse_speed + d.phase))
		if d.hue >= 0.0:
			n.color = Color.from_hsv(fposmod(d.hue + _clock * 0.05, 1.0), 0.85, 1.0)


# =====================================================================================
# Post-processing helpers
# =====================================================================================

func _post_all_off() -> void:
	if not is_instance_valid(_post):
		return
	_post.visible = false
	for k in ["bloom_enabled", "grade_enabled", "lut_enabled", "crt_enabled", "vhs_enabled", "glitch_enabled"]:
		_post.set(k, false)


# =====================================================================================
# Stage machine
# =====================================================================================

func _enter_stage(idx: int) -> void:
	_stage_index = idx
	_stage_time = 0.0
	var s = _stages[idx]
	_feature_lbl.text = s.name
	_desc_lbl.text = s.desc
	_counter_lbl.text = "%d / %d" % [idx + 1, _stages.size()]
	_set_ui_state("finale" if s.id == "finale" else "running")

	# Post is off for everything except the FX stages and finale.
	if not String(s.id).begins_with("fx_") and s.id != "finale":
		_post_all_off()

	# Lighting model is Phong for the whole reel except the dedicated PBR stage, which
	# flips the global on entry. Setting it on every stage (not just on the two
	# transitions) keeps it correct when the user skips in or out of the PBR stage.
	RenderingServer.global_shader_parameter_set(
		"lit_lighting_model", LIT_MODEL_PBR if s.id == "pbr" else LIT_MODEL_PHONG)

	# The PBR stage replaces the white-block props with skulls. When we leave it for any
	# other stage, put the standard blocks back so the rest of the reel looks unchanged.
	if s.id != "pbr" and _props_are_skulls:
		_clear_props()
		_spawn_props()
		_props_are_skulls = false

	match s.id:
		"intro":
			_clear_lights()
			_spawn_light("point", Color(1.0, 0.9, 0.75))
		"point":
			_clear_lights()
			_spawn_light("point", Color(1.0, 0.92, 0.8))
		"dir":
			_clear_lights()
			_spawn_light("dir", Color(1.0, 0.95, 0.85))
		"spot":
			_clear_lights()
			_spawn_light("spot", Color(0.6, 0.8, 1.0))
		"algo_ray":
			# The Shadow Algorithms section: the same dozen colored point lights persist
			# across all three stages, so the only thing that changes on screen is the
			# algorithm itself.
			_clear_lights()
			_ensure_count(ALGO_STAGE_LIGHTS, ["point"], true)
			_set_shadow_algorithm(LitPointLight2D.ShadowAlgorithm.RAYMARCHED)
		"algo_cone":
			_ensure_count(ALGO_STAGE_LIGHTS, ["point"], true)
			_set_shadow_algorithm(LitPointLight2D.ShadowAlgorithm.CONE_TRACED)
		"algo_stoch":
			_ensure_count(ALGO_STAGE_LIGHTS, ["point"], true)
			_set_shadow_algorithm(LitPointLight2D.ShadowAlgorithm.STOCHASTIC)
		"colors":
			_clear_lights()
			_ensure_count(12, ["point", "spot", "point", "dir"], true)
		"shadows":
			_ensure_count(24, ["point", "spot", "point"], true)
		"negative":
			_ensure_count(18, ["point", "spot"], true)
			for i in 2:
				var sd := _spawn_light("point", Color.WHITE)
				sd.node.blend_mode = LitPointLight2D.BlendMode.SUBTRACT
				sd.node.energy = 1.7
				sd.node.range = 360.0
				sd.base_energy = 1.7
				sd.pulse_speed = 0.0
				sd.hue = -1.0
		"masks":
			_clear_lights()
			for i in _props.size():
				_props[i].mat.set_shader_parameter("receiver_mask", 1 if i % 2 == 0 else 2)
			for i in 6:
				var is_red := i % 2 == 0
				var md := _spawn_light("point", Color(1.0, 0.3, 0.3) if is_red else Color(0.4, 0.55, 1.0))
				md.node.light_mask = 1 if is_red else 2
				md.hue = -1.0
		"stress":
			for p in _props:
				p.mat.set_shader_parameter("receiver_mask", 1)   # undo the mask split
			_clear_lights()
			_ensure_count(8, ["point", "spot", "point", "dir"], true)
		"cookies":
			# Textured lights, ramping to COOKIE_MAX_LIGHTS in _update_stage.
			_clear_lights()
			_ensure_count(8, _cookie_kinds(), true)
		"pbr":
			# Swap the plain white occluder blocks for skull props that carry real
			# normal / roughness / AO maps, so the PBR path has surface detail to act on.
			# A pair of warm orbiting point lights rake across them; as they sweep, the
			# normal map shapes the shading and the polished (low-roughness) ridges throw
			# tight highlights the matte bone doesn't.
			_clear_props()
			_clear_lights()
			_spawn_skull_grid()
			_props_are_skulls = true
			var pbr_a := _spawn_light("point", Color(1.0, 0.9, 0.72))
			pbr_a.node.range = 520.0
			pbr_a.node.energy = 2.0
			pbr_a.base_energy = 2.0
			pbr_a.pulse_speed = 0.0
			pbr_a.hue = -1.0
			var pbr_b := _spawn_light("point", Color(0.7, 0.82, 1.0))
			pbr_b.node.range = 520.0
			pbr_b.node.energy = 1.6
			pbr_b.base_energy = 1.6
			pbr_b.pulse_speed = 0.0
			pbr_b.hue = -1.0
			pbr_b.phase = PI            # orbit opposite the warm light so detail is raked from both sides
		"fx_bloom":
			_ensure_count(8, ["point", "spot", "point", "dir"], true)   # thin out so the FX aren't blown out
			if _post:
				_post.bloom_threshold = 0.45
				_post.bloom_intensity = 1.1
				_post.bloom_radius = 4.0
				_post.visible = true
				_post.bloom_enabled = true
		"fx_halation":
			# Bloom stays on from the previous stage; layer fiery halation over it.
			if _post:
				_post.bloom_enabled = true
				_post.bloom_threshold = 0.42
				_post.bloom_intensity = 1.2
				_post.bloom_radius = 4.5
				_post.halation_threshold = 0.5
				_post.halation_intensity = 0.95
				_post.halation_radius = 6.0
				_post.halation_tint = Color(1.0, 0.3, 0.1)
				_post.visible = true
				_post.halation_enabled = true
		"fx_grade":
			if _post:
				_post.lut_preset = LitPostProcess.LutPreset.TEAL_ORANGE
				_post.contrast = 1.12
				_post.saturation = 1.2
				_post.visible = true
				_post.bloom_enabled = true
				_post.grade_enabled = true
				_post.lut_enabled = true
		"fx_crt":
			if _post:
				_post.visible = true
				_post.bloom_enabled = true
				_post.crt_enabled = true
		"fx_vhs":
			if _post:
				_post.visible = true
				_post.bloom_enabled = true
				_post.vhs_enabled = true
		"fx_glitch":
			if _post:
				_post.glitch_intensity = 0.5
				_post.visible = true
				_post.bloom_enabled = true
				_post.glitch_enabled = true
		"finale":
			_ensure_count(8, ["point", "spot", "point", "dir"], true)
			if _post:
				_post.visible = true
				_post.bloom_enabled = true


# Apply one shadow algorithm to every live demo light. The Shadow Algorithms section
# switches the whole set at once so the algorithm change itself is what reads on
# screen. The enum values are identical across the three light classes.
func _set_shadow_algorithm(algo: int) -> void:
	for d in _lights:
		if is_instance_valid(d.node):
			d.node.shadow_algorithm = algo


# Spawn kind for the cookie stage: cookies when the textures load, plain points otherwise.
func _cookie_kinds() -> Array:
	return ["cookie"] if _ensure_cookie_textures() else ["point"]


func _update_stage(t: float) -> void:
	# Ramping stages grow the light count over the first 75% of their duration.
	var s = _stages[_stage_index]
	var ramp_kinds: Array = []
	var ramp_max := 0
	if s.id == "stress":
		ramp_kinds = ["point", "spot", "point", "dir"]
		ramp_max = MAX_LIGHTS
	elif s.id == "cookies":
		ramp_kinds = _cookie_kinds()
		ramp_max = COOKIE_MAX_LIGHTS
	if ramp_max > 0:
		var frac: float = clampf(t / (s.dur * 0.75), 0.0, 1.0)
		var target := int(lerp(8.0, float(ramp_max), frac))
		if target != _lights.size():
			_ensure_count(target, ramp_kinds, true)


func _next_stage() -> void:
	if _stage_index + 1 < _stages.size():
		_enter_stage(_stage_index + 1)


func _on_skip() -> void:
	if _running:
		_next_stage()


# =====================================================================================
# Per-frame
# =====================================================================================

func _process(dt: float) -> void:
	_clock += dt
	_update_perf(dt)
	if not _running:
		return
	_update_lights()
	_stage_time += dt
	_update_stage(_stage_time)
	var s = _stages[_stage_index]
	if s.auto and _stage_time >= s.dur:
		_next_stage()


func _update_perf(dt: float) -> void:
	# Refresh the panel 5x/s with window-averaged render times.
	var vp_rid := get_viewport().get_viewport_rid()
	_perf_frames += 1
	_perf_cpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
	_perf_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
	_perf_accum += dt
	if _perf_accum < 0.2:
		return
	var fps := Engine.get_frames_per_second()
	var ms := 1000.0 / maxf(fps, 1.0)
	var cpu_ms := _perf_cpu_sum / float(_perf_frames)
	var gpu_ms := _perf_gpu_sum / float(_perf_frames)
	_perf_accum = 0.0
	_perf_frames = 0
	_perf_cpu_sum = 0.0
	_perf_gpu_sum = 0.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var light_count := _lights.size() if _running else _enabled_scene_lights()
	_perf_lbl.text = "FPS    %4d\nFrame  %6.2f ms\nCPU    %6.2f ms\nGPU    %6.2f ms\nLights %4d\nDraws  %5d" \
			% [int(round(fps)), ms, cpu_ms, gpu_ms, light_count, draws]


# Enabled, visible scene lights, for the perf panel outside a demo run.
func _enabled_scene_lights() -> int:
	var n := 0
	for l in get_tree().get_nodes_in_group("lit_lights"):
		if l.get("enabled") and l.is_visible_in_tree():
			n += 1
	return n
