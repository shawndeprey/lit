extends Node2D
## Robot walker for the Lit sci-fi short.
##
## Sequence: stand idle for `idle_time` seconds, then play the walk cycle and
## translate to the right at `walk_speed` until it leaves the frame (or `walk_time`
## elapses). Designed to be filmed in one take for a 15-30s vertical Short.
##
## The AnimatedSprite2D child has two animations, "idle" (4 frames) and "walk"
## (8 frames), both sliced straight from res://Test/robot.png via AtlasTextures --
## no new art is generated. Its material is the Lit receiver shader so the scene's
## Lit lights shape it as it moves.
##
## The EyeGlow child is a Lit point light (lit_point_light_2d.gd) pulsed to sell the
## magenta eye panels as self-emissive -- the detail this lighting short shows off.

@export var idle_time: float = 1.6          # seconds standing before it sets off
@export var walk_speed: float = 46.0        # px/sec in native resolution
@export var walk_time: float = 6.0          # safety cap on walk duration
@export var loop_short: bool = true         # snap back to start and replay (clean Short loop)
@export var start_x: float = -28.0          # native x it spawns at (just off-frame left)
@export var exit_x: float = 240.0           # native x at which it has cleared frame right

@onready var _spr: AnimatedSprite2D = $AnimatedSprite2D
@onready var _eye: Node = get_node_or_null("EyeGlow")   # Lit point light, optional

enum State { IDLE, WALK }
var _state: int = State.IDLE
var _t: float = 0.0
var _eye_base_energy: float = 0.0


func _ready() -> void:
	position.x = start_x
	if _eye and "energy" in _eye:
		_eye_base_energy = _eye.energy
	_enter_idle()


func _enter_idle() -> void:
	_state = State.IDLE
	_t = 0.0
	_spr.play("idle")


func _enter_walk() -> void:
	_state = State.WALK
	_t = 0.0
	_spr.play("walk")


func _process(dt: float) -> void:
	_t += dt
	_pulse_eyes()

	match _state:
		State.IDLE:
			if _t >= idle_time:
				_enter_walk()
		State.WALK:
			position.x += walk_speed * dt
			if position.x >= exit_x or _t >= walk_time:
				if loop_short:
					position.x = start_x
					_enter_idle()
				else:
					set_process(false)


func _pulse_eyes() -> void:
	# Subtle flicker on the eye light so the glow feels alive, not static.
	if _eye and "energy" in _eye:
		var clock := Time.get_ticks_msec() / 1000.0
		var f := 0.85 + 0.15 * sin(clock * 6.0)
		_eye.energy = _eye_base_energy * f
