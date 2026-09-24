extends Node2D
## Renders an integration test scene at 1920x1080 (one pixel per canvas unit), saves one
## frame and quits. Options after "--":
##   scene=res://PATH   out=PATH   frames=N (default 8)   algo=raymarch|cone|stochastic

const ALGO_IDS := {"raymarch": 0, "cone": 1, "stochastic": 2}

var _scene := "res://Test/integration_tests/shadow_ramp/shadow_ramp_integration_test.tscn"
var _out := "user://integration_capture.png"
var _frames := 8
var _algo := -1


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"scene":
				_scene = kv[1]
			"out":
				_out = kv[1]
			"frames":
				_frames = int(kv[1])
			"algo":
				_algo = ALGO_IDS.get(kv[1], -1)
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.content_scale_size = Vector2i(1920, 1080)
	win.content_scale_factor = 1.0
	var root: Node = load(_scene).instantiate()
	add_child(root)
	if _algo >= 0:
		for n in root.find_children("*", "LitPointLight2D", true, false):
			n.shadow_algorithm = _algo
	_capture.call_deferred()


func _capture() -> void:
	var mgr := get_node_or_null("/root/LitManager")
	if mgr != null and mgr.precompiler != null:
		if mgr.precompiler.is_processing():
			await mgr.precompiler.finished
		while get_tree().root.get_node_or_null("LitPrecompileOverlay") != null:
			await RenderingServer.frame_post_draw
	for i in _frames:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out)
	print("INTEGRATION CAPTURE scene=%s algo=%d saved=%s" % [_scene, _algo, _out])
	get_tree().quit()
