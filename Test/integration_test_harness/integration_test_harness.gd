extends Node

## One launch to eyeball every integration scene: a tile menu loads each scene on
## click and a Back button returns to the menu. `-- thumbs=on` instead visits every
## scene, saves a 256-wide thumbnail into thumbnails/ and quits (`thumbs_wait=SECONDS`
## sets how long each scene settles first, `thumbs_shot=PATH` also saves a screenshot of
## the menu). The arg names stay clear of the scenes' own (capture=, demo=, bench=).

const THUMB_DIR := "res://Test/integration_test_harness/thumbnails/"
const THUMB_WIDTH := 256
const MENU := preload("res://Test/integration_test_harness/harness_menu.tscn")
const SCENES: Array[Dictionary] = [
	{"name": "Old Showcase", "scene": "res://Test/Test.tscn"},
	{"name": "Edge Polygon", "scene": "res://Test/integration_tests/edge_polygon/edge_polygon.tscn"},
	{"name": "Range Demo", "scene": "res://Test/integration_tests/light_range_test/range_demo.tscn"},
	{"name": "Line Arcs", "scene": "res://Test/integration_tests/line_light_test/line_light_arc_test.tscn"},
	{"name": "Line Closing", "scene": "res://Test/integration_tests/line_light_test/line_light_closing_test.tscn"},
	{"name": "Line Showcase", "scene": "res://Test/integration_tests/line_light_test/line_light_test.tscn"},
	{"name": "Lofi Viewport", "scene": "res://Test/integration_tests/pixelated_scene/low_res_scene.tscn"},
	{"name": "Shadow Length", "scene": "res://Test/integration_tests/shadow_length_test/shadow_length_test.tscn"},
	{"name": "Shadow Ramp", "scene": "res://Test/integration_tests/shadow_ramp/shadow_ramp_integration_test.tscn"},
	{"name": "Shadow Types", "scene": "res://Test/integration_tests/shadow_type_test/shadow_type_test.tscn"},
	{"name": "Stencil Buffer", "scene": "res://Test/integration_tests/stencil_buffer/stencil_buffer.tscn"},
	{"name": "Custom Shaders", "scene": "res://Test/misc/post-runtime-examples/post_runtime_examples.tscn"},
	{"name": "Auto Exposure", "scene": "res://Test/misc/auto_exposure.tscn"},
	{"name": "Get Luminance", "scene": "res://Test/misc/get_luminance.tscn"},
	{"name": "Normal Rotation", "scene": "res://Test/misc/normal_map_rotation.tscn"},
]

@onready var _back: Button = $BackLayer/Back
@onready var _stats: Label = $BackLayer/Stats

var _menu: Control
var _scene: Node
var _done := {}
var _capture := false
var _wait := 2.0
var _shot := ""

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "thumbs=on":
			_capture = true
		elif arg.begins_with("thumbs_wait="):
			_wait = maxf(float(arg.substr(12)), 0.1)
		elif arg.begins_with("thumbs_shot="):
			_shot = arg.substr(12)
	_back.pressed.connect(_show_menu)
	$BackLayer/StatsBtn.pressed.connect(_stats.toggle)
	_show_menu()
	if _capture:
		_capture_all()

func _show_menu() -> void:
	_unload_scene()
	_back.visible = false
	_menu = MENU.instantiate()
	add_child(_menu)
	_menu.build(_entries())
	_menu.selected.connect(_open)

func _open(entry: Dictionary) -> void:
	_unload_scene()
	if _menu:
		remove_child(_menu)
		_menu.queue_free()
		_menu = null
	_done[entry.scene] = true
	_scene = (load(entry.scene) as PackedScene).instantiate()
	add_child(_scene)
	_back.visible = not _capture

func _unload_scene() -> void:
	if _scene == null:
		return
	remove_child(_scene)
	_scene.queue_free()
	_scene = null
	# Scenes leave their camera transform and cull mask behind on the shared viewport.
	var vp := get_viewport()
	vp.canvas_transform = Transform2D()
	vp.global_canvas_transform = Transform2D()
	vp.canvas_cull_mask = 0xFFFFFFFF

func _entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in SCENES:
		var e := s.duplicate()
		var thumb := _thumb_path(s.scene)
		e["thumb"] = load(thumb) if ResourceLoader.exists(thumb) else null
		e["done"] = _done.has(s.scene)
		out.append(e)
	return out

func _thumb_path(scene: String) -> String:
	return THUMB_DIR + scene.get_file().get_basename() + ".png"

func _capture_all() -> void:
	DirAccess.make_dir_recursive_absolute(THUMB_DIR)
	# Mouse-driven scenes (edge polygon, stencil buffer) put their light under the cursor.
	Input.warp_mouse(get_viewport().get_visible_rect().size * 0.5)
	if _shot != "":
		await get_tree().create_timer(_wait).timeout
		_grab().save_png(_shot)
		print("HARNESS shot=%s" % _shot)
	_stats.visible = false
	$BackLayer/StatsBtn.visible = false
	for s in SCENES:
		_open(s)
		await get_tree().create_timer(_wait).timeout
		var img := _grab()
		img.resize(THUMB_WIDTH, roundi(THUMB_WIDTH * float(img.get_height()) / float(img.get_width())),
				Image.INTERPOLATE_LANCZOS)
		var path := _thumb_path(s.scene)
		img.save_png(path)
		print("HARNESS thumbnail=%s" % path)
	_unload_scene()
	get_tree().quit()

func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img
