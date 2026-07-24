extends CanvasLayer
class_name LitSplashScreen

## Drop-in branded splash: glitch-fades in the Lit logo, holds, fades to black, frees itself.

signal finished

const DEFAULT_LOGO := preload("res://addons/lit/branding/Lit-Logo-Text.png")
const DEFAULT_SFX := preload("res://addons/lit/branding/glitch.mp3")
const GLITCH_SHADER := preload("res://addons/lit/shaders/lit_post_glitch.gdshader")

@export var autoplay := true
@export var skippable := true
@export var auto_free := true
@export var logo: Texture2D = DEFAULT_LOGO
@export var sfx: AudioStream = DEFAULT_SFX
@export var background_color := Color.BLACK
## Fraction of screen width/height the logo may occupy (aspect is preserved).
@export_range(0.1, 1.0, 0.01) var logo_screen_ratio := 0.6
@export_range(0.05, 5.0, 0.05) var fade_in_time := 0.7
@export_range(0.0, 30.0, 0.1) var hold_time := 2.5
@export_range(0.05, 5.0, 0.05) var fade_out_time := 0.45
@export_range(0.0, 1.0, 0.01) var glitch_strength := 0.55

var _logo_rect: TextureRect
var _audio: AudioStreamPlayer
var _glitch_mat: ShaderMaterial
var _glitch_pass: CanvasLayer
var _tween: Tween
var _playing := false
var _elapsed := 0.0
var _glitch_len := 0.0


func _init() -> void:
	layer = 100


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	set_process(false)
	if autoplay:
		play()
	else:
		visible = false


func play() -> void:
	if _playing:
		return
	_playing = true
	_elapsed = 0.0
	_glitch_len = sfx.get_length() if sfx != null else 1.0
	_logo_rect.modulate.a = 0.0
	visible = true
	_glitch_pass.visible = true
	if sfx != null:
		_audio.stream = sfx
		_audio.play()
	set_process(true)
	_tween = create_tween()
	_tween.tween_property(_logo_rect, "modulate:a", 1.0, fade_in_time)
	_tween.tween_interval(maxf(0.0, _glitch_len - fade_in_time) + hold_time)
	_tween.tween_property(_logo_rect, "modulate:a", 0.0, fade_out_time)
	_tween.tween_interval(0.25)
	_tween.tween_callback(_finish)


func skip() -> void:
	if not _playing:
		return
	if _tween != null:
		_tween.kill()
	_audio.stop()
	_glitch_pass.visible = false
	_tween = create_tween()
	_tween.tween_property(_logo_rect, "modulate:a", 0.0, 0.2)
	_tween.tween_callback(_finish)


func _finish() -> void:
	_playing = false
	set_process(false)
	_glitch_pass.visible = false
	finished.emit()
	if auto_free:
		queue_free()
	else:
		visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not _playing or not skippable:
		return
	if (event is InputEventKey or event is InputEventJoypadButton) and event.is_pressed():
		get_viewport().set_input_as_handled()
		skip()


func _on_root_gui_input(event: InputEvent) -> void:
	if _playing and skippable and event is InputEventMouseButton and event.is_pressed():
		skip()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _glitch_len:
		_glitch_pass.visible = false
		return
	# Envelope: fast attack, decay over the tail of the audio.
	var k := clampf(_elapsed / 0.1, 0.0, 1.0) * clampf((_glitch_len - _elapsed) / 0.6, 0.0, 1.0)
	_glitch_mat.set_shader_parameter("intensity", glitch_strength * k)
	_glitch_mat.set_shader_parameter("rgb_shift", 6.0 * k)


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.gui_input.connect(_on_root_gui_input)
	add_child(root)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = background_color
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	_logo_rect = TextureRect.new()
	_logo_rect.texture = logo
	_logo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var m := logo_screen_ratio * 0.5
	_logo_rect.anchor_left = 0.5 - m
	_logo_rect.anchor_right = 0.5 + m
	_logo_rect.anchor_top = 0.5 - m
	_logo_rect.anchor_bottom = 0.5 + m
	_logo_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_rect.modulate.a = 0.0
	root.add_child(_logo_rect)

	_audio = AudioStreamPlayer.new()
	add_child(_audio)

	# Glitch pass sits one canvas layer above so hint_screen_texture reads the logo.
	_glitch_pass = CanvasLayer.new()
	_glitch_pass.layer = layer + 1
	_glitch_pass.visible = false
	_glitch_mat = ShaderMaterial.new()
	_glitch_mat.shader = GLITCH_SHADER
	_glitch_mat.set_shader_parameter("intensity", 0.0)
	_glitch_mat.set_shader_parameter("rgb_shift", 0.0)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = _glitch_mat
	_glitch_pass.add_child(rect)
	add_child(_glitch_pass)
