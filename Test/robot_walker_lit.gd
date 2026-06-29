extends Node2D
## Robot walker for the Lit sci-fi/industrial short, driven by a LitSprite2D.
##
## The previous version used an AnimatedSprite2D, which doesn't currently shade
## correctly under Lit. AnimatedSprite2D swaps whole textures per frame and doesn't
## expose its drawn frame through the plain Sprite2D region path that Lit's receiver
## material expects, so the normal/specular shading breaks up as frames change.
##
## Instead the body is a single LitSprite2D pointed at the whole 224x32 spritesheet,
## sliced with hframes = 14, vframes = 1. We animate by stepping the inherited
## `frame` property on a fixed timer -- the receiver material and CanvasTexture stay
## put, so Lit shades every frame identically. This is the standard "manual spritesheet
## animation on a Sprite2D" approach, just on the Lit-wired subclass.
##
## Spritesheet layout (1 row, 14 frames, each 16x32):
##   frames 0-3   idle cycle (4 frames)
##   frame  4     blank/unused
##   frames 5-12  walk cycle (8 frames)
##   frame  13    blank/unused
##
## Sequence: stand idle for `idle_time` seconds, then play the walk cycle and translate
## right at `walk_speed` until it leaves frame (or `walk_time` elapses). Built to be
## filmed in one take for a short vertical clip; set loop_short to replay cleanly.
##
## The EyeGlow child is a LitPointLight2D pulsed to sell the robot's eye panel as
## self-emissive -- the kind of detail this lighting short is meant to show off.

@export_group("Timing")
@export var idle_time: float = 1.6          # seconds standing before it sets off
@export var walk_time: float = 6.0          # safety cap on walk duration

@export_group("Movement")
@export var walk_speed: float = 46.0        # px/sec in the sprite's local space
@export var loop_short: bool = true         # snap back to start and replay (clean loop)
@export var start_x: float = -28.0          # local x it spawns at (just off-frame left)
@export var exit_x: float = 240.0           # local x at which it has cleared frame right

@export_group("Animation")
## Frames per second for both cycles. 8-10 reads well for a chunky pixel robot.
@export var idle_fps: float = 6.0
@export var walk_fps: float = 10.0

# Frame ranges within the sheet (inclusive). Exported so they can be retuned from the
# inspector if the sheet layout ever shifts, without touching code.
@export var idle_frames := Vector2i(0, 3)
@export var walk_frames := Vector2i(5, 12)

@onready var _spr: Sprite2D = $LitSprite2D
@onready var _eye: Node = get_node_or_null("LitSprite2D/EyeGlow")   # optional

enum State { IDLE, WALK }
var _state: int = State.IDLE
var _t: float = 0.0                 # time in current state
var _anim_t: float = 0.0           # accumulator for frame stepping
var _anim_frame: int = 0          # index within the current cycle (0-based)
var _eye_base_energy: float = 0.0


func _ready() -> void:
	# Make sure the sheet is sliced the way the layout describes, regardless of how the
	# scene was saved -- 14 columns, 1 row.
	_spr.hframes = 14
	_spr.vframes = 1
	position.x = start_x
	if _eye and "energy" in _eye:
		_eye_base_energy = _eye.energy
	_enter_idle()


func _enter_idle() -> void:
	_state = State.IDLE
	_t = 0.0
	_anim_t = 0.0
	_anim_frame = 0
	_spr.frame = idle_frames.x


func _enter_walk() -> void:
	_state = State.WALK
	_t = 0.0
	_anim_t = 0.0
	_anim_frame = 0
	_spr.frame = walk_frames.x


func _process(dt: float) -> void:
	_t += dt
	_pulse_eyes()

	match _state:
		State.IDLE:
			_advance_anim(dt, idle_frames, idle_fps)
			if _t >= idle_time:
				_enter_walk()
		State.WALK:
			_advance_anim(dt, walk_frames, walk_fps)
			position.x += walk_speed * dt
			if position.x >= exit_x or _t >= walk_time:
				if loop_short:
					position.x = start_x
					_enter_idle()
				else:
					set_process(false)


func _advance_anim(dt: float, frames: Vector2i, fps: float) -> void:
	# Step `frame` through the [frames.x, frames.y] span at `fps`, looping.
	if fps <= 0.0:
		return
	var count: int = frames.y - frames.x + 1
	if count <= 0:
		return
	_anim_t += dt
	var step := 1.0 / fps
	while _anim_t >= step:
		_anim_t -= step
		_anim_frame = (_anim_frame + 1) % count
		_spr.frame = frames.x + _anim_frame


func _pulse_eyes() -> void:
	# Subtle flicker on the eye light so the glow feels alive, not static.
	if _eye and "energy" in _eye:
		var clock := Time.get_ticks_msec() / 1000.0
		var f := 0.85 + 0.15 * sin(clock * 6.0)
		_eye.energy = _eye_base_energy * f
