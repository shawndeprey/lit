extends CanvasLayer
class_name LitPrecompileOverlay

## Presentation only: subscribes to a LitShaderPrecompiler and draws either the
## takeover UI or the async floating progress box, per the lit/startup/* settings.

const DEFAULT_TITLE := "Lit Shaders Precompiling"

# (horizontal, vertical) size flags indexed by the precompile_async_position enum.
const POS_FLAGS := [
	[Control.SIZE_SHRINK_BEGIN, Control.SIZE_SHRINK_BEGIN],
	[Control.SIZE_SHRINK_CENTER, Control.SIZE_SHRINK_BEGIN],
	[Control.SIZE_SHRINK_END, Control.SIZE_SHRINK_BEGIN],
	[Control.SIZE_SHRINK_BEGIN, Control.SIZE_SHRINK_CENTER],
	[Control.SIZE_SHRINK_CENTER, Control.SIZE_SHRINK_CENTER],
	[Control.SIZE_SHRINK_END, Control.SIZE_SHRINK_CENTER],
	[Control.SIZE_SHRINK_BEGIN, Control.SIZE_SHRINK_END],
	[Control.SIZE_SHRINK_CENTER, Control.SIZE_SHRINK_END],
	[Control.SIZE_SHRINK_END, Control.SIZE_SHRINK_END],
]

## Set before adding to the tree: the worker window always shows the takeover layout.
var force_takeover := false

var _root: Control
var _bar: ProgressBar
var _count: Label
var _detail: Label


func _init() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var asynchronous := bool(ProjectSettings.get_setting("lit/startup/precompile_async", false))
	var verbose := bool(ProjectSettings.get_setting("lit/startup/precompile_verbose", true))
	var title_text := str(ProjectSettings.get_setting("lit/startup/precompile_title", ""))
	if title_text.strip_edges().is_empty():
		title_text = DEFAULT_TITLE
	if asynchronous and not force_takeover:
		_build_async(title_text, verbose)
	else:
		_build_takeover(title_text, verbose)


func _build_takeover(title_text: String, verbose: bool) -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	center.add_child(_build_box(title_text, verbose, 28, Vector2(420, 16), 16))


func _build_async(title_text: String, verbose: bool) -> void:
	_root = MarginContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		_root.add_theme_constant_override(side, 24)
	add_child(_root)
	var box := _build_box(title_text, verbose, 16, Vector2(220, 10), 13)
	var pos := clampi(int(ProjectSettings.get_setting(
			"lit/startup/precompile_async_position", 8)), 0, POS_FLAGS.size() - 1)
	box.size_flags_horizontal = POS_FLAGS[pos][0]
	box.size_flags_vertical = POS_FLAGS[pos][1]
	_root.add_child(box)


func _build_box(title_text: String, verbose: bool, title_size: int,
		bar_size: Vector2, text_size: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8 if title_size < 20 else 14)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", title_size)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = bar_size
	_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bar.show_percentage = false
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_bar)
	_count = Label.new()
	_count.custom_minimum_size = Vector2(64, 0)
	_count.add_theme_font_size_override("font_size", text_size)
	row.add_child(_count)
	if verbose:
		# Fixed-height holder keeps the detail text out of the box's size math, so the
		# card never resizes with the label; long text overflows the card instead.
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(0, text_size + 8)
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(holder)
		_detail = Label.new()
		_detail.add_theme_font_size_override("font_size", text_size)
		_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		holder.add_child(_detail)
		_detail.set_anchors_preset(Control.PRESET_CENTER)
		_detail.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_detail.grow_vertical = Control.GROW_DIRECTION_BOTH
	return box


func attach(pre: LitShaderPrecompiler) -> void:
	pre.progress.connect(_on_progress)
	pre.finished.connect(_on_finished)


func _on_progress(done: int, total: int, label: String) -> void:
	if _bar == null:
		return
	_bar.max_value = total
	_bar.value = done
	_count.text = "%d/%d" % [done, total]
	if _detail != null and label != "":
		_detail.text = label


func _on_finished() -> void:
	if _root == null:
		queue_free()
		return
	var tween := create_tween()
	tween.tween_property(_root, "modulate:a", 0.0, 0.35)
	tween.tween_callback(queue_free)
