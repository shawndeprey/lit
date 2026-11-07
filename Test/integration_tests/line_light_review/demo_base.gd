extends "res://Test/integration_tests/line_light_review/checks/review_section.gd"

## Base for the narrated walkthrough scenes in this folder (one per review issue).
##
## Each demo is a sequence of steps. A caption at the bottom says what you are looking at
## and what to watch for; panels are tagged EXPECTED (the correct behaviour, from a
## reference setup) or ACTUAL (BUG); changes are shown as BEFORE -> AFTER and the key
## motion is slowed down. Steps advance on their own.
##
## Keys: Space pause / resume   Right / Left next / previous step   R restart
##       1 2 3 4 speed 0.5x 1x 2x 4x   Esc quit
## Command line (after "--"): speed=N   shots=DIR (a PNG at the middle and end of every
## step)   quit=on (quit after the last step)

const C_EXPECTED := Color(0.36, 0.9, 0.45)
const C_ACTUAL := Color(1.0, 0.36, 0.3)
const C_NOTE := Color(1.0, 0.84, 0.25)
const C_TEXT := Color(0.92, 0.92, 0.95)
const C_DIM := Color(0.62, 0.64, 0.7)
const STAGE := Rect2(20, 64, 1880, 800)
const CAPTION_TOP := 874.0

var _steps: Array = []
var _cur := -1
var _t := 0.0
var _paused := false
var _speed := 1.0
var _opt_shots := ""
var _opt_quit_end := false
var _mid_shot := false
var _ui: CanvasLayer
var _title_lbl: Label
var _step_lbl: Label
var _caption: RichTextLabel
var _bar: ColorRect
var _state_lbl: Label
var _frame_img: Image
var _frame_img_n := -1


func _ready() -> void:
	lit_version = LitShaderLibrary._get_version()
	pin_render_size(get_window())
	_parse_demo_args()
	RenderingServer.set_default_clear_color(Color(0.03, 0.03, 0.04))
	_build_ui()
	build()
	for i in 4:
		await get_tree().process_frame
	_go(0)


## Override: build the exhibit and add_step() the walkthrough.
func build() -> void:
	pass


func demo_title() -> String:
	return section_title


## One step: `secs` long at 1x; `enter` sets the whole state the step needs (so stepping
## back works); `tick(f, t)` runs every frame with f = 0..1 through the step, t = seconds.
func add_step(title: String, text: String, secs: float, enter := Callable(), tick := Callable()) -> void:
	_steps.append({"title": title, "text": text, "secs": secs, "enter": enter, "tick": tick})


# --- Caption markup ---------------------------------------------------------------------

static func g(s: String) -> String:
	return "[color=#5ce673][b]%s[/b][/color]" % s


static func r(s: String) -> String:
	return "[color=#ff5c4d][b]%s[/b][/color]" % s


static func y(s: String) -> String:
	return "[color=#ffd640][b]%s[/b][/color]" % s


static func code(s: String) -> String:
	return "[color=#9fc6ff][code]%s[/code][/color]" % s


# --- Sequencer --------------------------------------------------------------------------

func _process(dt: float) -> void:
	if _cur < 0:
		return
	var s: Dictionary = _steps[_cur]
	if not _paused:
		_t += dt * _speed
	var f := clampf(_t / s.secs, 0.0, 1.0)
	if s.tick.is_valid():
		s.tick.call(f, minf(_t, s.secs))
	_bar.size.x = 1880.0 * f
	if _opt_shots != "" and not _mid_shot and f >= 0.5:
		_mid_shot = true
		_shot("mid")
	if _t >= s.secs and not _paused:
		if _opt_shots != "":
			_shot("end")
		if _cur + 1 < _steps.size():
			_go(_cur + 1)
		elif _opt_quit_end:
			get_tree().quit()
		else:
			_paused = true
			_state_lbl.text = "END - R replays, Left goes back"


func _go(i: int) -> void:
	_cur = clampi(i, 0, _steps.size() - 1)
	_t = 0.0
	_mid_shot = false
	var s: Dictionary = _steps[_cur]
	_step_lbl.text = "Step %d / %d   %s" % [_cur + 1, _steps.size(), s.title]
	_caption.text = s.text
	if s.enter.is_valid():
		s.enter.call()
	_state_lbl.text = "PAUSED" if _paused else ""


func _shot(tag: String) -> void:
	frame_image().save_png(_opt_shots.path_join("%02d_%s.png" % [_cur + 1, tag]))


