extends Node2D

## Slowly brightens and dims a set of point lights like twinkling stars.
## Each light uses a sine wave (smooth swell, not a mechanical blink) and a
## random phase offset so they don't all pulse in unison.
##
## Setup:
##   1. Attach this script to a node in your scene (e.g. "LitLights").
##   2. In the Inspector, drag your LitPointLight2D nodes into the "Lights" array.
##   3. Tune Twinkle Amount / Twinkle Period to taste.

# Drag your LitPointLight2D nodes into this array in the Inspector.
@export var lights: Array[Node2D] = []

# How far above/below each light's base energy it swings.
# Keep small (0.03–0.06) relative to base energies of ~0.1–0.25, or dim lights
# will swing to zero and read as a flicker instead of a twinkle.
@export var twinkle_amount: float = 0.05

# Seconds for one full brighten→dim→brighten cycle. Higher = slower.
# 4.0 is gentle; 6.0–8.0 is dreamier.
@export var twinkle_period: float = 4.0

var _base_energy: Array[float] = []
var _phase_offset: Array[float] = []

func _ready() -> void:
	for light in lights:
		_base_energy.append(light.energy)
		# Random starting point so the lights don't pulse in sync.
		_phase_offset.append(randf() * TAU)

func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for i in lights.size():
		var wave := sin(t * (TAU / twinkle_period) + _phase_offset[i])
		lights[i].energy = _base_energy[i] + wave * twinkle_amount
