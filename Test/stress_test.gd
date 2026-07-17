extends Node2D

## Standalone Lit stress-test benchmark: instances the Test scene, strips the demo, and
## spawns LIGHT_COUNT deterministic (seeded) moving lights with full soft shadows.
## Warms up, measures, prints LITBENCH stats to stdout, and quits.
##
## Run fullscreen for true (uncapped) frame times:
##   godot --path . res://Test/StressTest.tscn --fullscreen

const RECEIVER_SHADER := preload("res://addons/lit/shaders/lit_receiver_fast.gdshader")

const SHADOW_ALGO_IDS := {"raymarch": 0, "cone": 1, "stochastic": 2}
const SHADOW_ALGO_NAMES := ["raymarch", "cone", "stochastic"]

# Launch-time settings, editable on the scene's root node in the inspector. CLI args
# (after "--") override them, so scripted benchmark runs keep working. Future
# launch-time toggles for the benchmark belong in this group.
@export_group("Launch Options")
## Shadow algorithm every spawned light starts on; keys 1/2/3 still switch live
## (switching restarts the warmup/measure cycle).
@export var shadow_algorithm: LitPointLight2D.ShadowAlgorithm = LitPointLight2D.ShadowAlgorithm.RAYMARCHED

# Deterministic shadow-source parameters for the cone/stochastic runs. The angle is a
# full angular diameter (source_angle convention), so this marches the same cone as
# the pre-convention-change 3.0 half-angle runs.
const SOURCE_RADIUS := 10.0
const SOURCE_ANGLE_DEG := 6.0
const SHADOW_SAMPLES := 8

const LIGHT_COUNT := 128
# Overrides for cost attribution, passed after "--" on the CLI:
#   shadows=off   kinds=point|spot|dir|cookie|mix   lights=N   warmup=N   measure=N
#   shadow_algo=raymarch|cone|stochastic   sdf=25|50|100 (SDF scale probe)
#   capture=PATH  render one deterministic frame after measuring, for pixel-diffing builds
# The shadow algorithm can also be switched live with keys 1 (raymarch), 2 (cone),
# 3 (stochastic); switching restarts the warmup/measure cycle so the reported numbers
# always describe a single algorithm. Receiver shaders follow via the registry's
# automatic variant swap, the same path a game uses.
var _opt_shadows := true
var _opt_kinds := ["point", "spot", "point", "dir"]
var _opt_light_count := LIGHT_COUNT
var _opt_capture := ""
var _opt_warmup := WARMUP_SEC
var _opt_measure := MEASURE_SEC
var _opt_shadow_algo := "raymarch"

# Clock value used for the deterministic capture frame.
const CAPTURE_CLOCK := 60.0
const PROP_COUNT := 7
const RNG_SEED := 0xC0FFEE
const WARMUP_SEC := 3.0
const MEASURE_SEC := 10.0

const LIT_MODEL_PHONG := 0

var _rng := RandomNumberGenerator.new()
var _white_tex: ImageTexture
var _area_center := Vector2(576, 324)
var _area_half := Vector2(560, 320)

var _lights: Array = []
var _props: Array = []

var _clock := 0.0
var _state := "boot"        # boot -> warmup -> measure -> done
var _state_time := 0.0
var _frame_times: PackedFloat64Array = PackedFloat64Array()
var _process_times: PackedFloat64Array = PackedFloat64Array()
var _render_cpu: PackedFloat64Array = PackedFloat64Array()
var _render_gpu: PackedFloat64Array = PackedFloat64Array()

var _hud: Label


func _ready() -> void:
	_opt_shadow_algo = SHADOW_ALGO_NAMES[shadow_algorithm]
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"shadows":
				_opt_shadows = kv[1] != "off"
			"kinds":
				_opt_kinds = ["point", "spot", "point", "dir"] if kv[1] == "mix" else [kv[1]]
			"lights":
				_opt_light_count = int(kv[1])
			"shadow_algo":
				if SHADOW_ALGO_IDS.has(kv[1]):
					_opt_shadow_algo = kv[1]
			"capture":
				_opt_capture = kv[1]
			"warmup":
				_opt_warmup = float(kv[1])
			"sdf":
				# Changes shadow fidelity: attribution only, never for A/B comparison.
				var scales := {100: RenderingServer.VIEWPORT_SDF_SCALE_100_PERCENT,
						50: RenderingServer.VIEWPORT_SDF_SCALE_50_PERCENT,
						25: RenderingServer.VIEWPORT_SDF_SCALE_25_PERCENT}
				if scales.has(int(kv[1])):
					RenderingServer.viewport_set_sdf_oversize_and_scale.call_deferred(
							get_viewport().get_viewport_rid(),
							RenderingServer.VIEWPORT_SDF_OVERSIZE_120_PERCENT,
							scales[int(kv[1])])
			"measure":
				_opt_measure = float(kv[1])
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_white_tex = ImageTexture.create_from_image(img)

	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var ui := CanvasLayer.new()
	ui.layer = 128
	add_child(ui)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hud.add_theme_constant_override("outline_size", 6)
	_hud.position = Vector2(16, 14)
	ui.add_child(_hud)

	# Let the instanced Test scene finish its _ready chain before we mutate it.
	_setup.call_deferred()


