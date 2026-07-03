extends Node2D

## Automated weather-cycle showcase: clear -> misty -> building -> storm ->
## clearing, looping. All effects fade smoothly via tweens on the RainSystem.
## Press M to toggle manual mode (E/Q intensity, arrows for wind, Space flash).

@export var move_speed: float = 260.0
@onready var player: CharacterBody2D = $Player
@onready var rain: RainSystem = $RainSystem
@onready var label: Label = $UI/Info
@onready var phase_label: Label = $UI/Phase

var _manual := false
var _cycle_tween: Tween
var _phase_tween: Tween
var _phase_name := "Starting..."

func _ready() -> void:
	_ensure_action("rain_up", KEY_E)
	_ensure_action("rain_down", KEY_Q)
	_ensure_action("wind_left", KEY_LEFT)
	_ensure_action("wind_right", KEY_RIGHT)
	_ensure_action("move_left", KEY_A)
	_ensure_action("move_right", KEY_D)
	_ensure_action("move_fwd", KEY_W)
	_ensure_action("move_back", KEY_S)
	_ensure_action("rain_flash", KEY_SPACE)
	_ensure_action("toggle_manual", KEY_M)

	# Hook thunder timing / screen shake here if desired
	rain.lightning_struck.connect(_on_lightning)

	# Tighter interval so the storm peak reliably shows a few strikes
	rain.lightning_enabled = true
	rain.lightning_interval = Vector2(2.5, 6.0)
	rain.set_intensity(0.0)
	rain.set_wind(0.0)
	_start_cycle()

func _ensure_action(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)

# --- Automated weather cycle -------------------------------------------------

func _start_cycle() -> void:
	if _cycle_tween and _cycle_tween.is_valid():
		_cycle_tween.kill()
	_cycle_tween = create_tween().set_loops()  # loop forever

	# Each entry: phase name, target intensity, target wind, duration, hold.
	_queue_phase("Clear skies", 0.0, 0.0, 3.0, 2.0)
	_queue_phase("Mist rolling in", 0.18, 0.05, 5.0, 2.0)
	_queue_phase("Light drizzle", 0.4, 0.12, 5.0, 2.0)
	_queue_phase("Steady rain", 0.7, 0.22, 5.0, 3.0)
	_queue_phase("STORM PEAK", 1.0, 0.4, 4.0, 6.0)   # lightning fires here
	_queue_phase("Gusting over", 0.75, -0.15, 4.0, 2.0)
	_queue_phase("Easing off", 0.35, -0.05, 5.0, 2.0)
	_queue_phase("Clearing", 0.0, 0.0, 6.0, 3.0)

func _queue_phase(pname: String, intensity: float, wind: float,
		dur: float, hold: float) -> void:
	# Label update at the start of the transition. Capture pname by value.
	var name_copy := pname
	_cycle_tween.tween_callback(func(): _phase_name = name_copy)
	# Read the CURRENT values when this phase begins, not when queued.
	_cycle_tween.tween_callback(func(): _begin_phase(intensity, wind, dur))
	# Reserve the transition duration, then the hold.
	_cycle_tween.tween_interval(dur)
	_cycle_tween.tween_interval(hold)

func _begin_phase(target_intensity: float, target_wind: float, dur: float) -> void:
	if _manual:
		return
	if _phase_tween and _phase_tween.is_valid():
		_phase_tween.kill()
	# Parallel tweens for intensity + wind, starting from wherever we are now.
	_phase_tween = create_tween().set_parallel(true)
	var ti := _phase_tween.tween_method(rain.set_intensity, rain.intensity, target_intensity, dur)
	ti.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var tw := _phase_tween.tween_method(rain.set_wind, rain.wind, target_wind, dur)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _on_lightning() -> void:
	# Small camera kick on each strike for drama
	var cam := $Camera2D as Camera2D
	if cam:
		var tw := create_tween()
		var base := cam.offset
		tw.tween_property(cam, "offset", base + Vector2(0, 4), 0.04)
		tw.tween_property(cam, "offset", base, 0.12)

# --- Manual override ---------------------------------------------------------

func _physics_process(_delta: float) -> void:
	var dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_fwd")
	)
	player.velocity = dir.normalized() * move_speed
	player.move_and_slide()

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("toggle_manual"):
		_manual = not _manual
		if _manual:
			if _cycle_tween and _cycle_tween.is_valid():
				_cycle_tween.kill()
			if _phase_tween and _phase_tween.is_valid():
				_phase_tween.kill()
			_phase_name = "MANUAL"
		else:
			_start_cycle()

	if _manual:
		if Input.is_action_pressed("rain_up"):
			rain.set_intensity(rain.intensity + 0.015)
		if Input.is_action_pressed("rain_down"):
			rain.set_intensity(rain.intensity - 0.015)
		if Input.is_action_pressed("wind_left"):
			rain.set_wind(clampf(rain.wind - 0.01, -0.6, 0.6))
		if Input.is_action_pressed("wind_right"):
			rain.set_wind(clampf(rain.wind + 0.01, -0.6, 0.6))
		if Input.is_action_just_pressed("rain_flash"):
			rain.do_lightning()

	phase_label.text = _phase_name
	var mode := "AUTO cycle — press M for manual control"
	if _manual:
		mode = "MANUAL — E/Q intensity, arrows for wind, Space lightning"
	label.text = "Intensity %.2f   Wind %+.2f\n%s\nWASD to walk into the shelter" % [rain.intensity, rain.wind, mode]
