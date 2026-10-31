extends Node2D

## Standalone Lit stress-test benchmark: instances the Test scene, strips the demo, and
## spawns LIGHT_COUNT deterministic (seeded) moving lights with full soft shadows.
## Warms up, measures, prints LITBENCH stats to stdout, and quits.
##
## Run fullscreen for true (uncapped) frame times:
##   godot --path . res://Test/StressTest.tscn --fullscreen

const RECEIVER_SHADER := preload("res://addons/lit/shaders/receiver/lit_receiver_fast.gdshader")

const SHADOW_ALGO_IDS := {"raymarch": 0, "cone": 1, "stochastic": 2}
const SHADOW_ALGO_NAMES := ["raymarch", "cone", "stochastic"]

enum ReceiverKind { SKULL, ANIMATED, STILL, SPRITE }
const RECEIVER_KIND_NAMES := ["skull", "animated", "still", "sprite"]
enum LayerMode { OFF, RANDOM, Z_PAIRS, Z_GRID, LAYER_PAIRS, LAYER_GRID }
const LAYER_MODE_NAMES := ["off", "random", "z_pairs", "z_grid", "layer_pairs", "layer_grid"]
const PAIR_MODES := ["z_pairs", "z_grid", "layer_pairs", "layer_grid"]

# Launch-time settings, editable on the scene's root node in the inspector. CLI args
# (after "--") override them, so scripted benchmark runs keep working. Future
# launch-time toggles for the benchmark belong in this group.
@export_group("Launch Options")
## Shadow algorithm every spawned light starts on; keys 1/2/3 still switch live
## (switching restarts the warmup/measure cycle).
@export var shadow_algorithm: LitPointLight2D.ShadowAlgorithm = LitPointLight2D.ShadowAlgorithm.RAYMARCHED
## Give every spawned light a random (seeded) shadow_length fraction, exercising the
## march cap + tip closure. Off by default so standing benchmarks stay comparable.
@export var randomize_shadow_length: bool = false
## Light-range filters at scale. Random: every occluder prop and scene receiver takes a
## random (seeded) z_index and canvas layer and every spawned light a random z / layer
## range. Z pairs: receiver_count receivers (the light count when unset) on a grid
## scaled to fit, each on its own z_index, and one light orbiting each receiver ranged
## to that z alone, so every light shades exactly one object. Layer pairs: the same with
## a CanvasLayer per receiver and layer ranges instead. Z grid and layer grid: those
## layouts with the filters off, their baselines. Off by default so standing benchmarks
## stay comparable.
@export var layer_mode: LayerMode = LayerMode.OFF
## What stands at the Test scene's Skeleton prop: the skull (LitSprite2D, as authored),
## the animated skeleton playing its turnaround, the same node with the turnaround
## stopped, or a LitSprite2D showing one frame of it over the same footprint occluder.
@export var skeleton: ReceiverKind = ReceiverKind.SKULL
## Extra receivers laid out in a grid over the scene, on top of the standing benchmark;
## 0 adds none. Run kinds at the same count to compare them.
@export_range(0, 1000) var receiver_count: int = 0
@export var receivers: ReceiverKind = ReceiverKind.SKULL
## Every spawned light becomes a LitLineLight2D (seeded length, colour and a slow
## spin) in place of the point / spot / directional mix: the line light's cost against
## the standing benchmark. Off by default so standing benchmarks stay comparable.
@export var line_lights: bool = false

# Deterministic shadow-source parameters for the cone/stochastic runs. The angle is a
# full angular diameter (source_angle convention), so this marches the same cone as
# the pre-convention-change 3.0 half-angle runs.
const SOURCE_RADIUS := 10.0
const SOURCE_ANGLE_DEG := 6.0
const SHADOW_SAMPLES := 8

