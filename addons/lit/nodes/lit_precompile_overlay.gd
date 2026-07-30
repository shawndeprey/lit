extends CanvasLayer
class_name LitPrecompileOverlay

## Presentation only: subscribes to a LitShaderPrecompiler and draws the takeover UI.

var _cover: Control
var _bar: ProgressBar
var _status: Label


func _init() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_cover = Control.new()
	_cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_cover)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cover.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cover.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)
	var title := Label.new()
	title.text = "Lit Shaders Precompiling"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(420, 16)
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bar.show_percentage = false
	box.add_child(_bar)
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)


func attach(pre: LitShaderPrecompiler) -> void:
	pre.progress.connect(_on_progress)
	pre.finished.connect(_on_finished)


func _on_progress(done: int, total: int, label: String) -> void:
	_bar.max_value = total
	_bar.value = done
	_status.text = "%d/%d shaders precompiled\n%s" % [done, total, label]


func _on_finished() -> void:
	var tween := create_tween()
	tween.tween_property(_cover, "modulate:a", 0.0, 0.35)
	tween.tween_callback(queue_free)