func _setup() -> void:
	# Drop the interactive demo node so its UI/buttons never appear.
	var demo := get_node_or_null("Test/LitDemo")
	if demo:
		demo.queue_free()

	# Mirror lit_demo.gd's stress-stage scene state.
	for l in get_tree().get_nodes_in_group("lit_lights"):
		l.enabled = false

	var scene := get_node("Test")
	var canvas_modulate := _find_first(scene, LitCanvasModulate)
	if canvas_modulate:
		canvas_modulate.color = Color(0.02, 0.02, 0.03)

	var post := _find_first(scene, LitPostProcess)
	if post:
		post.visible = false
		for k in ["bloom_enabled", "grade_enabled", "lut_enabled", "crt_enabled", "vhs_enabled", "glitch_enabled"]:
			post.set(k, false)

	for occ in _find_all(scene, LightOccluder2D):
		occ.sdf_collision = false

	# Particles are nondeterministic; hide them so runs and captures are comparable.
	for part in _find_all(scene, GPUParticles2D):
		part.visible = false

	RenderingServer.global_shader_parameter_set("lit_lighting_model", LIT_MODEL_PHONG)

	_compute_area()
	_rng.seed = RNG_SEED
	_spawn_props()
	for i in _opt_light_count:
		var kind: String = _opt_kinds[i % _opt_kinds.size()]
		_spawn_light(kind, Color.from_hsv(_rng.randf(), 0.85, 1.0))

	_state = "warmup"
	_state_time = 0.0


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


# --- props: identical construction to lit_demo.gd -----------------------------------

func _spawn_props() -> void:
	for i in PROP_COUNT:
		var ang := TAU * float(i) / float(PROP_COUNT)
		var pos := _area_center + Vector2(cos(ang) * _area_half.x * 0.55, sin(ang) * _area_half.y * 0.55)
		var size := Vector2(_rng.randf_range(74, 128), _rng.randf_range(74, 150))
		_make_prop(pos, size)


func _make_prop(pos: Vector2, size: Vector2) -> void:
	var root := Node2D.new()
	root.position = pos
	add_child(root)

	var spr := Sprite2D.new()
	spr.texture = _white_tex
	spr.scale = size
	spr.modulate = Color(0.82, 0.84, 0.92)
	var mat := ShaderMaterial.new()
	mat.shader = RECEIVER_SHADER
	spr.material = mat
	root.add_child(spr)

	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var hw := size.x * 0.5
	var hh := size.y * 0.5
	poly.polygon = PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])
	occ.occluder = poly
	root.add_child(occ)

	_props.append({"root": root, "mat": mat})


# --- lights: identical construction/motion to lit_demo.gd ---------------------------

const COOKIE_DIR := "res://Test/textures/cookies/"
const COOKIE_FILES := [
	"cookie_window.png", "cookie_blinds.png", "cookie_canopy.png",
	"cookie_flashlight.png", "cookie_soft_radial.png",
]
var _cookie_textures: Array = []


func _spawn_light(kind: String, col: Color) -> void:
	var n
	match kind:
		"cookie":
			if _cookie_textures.is_empty():
				for f in COOKIE_FILES:
					if ResourceLoader.exists(COOKIE_DIR + f):
						_cookie_textures.append(load(COOKIE_DIR + f))
			n = LitPointLight2D.new()
			n.range = _rng.randf_range(220, 380)
			n.height = _rng.randf_range(12, 26)
			n.falloff = 0.0
			n.texture = _cookie_textures[_rng.randi() % _cookie_textures.size()]
			n.texture_size_mode = LitPointLight2D.TextureSizeMode.FIT_RANGE
			n.texture_scale = _rng.randf_range(0.72, 1.0)
		"spot":
			n = LitSpotLight2D.new()
			n.range = _rng.randf_range(280, 460)
			n.spot_angle = _rng.randf_range(18, 42)
			n.spot_softness = _rng.randf_range(0.45, 0.95)
			n.height = _rng.randf_range(20, 60)
		"dir":
			n = LitDirectionalLight2D.new()
			n.height = _rng.randf_range(10, 22)
		_:
			n = LitPointLight2D.new()
			n.range = _rng.randf_range(220, 380)
			n.height = _rng.randf_range(12, 26)
	n.color = col
	n.energy = _rng.randf_range(1.3, 2.4)
	n.shadow_enabled = _opt_shadows
	_configure_shadow_algo(n, kind)
	add_child(n)

	_lights.append({
		"node": n, "kind": kind, "base_energy": n.energy,
		"center": _area_center + Vector2(_rng.randf_range(-_area_half.x * 0.18, _area_half.x * 0.18), _rng.randf_range(-_area_half.y * 0.18, _area_half.y * 0.18)),
		"rx": _rng.randf_range(_area_half.x * 0.30, _area_half.x * 0.88),
		"ry": _rng.randf_range(_area_half.y * 0.30, _area_half.y * 0.88),
		"speed": _rng.randf_range(0.25, 0.9) * (1.0 if _rng.randf() > 0.5 else -1.0),
		"phase": _rng.randf() * TAU,
		"pulse_speed": (_rng.randf_range(1.5, 3.5) if _rng.randf() > 0.45 else 0.0),
		"hue": _rng.randf(),
		"dir_speed": _rng.randf_range(0.15, 0.4) * (1.0 if _rng.randf() > 0.5 else -1.0),
	})


