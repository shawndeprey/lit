extends Node2D

## Render-only copy of rpghub's Pot: frame variant + pastel tint + shadow placement.
## Net code, damage, sounds, and break particles are stripped for the benchmark.

@onready var pot: Sprite2D = $Sprites/Pot
@onready var overlay: Sprite2D = $Sprites/Overlay
@onready var shadow: Sprite2D = $Sprites/Shadow

var shadow_positions: Array[Vector2] = [Vector2(-0.5, 5), Vector2(0, 3), Vector2(0, 4), Vector2(0, 4),
										Vector2(0, 3), Vector2(0, 3), Vector2(0, 5), Vector2(0.5, 5)]
var base_frames: Array[int] = [0, 4, 8, 12, 16, 20, 24, 28]
var base_frame: int = base_frames.pick_random()

func _ready() -> void:
	pot.frame = base_frame
	overlay.frame = base_frame
	apply_random_pastel(pot)
	apply_random_pastel(overlay)
	shadow.position = shadow_positions[base_frames.find(base_frame)]

func apply_random_pastel(sprite: Sprite2D) -> void:
	sprite.modulate = Color.from_hsv(randf(), randf_range(0.25, 0.45), randf_range(0.85, 1.0))
