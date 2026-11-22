extends Button

## One scene tile: a darkened thumbnail that grows, zooms, brightens and lights up in a
## random colour while hovered, then eases back. Every change is tweened.

const GROW := 1.08
const ZOOM := 1.12
const DIM := Color(0.55, 0.55, 0.55)
const GLOW_ENERGY := 1.6
const IN_TIME := 0.18
const OUT_TIME := 0.4

@onready var _thumb: Sprite2D = $Thumb
@onready var _glow: LitPointLight2D = $Glow
@onready var _label: Label = $Name

var _tile_size := Vector2(480, 270)
var _thumb_scale := Vector2.ONE
var _tween: Tween

func _ready() -> void:
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)
	_thumb.self_modulate = DIM

func setup(entry: Dictionary) -> void:
	_label.text = entry.name
	_thumb.texture = entry.thumb
	_thumb.visible = entry.thumb != null

func set_tile_size(tile_size: Vector2, cookie: Texture2D, cookie_scale: float) -> void:
	_tile_size = tile_size
	custom_minimum_size = tile_size
	pivot_offset = tile_size * 0.5
	_thumb.position = tile_size * 0.5
	if _thumb.texture:
		_thumb_scale = tile_size / Vector2(_thumb.texture.get_size())
		_thumb.scale = _thumb_scale * (ZOOM if is_hovered() else 1.0)
	_glow.position = tile_size * 0.5
	_glow.texture = cookie
	_glow.texture_scale = cookie_scale
	_glow.range = tile_size.length()

func _on_enter() -> void:
	z_index = 1
	_glow.color = Color.from_hsv(randf(), 0.8, 1.0)
	_glow.enabled = true
	_animate(GROW, ZOOM, Color.WHITE, GLOW_ENERGY, IN_TIME, Tween.EASE_OUT)

func _on_exit() -> void:
	_animate(1.0, 1.0, DIM, 0.0, OUT_TIME, Tween.EASE_IN_OUT)
	_tween.finished.connect(func() -> void:
		z_index = 0
		_glow.enabled = false)

func _animate(grow: float, zoom: float, tint: Color, energy: float, time: float, easing: Tween.EaseType) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_tween.tween_property(self, "scale", Vector2.ONE * grow, time)
	_tween.tween_property(_thumb, "scale", _thumb_scale * zoom, time)
	_tween.tween_property(_thumb, "self_modulate", tint, time)
	_tween.tween_property(_glow, "energy", energy, time)