func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_SPACE:
			_paused = not _paused
			_state_lbl.text = "PAUSED" if _paused else ""
		KEY_RIGHT:
			_go(_cur + 1)
		KEY_LEFT:
			_go(_cur - 1)
		KEY_R:
			_paused = false
			_go(0)
		KEY_1:
			_speed = 0.5
		KEY_2:
			_speed = 1.0
		KEY_3:
			_speed = 2.0
		KEY_4:
			_speed = 4.0
		KEY_ESCAPE:
			get_tree().quit()
	_keys_text()


func _parse_demo_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"speed":
				_speed = maxf(float(kv[1]), 0.1)
			"shots":
				_opt_shots = kv[1]
				DirAccess.make_dir_recursive_absolute(_opt_shots)
			"quit":
				_opt_quit_end = kv[1] == "on"


# --- UI ---------------------------------------------------------------------------------

var _keys_lbl: Label


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 100
	add_child(_ui)
	var top := ColorRect.new()
	top.color = Color(0.06, 0.06, 0.08)
	top.position = Vector2.ZERO
	top.size = Vector2(1920, 56)
	_ui.add_child(top)
	_title_lbl = _ui_label(demo_title(), Vector2(20, 10), 26, C_TEXT)
	_step_lbl = _ui_label("", Vector2(1000, 14), 22, C_NOTE)
	_step_lbl.size = Vector2(900, 30)
	_step_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var bottom := ColorRect.new()
	bottom.color = Color(0.06, 0.06, 0.08)
	bottom.position = Vector2(0, CAPTION_TOP)
	bottom.size = Vector2(1920, 1080 - CAPTION_TOP)
	_ui.add_child(bottom)
	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.16, 0.16, 0.2)
	bar_bg.position = Vector2(20, CAPTION_TOP + 6)
	bar_bg.size = Vector2(1880, 4)
	_ui.add_child(bar_bg)
	_bar = ColorRect.new()
	_bar.color = C_NOTE
	_bar.position = bar_bg.position
	_bar.size = Vector2(0, 4)
	_ui.add_child(_bar)
	_caption = RichTextLabel.new()
	_caption.bbcode_enabled = true
	_caption.position = Vector2(24, CAPTION_TOP + 16)
	_caption.size = Vector2(1872, 160)
	_caption.scroll_active = false
	_caption.add_theme_font_size_override("normal_font_size", 22)
	_caption.add_theme_font_size_override("bold_font_size", 22)
	_caption.add_theme_font_size_override("mono_font_size", 20)
	_caption.add_theme_color_override("default_color", C_TEXT)
	_ui.add_child(_caption)
	_keys_lbl = _ui_label("", Vector2(24, 1052), 15, C_DIM)
	_state_lbl = _ui_label("", Vector2(1600, 1050), 18, C_NOTE)
	_keys_text()


func _keys_text() -> void:
	_keys_lbl.text = "Space pause   Left/Right previous/next step   R restart   1-4 speed (now %sx)   Esc quit" % str(_speed)


func _ui_label(text: String, pos: Vector2, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 4)
	_ui.add_child(l)
	return l


## A framed exhibit area with a coloured tag: kind "expected" | "actual" | "neutral".
func panel(rect: Rect2, kind: String, heading: String) -> void:
	var col := C_EXPECTED if kind == "expected" else (C_ACTUAL if kind == "actual" else C_DIM)
	var tag: String = {"expected": "EXPECTED", "actual": "ACTUAL (BUG)", "neutral": ""}[kind]
	overlay_line(PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y), rect.position]), Color(col, 0.8), 2.0)
	var l := Label.new()
	l.text = ("  %s  " % tag if tag != "" else "") + "  " + heading
	l.position = rect.position + Vector2(8, 6)
	l.z_index = 60
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", 5)
	add_child(l)


## A world-space text readout (unlit, above the exhibits).
func readout(pos: Vector2, size := 22, color := C_TEXT, parent: Node = null) -> Label:
	var l := Label.new()
	l.position = pos
	l.z_index = 60
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	l.add_theme_constant_override("outline_size", 6)
	(parent if parent != null else self).add_child(l)
	return l


## A filled unlit polygon (drawn above the exhibits).
func overlay_poly(points: PackedVector2Array, color: Color, parent: Node = null) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = points
	p.color = color
	p.z_index = 55
	(parent if parent != null else self).add_child(p)
	return p