const LIGHT_COUNT := 128
# Overrides for cost attribution, passed after "--" on the CLI:
#   shadows=off   kinds=point|spot|dir|cookie|line|mix   lights=N   warmup=N   measure=N
#   lines=on      every light a LitLineLight2D (seeded length 60..420 px, slow spin),
#     whatever kinds= says; kinds=point is its point-light baseline
#   linelen=N     every line light exactly N px long (0 = point-sized capsules: the
#     line code path at the point light's footprint)
#   linecurve=on  every line light bent into an S-curve (a Path2D child) spanning its
#     length: the curved path (arcs for the look, chords for the shadows);
#     linecurve=straight a 2-point straight path along the light's own segment
#   props=off     no prop occluders: the Test scene's own casters only (sparse scene)
#   linewall=N    an occluder wall N px behind every line light, riding with it (a
#     light bar on a wall: the gate's hardest case, every open-side pixel sees the wall)
#   shadow_algo=raymarch|cone|stochastic|mixed   sdf=25|50|100 (SDF scale probe)
#     mixed cycles the three algorithms across the spawned lights (launch only)
#   shadowlen=on   random (seeded) shadow_length fraction per light
#   texoffset=on   random (seeded) texture_offset on every cookie light
#   layers=random  random (seeded) z_index + canvas layer per occluder prop and scene
#     receiver, random z / layer range per light (the light-range filters at scale)
#   layers=z_pairs   receiver_count receivers (128 when unset) on a grid scaled to fit,
#     each on its own z_index; one light orbits each receiver ranged to that z alone,
#     so every light shades exactly one object (lights= follows receiver_count)
#   layers=layer_pairs   the same with a CanvasLayer per receiver and layer ranges
#   layers=z_grid | layer_grid   those layouts with the filters off (their baselines)
#   capture=PATH  render one deterministic frame after measuring, for pixel-diffing builds
#   post=Name,Name  add fresh default-state post effects (e.g. post=Bloom,AutoExposure)
#   skeleton=skull|animated|still|sprite   what stands at the Test scene's Skeleton prop
#   receivers=skull|animated|still|sprite receiver_count=N   a grid of N receivers over
#     the scene, on top of the standing benchmark. skull = Test/nodes/skeleton.tscn;
#     animated = skeleton_animated.tscn playing its turnaround; still = the same node
#     with the turnaround stopped; sprite = that scene with a LitSprite2D showing one
#     frame over the same footprint occluder. Run kinds at the same count. Default 0.
#   plain=on       pair-grid receivers as plain Sprite2D with no Lit material and no
#     footprint occluder, so the layer grids show Godot's own per-canvas cost apart from Lit's
#   rangecost=pass|layer|miss|mask   every light ranged to a z band every receiver passes
#     (pass), to a layer band every receiver passes (layer), to z 4096 so every receiver
#     rejects it (miss), or put on light_mask 2 so the mask test rejects it instead
#     (mask): the range tests' price against the mask test
#   precompile=api   run the worker-backed shader precompile during the measure window
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
var _opt_ysort := false
# masks=off|one|all|split|tilemap: mark one prop occluder (or all) with occluder mask 2.
# With no mask-2 light that exercises the global-exclusion tier; split also gives light 0
# shadow_mask 3 so the occluder still casts for it, exercising the per-light tier.
# tilemap puts every tileset occlusion layer on mask 2 (globally excluded tilemap case).
var _opt_masks := "off"
# maskcull=off: leave globally excluded occluders in the SDF (registry sdf_cull off,
# driven directly), so the gx shader tier runs instead of tier-1 culling.
var _opt_maskcull := "on"
# rxmask=N: shadow_ignore_mask N on every Lit tilemap receiver (rx cost probe).
var _opt_rxmask := 0
# rxnode=NAME: shadow_ignore_mask 1 on the named LitSprite2D (small-receiver probe).
var _opt_rxnode := ""
var _opt_post := ""
var _opt_shadowlen := false
var _opt_texoffset := false
var _opt_rangecost := ""
var _opt_plain := false
var _opt_layers := "off"
var _opt_skeleton := "skull"
var _opt_receivers := "skull"
var _opt_receiver_count := 0
# precompile=api: start LitManager.precompile_shaders() when measuring begins; the
# measure window then ends when the precompile finishes (measure=S is the timeout).
var _opt_precompile := ""
var _opt_lines := false
var _opt_linelen := -1.0
var _opt_linecurve := "off"
var _opt_props := true
var _opt_linewall := 0.0
var _pre_elapsed := -1.0
var _last_usec := 0

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
var _draw_calls: PackedFloat64Array = PackedFloat64Array()

var _hud: Label


