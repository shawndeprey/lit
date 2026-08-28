class_name CryptTorch extends Node2D

@onready var point_light_2d: LitPointLight2D = $PointLight2D

# Tunables (realistic values)
@export var flicker_strength := 0.12      # ±12% energy variation
@export var flicker_speed := 2.5           # how fast the flame moves
@export var jitter_strength := 0.03        # tiny chaotic jitter

var base_energy: float
var time := 0.0
var noise := FastNoiseLite.new()

func _ready() -> void:
	base_energy = point_light_2d.energy

	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.8
	noise.seed = randi()

func _process(delta: float) -> void:
	time += delta * flicker_speed

	# Smooth flame movement
	var smooth := noise.get_noise_1d(time)          # -1 → 1
	smooth = (smooth + 1.0) * 0.5                    # 0 → 1

	# Small chaotic jitter
	var jitter := randf_range(-jitter_strength, jitter_strength)

	# Final energy
	var energy := base_energy
	energy += base_energy * flicker_strength * smooth
	energy += base_energy * jitter

	point_light_2d.energy = energy
