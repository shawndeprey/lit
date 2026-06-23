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
## scene. All demo lights run full soft shadows (shadow_hardness = 0).

const RECEIVER_SHADER := preload("res://addons/lit/shaders/lit_receiver.gdshader")

const MAX_LIGHTS := 128
const PROP_COUNT := 7
const BRAND := Color("#ffca60")

# --- runtime state ---
var _running := false
var _stage_index := -1
var _stage_time := 0.0
var _clock := 0.0
var _perf_accum := 0.0

var _white_tex: ImageTexture
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
var _occluders: Array = []       # pre-existing scene occluders, disabled during the demo

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
	{"id": "colors",    "name": "Many Colored Lights",       "desc": "Mixed types, every color, all moving", "dur": 6.0,  "auto": true},
	{"id": "shadows",   "name": "Layered Soft Shadows",      "desc": "Overlapping casters, all real-time",   "dur": 6.0,  "auto": true},
	{"id": "negative",  "name": "Negative Lights",           "desc": "Subtract mode carves darkness",        "dur": 5.0,  "auto": true},
	{"id": "masks",     "name": "Light Masks",               "desc": "Lights only touch matching objects",   "dur": 5.5,  "auto": true},
	{"id": "stress",    "name": "Stress Test",               "desc": "Ramping up to 128 lights…",            "dur": 14.0, "auto": true},
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
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_white_tex = ImageTexture.create_from_image(img)
	_build_ui()
	_set_ui_state("idle")


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 128                        # above the post-process pass layers, so the HUD stays crisp
	add_child(_ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(root)

	_perf_lbl = _make_label(root, 18, Color(0.6, 1.0, 0.7), HORIZONTAL_ALIGNMENT_LEFT)
	_set_rect(_perf_lbl, 0, 0, 0, 0, 16, 14, 250, 150)

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


func _make_label(parent: Control, size: int, color: Color, align: int) -> Label:
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
	_perf_lbl.visible = running


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
	for o in _occluders:
		if is_instance_valid(o.node):
			o.node.sdf_collision = o.sdf
	_occluders.clear()


func _capture_scene_state() -> void:
	# The lights already in the scene are the originals; capture before we spawn any.
	_orig_lights = get_tree().get_nodes_in_group("lit_lights").duplicate()
	for l in _orig_lights:
		l.enabled = false

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

	# Pre-existing scene occluders (e.g. the skull's LightOccluder2D) fight the demo's
	# own shadows, so drop them from the SDF while the demo runs and restore on stop.
	_occluders.clear()
	for occ in _find_all(scene, LightOccluder2D):
		_occluders.append({"node": occ, "sdf": occ.sdf_collision})
		occ.sdf_collision = false


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
		var size := Vector2(randf_range(74, 128), randf_range(74, 150))
		_make_prop(pos, size)


func _make_prop(pos: Vector2, size: Vector2) -> void:
	var root := Node2D.new()
	root.position = pos
	add_child(root)

	var spr := Sprite2D.new()
	spr.texture = _white_tex
	spr.scale = size                       # scale the 1x1 white tex to a size.x by size.y block
	spr.modulate = Color(0.82, 0.84, 0.92)
	var mat := ShaderMaterial.new()
	mat.shader = RECEIVER_SHADER
	spr.material = mat
	root.add_child(spr)

	var occ := LightOccluder2D.new()       # sdf_collision defaults true, so it feeds the SDF
	var poly := OccluderPolygon2D.new()
	var hw := size.x * 0.5
	var hh := size.y * 0.5
	poly.polygon = PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])
	occ.occluder = poly
	root.add_child(occ)

	_props.append({"root": root, "mat": mat})


func _clear_props() -> void:
	for p in _props:
		if is_instance_valid(p.root):
			p.root.queue_free()
	_props.clear()


# =====================================================================================
# Lights
# =====================================================================================

func _spawn_light(kind: String, col: Color, hue_cycle := false) -> Dictionary:
	var n
	match kind:
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
	n.shadow_hardness = 0.0                # full soft shadows, always
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


func _update_stage(t: float) -> void:
	if _stages[_stage_index].id == "stress":
		var s = _stages[_stage_index]
		var frac: float = clampf(t / (s.dur * 0.75), 0.0, 1.0)
		var target := int(lerp(8.0, float(MAX_LIGHTS), frac))
		if target != _lights.size():
			_ensure_count(target, ["point", "spot", "point", "dir"], true)


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
	_perf_accum += dt
	if _perf_accum < 0.2:
		return
	_perf_accum = 0.0
	var fps := Engine.get_frames_per_second()
	var ms := 1000.0 / maxf(fps, 1.0)
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_perf_lbl.text = "FPS    %4d\nFrame  %5.1f ms\nLights %4d\nDraws  %5d" % [int(round(fps)), ms, _lights.size(), draws]