func _ready() -> void:
	_opt_shadow_algo = SHADOW_ALGO_NAMES[shadow_algorithm]
	_opt_shadowlen = randomize_shadow_length
	_opt_layers = LAYER_MODE_NAMES[layer_mode]
	_opt_skeleton = RECEIVER_KIND_NAMES[skeleton]
	_opt_receivers = RECEIVER_KIND_NAMES[receivers]
	_opt_receiver_count = receiver_count
	_opt_lines = line_lights
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"shadows":
				_opt_shadows = kv[1] != "off"
			"kinds":
				_opt_kinds = ["point", "spot", "point", "dir"] if kv[1] == "mix" else Array(kv[1].split(","))
			"lights":
				_opt_light_count = int(kv[1])
			"shadow_algo":
				if SHADOW_ALGO_IDS.has(kv[1]) or kv[1] == "mixed":
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
			"ysort":
				_opt_ysort = kv[1] == "on"
			"masks":
				_opt_masks = kv[1]
			"maskcull":
				_opt_maskcull = kv[1]
			"rxmask":
				_opt_rxmask = int(kv[1])
			"rxnode":
				_opt_rxnode = kv[1]
			"post":
				_opt_post = kv[1]
			"shadowlen":
				_opt_shadowlen = kv[1] == "on"
			"texoffset":
				_opt_texoffset = kv[1] == "on"
			"rangecost":
				_opt_rangecost = kv[1]
			"plain":
				_opt_plain = kv[1] == "on"
			"layers":
				_opt_layers = "random" if kv[1] == "on" else kv[1]
			"receivers":
				_opt_receivers = kv[1]
			"receiver_count":
				_opt_receiver_count = int(kv[1])
			"skeleton":
				_opt_skeleton = kv[1]
			"precompile":
				_opt_precompile = kv[1]
			"lines":
				_opt_lines = kv[1] == "on"
			"linelen":
				_opt_linelen = float(kv[1])
			"linecurve":
				_opt_linecurve = kv[1]
			"props":
				_opt_props = kv[1] != "off"
			"linewall":
				_opt_linewall = float(kv[1])
	if _opt_lines:
		_opt_kinds = ["line"]
	# A startup takeover (lit/startup/precompile_shaders) is already running by now:
	# report how long the boot spent in it.
	var boot_pre: Node = get_node("/root/LitManager").precompiler
	if boot_pre != null and boot_pre.took_over and boot_pre.is_processing():
		boot_pre.finished.connect(func() -> void:
			print("LITBENCH boot_precompile_s=%.2f" % (float(Time.get_ticks_msec()) / 1000.0)))
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
		for c in post.get_children():
			if c is LitPostEffect:
				c.visible = false

	if _opt_post != "" and not _add_post_chain():
		get_tree().quit(1)
		return

	for occ in _find_all(scene, LightOccluder2D):
		occ.sdf_collision = false

	# Particles are nondeterministic; hide them so runs and captures are comparable.
	for part in _find_all(scene, GPUParticles2D):
		part.visible = false

	RenderingServer.global_shader_parameter_set("lit_lighting_model", LIT_MODEL_PHONG)

	# Driven directly: a runtime set_setting perturbs renderer state and skews numbers.
	if _opt_ysort:
		RenderingServer.global_shader_parameter_set("lit_ysort_enabled", true)
		RenderingServer.global_shader_parameter_set("lit_ysort_band", 12.0)
		get_node("/root/LitManager")._registry.set_ysort(true)
	if _opt_maskcull == "off":
		get_node("/root/LitManager")._registry.sdf_cull = false

	if _opt_skeleton != "skull" and not _swap_skeleton(scene):
		get_tree().quit(1)
		return
	_compute_area()
	if not LAYER_MODE_NAMES.has(_opt_layers):
		print("LITBENCH error layers must be one of %s, got '%s'" % [", ".join(LAYER_MODE_NAMES), _opt_layers])
		get_tree().quit(1)
		return
	var paired := PAIR_MODES.has(_opt_layers)
	if paired:
		if _opt_receiver_count == 0:
			_opt_receiver_count = LIGHT_COUNT
		_opt_light_count = _opt_receiver_count
	_rng.seed = RNG_SEED
	if _opt_props:
		_spawn_props()
	if _opt_receiver_count > 0 and not (_spawn_pair_grid() if paired else _spawn_receivers()):
		get_tree().quit(1)
		return
	if _opt_masks == "one" or _opt_masks == "split":
		_props[0].occ.occluder_light_mask = 2
	elif _opt_masks == "all":
		for p in _props:
			p.occ.occluder_light_mask = 2
	elif _opt_masks == "tilemap":
		for tml in _find_all(scene, TileMapLayer):
			var ts: TileSet = tml.tile_set
			if ts != null:
				for l in ts.get_occlusion_layers_count():
					ts.set_occlusion_layer_light_mask(l, 2)
	if _opt_rxmask != 0:
		for tml in _find_all(scene, TileMapLayer):
			if tml is LitTileMapLayer:
				tml.shadow_ignore_mask = _opt_rxmask
	if _opt_rxnode != "":
		var rx_target := scene.find_child(_opt_rxnode, true, false)
		if rx_target is LitSprite2D:
			rx_target.shadow_ignore_mask = 1
	for i in _opt_light_count:
		var kind: String = _opt_kinds[i % _opt_kinds.size()]
		_spawn_light(kind, Color.from_hsv(_rng.randf(), 0.85, 1.0))
	if _opt_masks == "split" and not _lights.is_empty():
		_lights[0].node.shadow_mask = 3
	for d in _lights:
		match _opt_rangecost:
			"pass":
				d.node.range_z_min = -4000
				d.node.range_z_max = 4000
			"layer":
				d.node.range_layer_min = -4000
				d.node.range_layer_max = 4000
			"miss":
				d.node.range_z_min = 4096
				d.node.range_z_max = 4096
			"mask":
				d.node.light_mask = 2
	# Own RNG stream: the main _rng draws stay identical to shadowlen=off runs, so the
	# fractions are the ONLY difference between the two configs.
	if _opt_shadowlen:
		var slrng := RandomNumberGenerator.new()
		slrng.seed = RNG_SEED + 1
		for d in _lights:
			d.node.shadow_length = slrng.randf_range(0.1, 0.9)
	# Own RNG stream, same reasoning as shadowlen above.
	if _opt_texoffset:
		var torng := RandomNumberGenerator.new()
		torng.seed = RNG_SEED + 2
		for d in _lights:
			if d.kind == "cookie":
				d.node.texture_offset = Vector2(
						torng.randf_range(-0.35, 0.35), torng.randf_range(-0.35, 0.35)) * d.node.range
	# Own RNG stream, same reasoning as shadowlen above.
	if _opt_layers == "random":
		_randomize_layers(scene)
	elif paired:
		_pair_lights(_opt_layers.ends_with("pairs"), _opt_layers.begins_with("layer_"))

	_state = "warmup"
	_state_time = 0.0