func _update_lights() -> void:
	for d in _lights:
		var n = d.node
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


# Apply the current shadow algorithm and its fixed source parameters to one light.
# Fixed values keep runs comparable across algorithms; cone/stochastic read hardness
# as a contrast remap, where 0.5 is neutral.
func _configure_shadow_algo(n, kind: String) -> void:
	n.shadow_algorithm = SHADOW_ALGO_IDS[_opt_shadow_algo]
	if _opt_shadow_algo == "raymarch":
		n.shadow_hardness = 0.0
	else:
		n.shadow_hardness = 0.5
		n.shadow_samples = SHADOW_SAMPLES
		n.shadow_jitter = 1.0
		if kind == "dir":
			n.source_angle = SOURCE_ANGLE_DEG
		else:
			n.source_radius = SOURCE_RADIUS


# --- benchmark loop ------------------------------------------------------------------

## Live algorithm switch: 1 = raymarch, 2 = cone, 3 = stochastic. Restarts the
## warmup/measure cycle so the reported numbers describe a single algorithm.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var algo := ""
	match key.keycode:
		KEY_1:
			algo = "raymarch"
		KEY_2:
			algo = "cone"
		KEY_3:
			algo = "stochastic"
		_:
			return
	if algo == _opt_shadow_algo or _state == "boot" or _state == "done":
		return
	_opt_shadow_algo = algo
	for d in _lights:
		_configure_shadow_algo(d.node, d.kind)
	_state = "warmup"
	_state_time = 0.0
	_frame_times.clear()
	_process_times.clear()
	_render_cpu.clear()
	_render_gpu.clear()


func _process(dt: float) -> void:
	if _state == "boot" or _state == "done":
		return
	_clock += dt
	_update_lights()
	_state_time += dt

	if _state == "warmup":
		_hud.text = "WARMUP %.1f / %.1f s   lights %d   algo %s   [1] raymarch [2] cone [3] stochastic" % [_state_time, _opt_warmup, _lights.size(), _opt_shadow_algo]
		if _state_time >= _opt_warmup:
			_state = "measure"
			_state_time = 0.0
		return

	# measure
	var vp_rid := get_viewport().get_viewport_rid()
	_frame_times.append(dt)
	_process_times.append(Performance.get_monitor(Performance.TIME_PROCESS))
	_render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
	_render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
	_hud.text = "MEASURE %.1f / %.1f s   lights %d   algo %s   fps %d" % [_state_time, _opt_measure, _lights.size(), _opt_shadow_algo, Engine.get_frames_per_second()]
	if _state_time >= _opt_measure:
		_state = "done"
		_report()
		if _opt_capture != "":
			_capture_and_quit()
		else:
			get_tree().quit()


## Render one deterministic frame (fixed clock, seeded params) and save it for
## pixel-diffing builds.
func _capture_and_quit() -> void:
	_clock = CAPTURE_CLOCK
	_update_lights()
	_hud.visible = false
	# Two frames: the registry repacks from the fixed state, then the result presents.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_opt_capture)
	print("LITBENCH capture=%s" % _opt_capture)
	get_tree().quit()


func _report() -> void:
	var n := _frame_times.size()
	var total := 0.0
	for t in _frame_times:
		total += t
	var avg_ms := total / float(n) * 1000.0
	var fps := float(n) / total

	var sorted := _frame_times.duplicate()
	sorted.sort()
	var worst_n := maxi(int(float(n) * 0.01), 1)
	var worst_sum := 0.0
	for i in worst_n:
		worst_sum += sorted[n - 1 - i]
	var low1_ms := worst_sum / float(worst_n) * 1000.0

	var proc_ms := _mean(_process_times) * 1000.0
	var rcpu_ms := _mean(_render_cpu)
	var rgpu_ms := _mean(_render_gpu)

	print("LITBENCH shadow_algo=%s" % _opt_shadow_algo)
	print("LITBENCH frames=%d" % n)
	print("LITBENCH avg_fps=%.2f" % fps)
	print("LITBENCH avg_frame_ms=%.3f" % avg_ms)
	print("LITBENCH low1pct_frame_ms=%.3f (%.1f fps)" % [low1_ms, 1000.0 / low1_ms])
	print("LITBENCH main_process_ms=%.3f" % proc_ms)
	print("LITBENCH render_cpu_ms=%.3f" % rcpu_ms)
	print("LITBENCH render_gpu_ms=%.3f" % rgpu_ms)
	print("LITBENCH viewport=%s screen=%s" % [get_viewport_rect().size, DisplayServer.screen_get_size()])


func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / float(a.size())