static func circle_points(c: Vector2, rad: float, n := 32) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in n:
		pts.append(c + Vector2.from_angle(TAU * float(k) / float(n)) * rad)
	return pts


## The last rendered frame, read back once per drawn frame.
func frame_image() -> Image:
	var n := Engine.get_frames_drawn()
	if n != _frame_img_n or _frame_img == null:
		_frame_img = get_viewport().get_texture().get_image()
		_frame_img_n = n
	return _frame_img


## A sprite in the UI layer showing a magnified crop of `img` around `center`.
func zoom_inset(sprite: Sprite2D, img: Image, center: Vector2, half: Vector2i, zoom: float) -> void:
	var c := to_px(center, img)
	var crop := img.get_region(Rect2i(int(c.x) - half.x, int(c.y) - half.y, half.x * 2, half.y * 2))
	sprite.texture = ImageTexture.create_from_image(crop)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.centered = false
	sprite.scale = Vector2(zoom, zoom)


## A line chart drawn in the UI layer.
class Graph extends Node2D:
	var rect := Rect2(0, 0, 400, 300)
	var x_min := 0.0
	var x_max := 1.0
	var y_min := 0.0
	var y_max := 1.0
	var title := ""
	var x_label := ""
	var y_label := ""
	var series := {}
	var order: Array = []
	var bands: Array = []    # [x0, x1, Color, label]
	var x_ticks: Array = []  # [x, "label"]
	var y_ticks: Array = []
	var cursor := NAN

	func add_series(name: String, color: Color) -> void:
		series[name] = {"color": color, "pts": PackedVector2Array()}
		order.append(name)

	func push(name: String, x: float, yv: float) -> void:
		series[name].pts.append(Vector2(x, yv))
		queue_redraw()

	func clear_points() -> void:
		for k in series:
			series[k].pts = PackedVector2Array()
		cursor = NAN
		queue_redraw()

	func map(p: Vector2) -> Vector2:
		return Vector2(rect.position.x + (p.x - x_min) / (x_max - x_min) * rect.size.x,
				rect.end.y - (clampf(p.y, y_min, y_max) - y_min) / (y_max - y_min) * rect.size.y)

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(rect.grow(10), Color(0.05, 0.05, 0.07, 0.94))
		draw_rect(rect, Color(0.3, 0.3, 0.36), false, 1.0)
		for b in bands:
			var a := map(Vector2(b[0], y_max))
			var e := map(Vector2(b[1], y_min))
			draw_rect(Rect2(a, e - a), b[2])
			if b.size() > 3:
				draw_string(font, Vector2(a.x + 4, e.y - 8), b[3], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 0.9, 0.4))
		for t in y_ticks:
			var p := map(Vector2(x_min, t[0]))
			draw_line(p, Vector2(rect.end.x, p.y), Color(0.25, 0.25, 0.3), 1.0)
			draw_string(font, p + Vector2(-48, 5), t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.7, 0.75))
		for t in x_ticks:
			var p := map(Vector2(t[0], y_min))
			draw_line(p, p + Vector2(0, 6), Color(0.6, 0.6, 0.65), 1.0)
			draw_string(font, p + Vector2(-20, 22), t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.7, 0.75))
		if not is_nan(cursor):
			var p := map(Vector2(cursor, y_min))
			draw_line(p, Vector2(p.x, rect.position.y), Color(1, 1, 1, 0.35), 1.0)
		var ly := rect.position.y + 4
		for name in order:
			var s: Dictionary = series[name]
			var pts := PackedVector2Array()
			for v in s.pts:
				pts.append(map(v))
			if pts.size() >= 2:
				draw_polyline(pts, s.color, 3.0, true)
			elif pts.size() == 1:
				draw_circle(pts[0], 3.0, s.color)
			draw_rect(Rect2(rect.end.x - 230, ly + 4, 16, 4), s.color)
			draw_string(font, Vector2(rect.end.x - 208, ly + 12), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, s.color)
			ly += 20
		draw_string(font, rect.position + Vector2(0, -16), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.95, 0.95, 1))
		draw_string(font, Vector2(rect.position.x, rect.end.y + 42), x_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.75, 0.75, 0.8))
		draw_string(font, rect.position + Vector2(-48, -2 - 2), y_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.75, 0.75, 0.8))


func graph(rect: Rect2) -> Graph:
	var gr := Graph.new()
	gr.rect = rect
	_ui.add_child(gr)
	return gr