## post=CSV: fresh LitPostProcess with the named effects at default state, resolved
## against every LitPostEffect subclass ("Bloom" or "LitPostBloom", case-insensitive).
func _add_post_chain() -> bool:
	var classes := ProjectSettings.get_global_class_list()
	var by_name := {}
	for c in classes:
		by_name[String(c["class"])] = c
	var effects := {}
	for c in classes:
		var base := String(c["base"])
		while by_name.has(base) and base != "LitPostEffect":
			base = String(by_name[base]["base"])
		if base == "LitPostEffect":
			effects[String(c["class"]).to_lower().trim_prefix("litpost")] = String(c["path"])
	var post := LitPostProcess.new()
	for raw in _opt_post.split(","):
		var key := raw.strip_edges().to_lower().trim_prefix("litpost")
		if not effects.has(key):
			var valid := effects.keys()
			valid.sort()
			print("LITBENCH error unknown post effect '%s' (valid: %s)" % [raw.strip_edges(), ", ".join(valid)])
			return false
		post.add_effect((load(effects[key]) as Script).new())
	add_child(post)
	return true


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


# --- props: mirrors lit_demo.gd's layout. The demo's circle props moved to LitSprite2D
# (native self-exclusion); the bench deliberately keeps plain sprites + the fast shader
# so standing benchmark numbers stay comparable across runs. ------------------------

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
	mat.set_shader_parameter("self_shadow", true)
	spr.material = mat
	root.add_child(spr)

	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var hw := size.x * 0.5
	var hh := size.y * 0.5
	poly.polygon = PackedVector2Array([Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])
	occ.occluder = poly
	root.add_child(occ)

	_props.append({"root": root, "mat": mat, "occ": occ})


# --- receivers: skeleton= swaps the Test scene's Skeleton prop; receivers= lays out a
# grid of receivers on top of the standing benchmark. Kinds: skull = skeleton.tscn;
# animated = skeleton_animated.tscn playing its turnaround; still = the same node with
# the turnaround stopped; sprite = that scene with a LitSprite2D showing one frame over
# the same footprint occluder. ------------------------------------------------------

const SKULL_SCENE := "res://Test/nodes/skeleton.tscn"
const ANIMATED_SCENE := "res://Test/nodes/skeleton_animated.tscn"

func _swap_skeleton(scene: Node) -> bool:
	var skull := scene.get_node_or_null("Skeleton") as Node2D
	if skull == null or not RECEIVER_KIND_NAMES.has(_opt_skeleton):
		print("LITBENCH error skeleton must be one of %s, got '%s'" % [", ".join(RECEIVER_KIND_NAMES), _opt_skeleton])
		return false
	_add_receiver(_opt_skeleton, skull.position, 0, skull.get_parent())
	skull.queue_free()
	return true


func _spawn_receivers() -> bool:
	if not RECEIVER_KIND_NAMES.has(_opt_receivers):
		print("LITBENCH error receivers must be one of %s, got '%s'" % [", ".join(RECEIVER_KIND_NAMES), _opt_receivers])
		return false
	var cols := int(ceil(sqrt(float(_opt_receiver_count))))
	var rows := int(ceil(float(_opt_receiver_count) / float(cols)))
	var cell := Vector2(_area_half.x * 2.0 / float(cols + 1), _area_half.y * 2.0 / float(rows + 1))
	for i in _opt_receiver_count:
		@warning_ignore("integer_division")
		var row := i / cols
		_add_receiver(_opt_receivers, _area_center - _area_half
				+ Vector2(cell.x * float(i % cols + 1), cell.y * float(row + 1)), i, self)
	return true


func _add_receiver(kind: String, pos: Vector2, stagger: int, parent: Node) -> void:
	var packed := load(SKULL_SCENE if kind == "skull" else ANIMATED_SCENE) as PackedScene
	var node := packed.instantiate() as Node2D
	node.position = pos
	_added_receivers.append(node)
	# The scene's own lights stay off, like the Test scene's.
	for l in _find_all(node, LitPointLight2D):
		l.enabled = false
	var spr := _find_first(node, LitAnimatedSprite2D) as LitAnimatedSprite2D
	if spr == null:
		parent.add_child(node)
		return
	var frame := stagger % maxi(spr.sprite_frames.get_frame_count(spr.animation), 1)
	if kind == "sprite":
		var s := LitSprite2D.new()
		s.texture = spr.sprite_frames.get_frame_texture(spr.animation, frame)
		s.position = spr.position
		for occ in spr.get_children():
			spr.remove_child(occ)
			s.add_child(occ)
		node.remove_child(spr)
		spr.free()
		node.add_child(s)
		parent.add_child(node)
		return
	parent.add_child(node)
	# After ready, so autoplay has started; turnarounds start staggered.
	if kind == "still":
		spr.stop()
	spr.frame = frame


# --- layers: layers=random. Floor tilemaps take a z below everything else and stay on the
# base canvas; props and sprite receivers take a z at or above it plus a canvas layer
# (base or one of LAYER_COUNT viewport-following CanvasLayers), so draw order stays
# coherent while every light's random z / layer ranges reach a different subset. Prop
# receivers are hand-made (plain Sprite2D + the fast shader), so their pair is set on
# their own materials; the scene's Lit receivers derive theirs once refreshed. -------

const LAYER_COUNT := 3
const Z_SPAN := 3
const PAIR_FILL := 0.85
var _added_receivers: Array = []
var _pair_nodes: Array = []
var _pair_cell := Vector2.ZERO


func _randomize_layers(scene: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = RNG_SEED + 3
	var layers: Array = []
	for i in LAYER_COUNT:
		var cl := CanvasLayer.new()
		cl.layer = i + 1
		cl.follow_viewport_enabled = true
		add_child(cl)
		layers.append(cl)
	for p in _props:
		var z: int = rng.randi_range(0, Z_SPAN)
		var layer: int = rng.randi_range(0, LAYER_COUNT)
		p.root.z_index = z
		if layer > 0:
			p.root.reparent(layers[layer - 1])
		p.mat.set_shader_parameter("receiver_z", z)
		p.mat.set_shader_parameter("receiver_layer", layer)
	var targets: Array = []
	for node in scene.get_children():
		if node is TileMapLayer:
			node.z_index = rng.randi_range(-Z_SPAN, -1)
			LitLightRegistry.refresh_light_ranges(node)
		elif node is Node2D and _has_lit_receiver(node):
			targets.append(node)
	for node in _added_receivers:
		if is_instance_valid(node) and not targets.has(node):
			targets.append(node)
	for node in targets:
		node.z_index = rng.randi_range(0, Z_SPAN)
		var layer: int = rng.randi_range(0, LAYER_COUNT)
		if layer > 0:
			node.reparent(layers[layer - 1])
		LitLightRegistry.refresh_light_ranges(node)
	for d in _lights:
		var n = d.node
		n.range_z_min = rng.randi_range(-Z_SPAN, Z_SPAN)
		n.range_z_max = rng.randi_range(n.range_z_min, Z_SPAN)
		match rng.randi_range(0, 2):
			1:
				n.range_layer_min = 0
				n.range_layer_max = 0
			2:
				var k: int = rng.randi_range(1, LAYER_COUNT)
				n.range_layer_min = k
				n.range_layer_max = k


func _has_lit_receiver(node: Node) -> bool:
	if node is LitSprite2D or node is LitAnimatedSprite2D or node is LitTileMapLayer:
		return true
	for c in node.get_children():
		if _has_lit_receiver(c):
			return true
	return false


# layers=z_pairs / layer_pairs and their grids: receiver_count receivers on an
# edge-to-edge grid over the area, each scaled to PAIR_FILL of its cell, and light i
# orbiting receiver i. z_pairs puts receiver i on z_index i + 1 and ranges light i to
# that z alone; layer_pairs parents receiver i to its own viewport-following
# CanvasLayer i + 1 and ranges light i to that layer. Either way every light shades
# exactly one object and every receiver pixel rejects all other lights in the shader.
# The grids keep the same layout with the filters off as the matched baselines: the
# layer ones carry Godot's per-canvas cost and their footprint occluders sit outside
# the world SDF, so compare layer_pairs with layer_grid and z_pairs with z_grid. The
# standing scene stays on z 0 / the base canvas, below every band.
func _spawn_pair_grid() -> bool:
	if not RECEIVER_KIND_NAMES.has(_opt_receivers):
		print("LITBENCH error receivers must be one of %s, got '%s'" % [", ".join(RECEIVER_KIND_NAMES), _opt_receivers])
		return false
	var n := _opt_receiver_count
	var cols := int(ceil(sqrt(float(n) * _area_half.x / _area_half.y)))
	var rows := int(ceil(float(n) / float(cols)))
	_pair_cell = _area_half * 2.0 / Vector2(float(cols), float(rows))
	for i in n:
		@warning_ignore("integer_division")
		var pos := _area_center - _area_half \
				+ _pair_cell * (Vector2(float(i % cols), float(i / cols)) + Vector2(0.5, 0.5))
		var parent: Node = self
		if _opt_layers.begins_with("layer_"):
			var cl := CanvasLayer.new()
			cl.layer = i + 1
			cl.follow_viewport_enabled = true
			add_child(cl)
			parent = cl
		var before := _added_receivers.size()
		_add_receiver(_opt_receivers, pos, i, parent)
		var node: Node2D = _added_receivers[before]
		if _opt_plain:
			_strip_lit(node)
		node.scale *= minf(_pair_cell.x, _pair_cell.y) * PAIR_FILL / _footprint(node)
		_pair_nodes.append(node)
	return true


## plain=on: swap a receiver's Lit sprite for a plain Sprite2D with the same texture and
## placement and drop its footprint occluder, so the node draws through Godot's default
## canvas material and leaves the SDF alone.
func _strip_lit(node: Node2D) -> void:
	var spr := _find_first(node, Sprite2D) as Sprite2D
	if spr == null:
		return
	var plain := Sprite2D.new()
	plain.texture = spr.texture
	plain.position = spr.position
	plain.scale = spr.scale
	plain.offset = spr.offset
	for c in spr.get_children():
		spr.remove_child(c)
		if c is LightOccluder2D:
			c.free()
		else:
			plain.add_child(c)
	spr.get_parent().add_child(plain)
	spr.free()


## Largest side of a receiver's sprite in its parent's units, scale included.
func _footprint(node: Node2D) -> float:
	var size := Vector2.ONE * 32.0
	var spr := _find_first(node, Sprite2D) as Sprite2D
	var anim := _find_first(node, AnimatedSprite2D) as AnimatedSprite2D
	if spr != null:
		size = spr.get_rect().size * spr.scale
	elif anim != null:
		size = anim.sprite_frames.get_frame_texture(anim.animation, 0).get_size() * anim.scale
	return maxf(size.x, size.y) * maxf(node.scale.x, node.scale.y)


func _pair_lights(filter: bool, by_layer: bool) -> void:
	if filter and not by_layer:
		for i in _pair_nodes.size():
			_pair_nodes[i].z_index = i + 1
			LitLightRegistry.refresh_light_ranges(_pair_nodes[i])
	for i in _lights.size():
		var d: Dictionary = _lights[i]
		var slot := i % _pair_nodes.size()
		var node: Node2D = _pair_nodes[slot]
		d.center = node.position
		d.target = node.position
		d.rx = _pair_cell.x * 0.5
		d.ry = _pair_cell.y * 0.5
		if not filter:
			continue
		if by_layer:
			d.node.range_layer_min = slot + 1
			d.node.range_layer_max = slot + 1
		else:
			d.node.range_z_min = slot + 1
			d.node.range_z_max = slot + 1


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
		"line":
			n = LitLineLight2D.new()
			n.range = _rng.randf_range(220, 380)
			n.height = _rng.randf_range(12, 26)
			n.length = _rng.randf_range(60, 420)
			n.width = _rng.randf_range(0, 24)
			n.glow = _rng.randf_range(0.2, 1.0)
			if _opt_linelen >= 0.0:
				n.length = _opt_linelen
			if _opt_linecurve == "on" or _opt_linecurve == "straight":
				var path := Path2D.new()
				var curve := Curve2D.new()
				var h: float = n.length * 0.5
				if _opt_linecurve == "straight":
					curve.add_point(Vector2(-h, 0))
					curve.add_point(Vector2(h, 0))
				else:
					curve.add_point(Vector2(-h, 0), Vector2.ZERO, Vector2(h * 0.6, 0))
					curve.add_point(Vector2(0, h * 0.4), Vector2(-h * 0.25, -h * 0.25), Vector2(h * 0.25, h * 0.25))
					curve.add_point(Vector2(h, 0), Vector2(-h * 0.6, 0), Vector2.ZERO)
				path.curve = curve
				n.add_child(path)
			if _opt_linewall > 0.0:
				var wall := LightOccluder2D.new()
				var poly := OccluderPolygon2D.new()
				var hw: float = n.length * 0.5 + 20.0
				poly.polygon = PackedVector2Array([Vector2(-hw, 0), Vector2(hw, 0), Vector2(hw, 12), Vector2(-hw, 12)])
				wall.occluder = poly
				wall.position = Vector2(0, _opt_linewall)
				n.add_child(wall)
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
		"target": _area_center,
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
				n.rotation = (d.target - p).angle()
			elif d.kind == "line":
				n.rotation = d.phase + _clock * d.dir_speed
		if d.pulse_speed > 0.0:
			n.energy = d.base_energy * (0.72 + 0.28 * sin(_clock * d.pulse_speed + d.phase))
		if d.hue >= 0.0:
			n.color = Color.from_hsv(fposmod(d.hue + _clock * 0.05, 1.0), 0.85, 1.0)


# Apply the current shadow algorithm and its fixed source parameters to one light.
# Fixed values keep runs comparable across algorithms; cone/stochastic read hardness
# as a contrast remap, where 0.5 is neutral.
func _configure_shadow_algo(n, kind: String) -> void:
	var algo := _opt_shadow_algo
	if algo == "mixed":
		algo = SHADOW_ALGO_NAMES[_lights.size() % 3]
	n.shadow_algorithm = SHADOW_ALGO_IDS[algo]
	if algo == "raymarch":
		n.shadow_hardness = 0.0
	else:
		n.shadow_hardness = 0.5
		n.shadow_samples = SHADOW_SAMPLES
		n.shadow_jitter = 0.35
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
	_last_usec = 0
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
			_last_usec = 0
			if _opt_precompile == "api":
				var mgr := get_node("/root/LitManager")
				mgr.precompile_finished.connect(func() -> void: _pre_elapsed = _state_time)
				if not mgr.precompile_shaders():
					print("LITBENCH error precompile already running")
		return

	# measure
	# Frame times come from the wall clock: the engine caps dt at its physics catch-up
	# limit (about 133 ms), which would hide the length of any longer stall.
	var now := Time.get_ticks_usec()
	var wall := float(now - _last_usec) / 1000000.0 if _last_usec != 0 else dt
	_last_usec = now
	_state_time += wall - dt
	var vp_rid := get_viewport().get_viewport_rid()
	_frame_times.append(wall)
	_process_times.append(Performance.get_monitor(Performance.TIME_PROCESS))
	_render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
	_render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
	_draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_hud.text = "MEASURE %.1f / %.1f s   lights %d   algo %s   fps %d" % [_state_time, _opt_measure, _lights.size(), _opt_shadow_algo, Engine.get_frames_per_second()]
	if _state_time >= _opt_measure or _pre_elapsed >= 0.0:
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

	var stall := 0
	var hitch := 0
	var smooth := 0
	var worst := 0.0
	var smooth_time := 0.0
	for t in _frame_times:
		worst = maxf(worst, t)
		if t > 0.1:
			stall += 1
		elif t > 0.025:
			hitch += 1
		else:
			smooth += 1
			smooth_time += t
	print("LITBENCH histo stall100=%d hitch25=%d smooth=%d worst_ms=%.1f smooth_share=%.2f"
			% [stall, hitch, smooth, worst * 1000.0, smooth_time / total])

	if _opt_precompile != "":
		print("LITBENCH precompile=%s finished=%s elapsed_s=%.2f" % [_opt_precompile,
				"yes" if _pre_elapsed >= 0.0 else "no", _pre_elapsed if _pre_elapsed >= 0.0 else total])
	print("LITBENCH shadow_algo=%s" % _opt_shadow_algo)
	print("LITBENCH shadowlen=%s" % ("on" if _opt_shadowlen else "off"))
	print("LITBENCH layers=%s" % _opt_layers)
	print("LITBENCH post=%s" % (_opt_post if _opt_post != "" else "off"))
	print("LITBENCH skeleton=%s" % _opt_skeleton)
	print("LITBENCH kinds=%s lines=%s linelen=%s" % [",".join(_opt_kinds), "on" if _opt_lines else "off",
			("%.0f" % _opt_linelen) if _opt_linelen >= 0.0 else "random"])
	if _opt_rangecost != "":
		print("LITBENCH rangecost=%s" % _opt_rangecost)
	if not _opt_props:
		print("LITBENCH props=off")
	if _opt_linewall > 0.0:
		print("LITBENCH linewall=%.0f" % _opt_linewall)
	if _opt_linecurve != "off":
		print("LITBENCH linecurve=%s" % _opt_linecurve)
	if _opt_plain:
		print("LITBENCH plain=on")
	if _opt_receiver_count > 0:
		print("LITBENCH receivers=%s receiver_count=%d" % [_opt_receivers, _opt_receiver_count])
	print("LITBENCH frames=%d" % n)
	print("LITBENCH avg_fps=%.2f" % fps)
	print("LITBENCH avg_frame_ms=%.3f" % avg_ms)
	print("LITBENCH low1pct_frame_ms=%.3f (%.1f fps)" % [low1_ms, 1000.0 / low1_ms])
	print("LITBENCH main_process_ms=%.3f" % proc_ms)
	print("LITBENCH render_cpu_ms=%.3f" % rcpu_ms)
	print("LITBENCH render_gpu_ms=%.3f" % rgpu_ms)
	print("LITBENCH draw_calls=%.0f" % _mean(_draw_calls))
	print("LITBENCH viewport=%s screen=%s" % [get_viewport_rect().size, DisplayServer.screen_get_size()])


func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / float(a.size())
