extends Node2D

## Combined showcase: Lit 2D lighting + the screen-space weather system + the
## lit mech. A looping storm cycle drives the RainSystem; the Lit ambient
## (LitCanvasModulate) darkens and lifts with the weather, and every lightning
## strike briefly floods the scene with light via the ambient + a directional
## "sky" light, so the lighting and weather visibly react as one system.
##
## Controls (registered in code so they always work):
##   WASD  - drive the mech around
##   M     - toggle AUTO storm cycle / MANUAL
##   In MANUAL: E/Q intensity, Left/Right wind, Space lightning

@export var move_speed: float = 140.0

@onready var rain: RainSystem = $RainSystem
@onready var ambient: LitCanvasModulate = $Lit/LitCanvasModulate
@onready var sky: LitDirectionalLight2D = $Lit/SkyLight
@onready var mech: Node2D = $Mech
@onready var camera: Camera2D = $Camera2D
@onready var phase_label: Label = $UI/Phase
@onready var info_label: Label = $UI/Info

# Ambient endpoints for the storm. Clear night is a soft blue-grey; the storm
# peak crushes it toward near-black so lightning and the mech lights pop.
const AMBIENT_CLEAR := Color(0.20, 0.23, 0.30)
const AMBIENT_STORM := Color(0.05, 0.06, 0.09)

var _mech_body := Vector2.ZERO
var _manual := false
var _cycle_tween: Tween
var _phase_tween: Tween
var _phase_name := "Gathering clouds..."
var _storm_t := 0.0            # 0 = clear, 1 = peak; drives ambient darkness
var _flash_energy := 0.0       # transient lightning boost on the sky light


func _ready() -> void:
	_ensure_action("rain_up", KEY_E)
	_ensure_action("rain_down", KEY_Q)
	_ensure_action("wind_left", KEY_LEFT)
	_ensure_action("wind_right", KEY_RIGHT)
	_ensure_action("move_left", KEY_A)
	_ensure_action("move_right", KEY_D)
	_ensure_action("move_up", KEY_W)
	_ensure_action("move_down", KEY_S)
	_ensure_action("storm_flash", KEY_SPACE)
	_ensure_action("toggle_manual", KEY_M)

	rain.lightning_struck.connect(_on_lightning)
	rain.lightning_enabled = true
	rain.lightning_interval = Vector2(2.5, 6.0)
	rain.set_intensity(0.0)
	rain.set_wind(0.0)

	_apply_ambient()
	_start_cycle()


func _ensure_action(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


# --- Storm cycle -------------------------------------------------------------

func _start_cycle() -> void:
	if _cycle_tween and _cycle_tween.is_valid():
		_cycle_tween.kill()
	_cycle_tween = create_tween().set_loops()

	# name, rain intensity, wind, storm_t (ambient darkness), duration, hold
	_queue_phase("Calm night", 0.0, 0.0, 0.0, 3.0, 2.0)
	_queue_phase("Mist rolling in", 0.18, 0.05, 0.25, 5.0, 2.0)
	_queue_phase("Rain begins", 0.42, 0.14, 0.5, 5.0, 2.0)
	_queue_phase("Heavy downpour", 0.72, 0.24, 0.8, 5.0, 3.0)
	_queue_phase("STORM PEAK", 1.0, 0.42, 1.0, 4.0, 6.0)
	_queue_phase("Storm passing", 0.7, -0.16, 0.7, 4.0, 2.0)
	_queue_phase("Skies clearing", 0.32, -0.05, 0.3, 5.0, 2.0)
	_queue_phase("Calm returns", 0.0, 0.0, 0.0, 6.0, 3.0)


func _queue_phase(pname: String, intensity: float, wind: float,
		storm_t: float, dur: float, hold: float) -> void:
	var name_copy := pname
	_cycle_tween.tween_callback(func(): _phase_name = name_copy)
	_cycle_tween.tween_callback(func(): _begin_phase(intensity, wind, storm_t, dur))
	_cycle_tween.tween_interval(dur)
	_cycle_tween.tween_interval(hold)


func _begin_phase(target_intensity: float, target_wind: float,
		target_storm: float, dur: float) -> void:
	if _manual:
		return
	if _phase_tween and _phase_tween.is_valid():
		_phase_tween.kill()
	_phase_tween = create_tween().set_parallel(true)
	_phase_tween.tween_method(rain.set_intensity, rain.intensity, target_intensity, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_phase_tween.tween_method(rain.set_wind, rain.wind, target_wind, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_phase_tween.tween_method(_set_storm_t, _storm_t, target_storm, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _set_storm_t(v: float) -> void:
	_storm_t = clampf(v, 0.0, 1.0)
	_apply_ambient()


func _apply_ambient() -> void:
	# Darken ambient with the storm, then add any live lightning flash on top.
	var base := AMBIENT_CLEAR.lerp(AMBIENT_STORM, _storm_t)
	ambient.color = base + Color(_flash_energy, _flash_energy, _flash_energy)
	# The sky light stays dim during the storm and spikes on each flash.
	var sky_base := lerpf(0.35, 0.12, _storm_t)
	sky.energy = sky_base + _flash_energy * 6.0


func _on_lightning() -> void:
	# Punch the ambient + sky light bright, then decay. Camera kick for weight.
	if _phase_tween and false:
		pass
	var flash := create_tween()
	flash.tween_method(_set_flash, 0.55, 0.0, 0.5) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)

	var base_off := camera.offset
	var kick := create_tween()
	kick.tween_property(camera, "offset", base_off + Vector2(0, 5), 0.04)
	kick.tween_property(camera, "offset", base_off, 0.16)


func _set_flash(v: float) -> void:
	_flash_energy = v
	_apply_ambient()


# --- Mech movement + manual override ----------------------------------------

func _physics_process(_delta: float) -> void:
	var dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_down") - Input.get_action_strength("move_up")
	)
	_mech_body = dir.normalized() * move_speed
	mech.position += _mech_body * _delta
	# Face travel direction: the mech art points up, so aim the local -Y along motion.
	if dir.length() > 0.05:
		mech.rotation = lerp_angle(mech.rotation, dir.angle() + PI * 0.5, 0.15)


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
			_set_storm_t(rain.intensity)
		if Input.is_action_pressed("rain_down"):
			rain.set_intensity(rain.intensity - 0.015)
			_set_storm_t(rain.intensity)
		if Input.is_action_pressed("wind_left"):
			rain.set_wind(clampf(rain.wind - 0.01, -0.6, 0.6))
		if Input.is_action_pressed("wind_right"):
			rain.set_wind(clampf(rain.wind + 0.01, -0.6, 0.6))
		if Input.is_action_just_pressed("storm_flash"):
			rain.do_lightning()

	phase_label.text = _phase_name
	var mode := "AUTO storm cycle — M for manual"
	if _manual:
		mode = "MANUAL — E/Q rain, arrows wind, Space lightning"
	info_label.text = "Rain %.2f   Wind %+.2f   Storm %.2f\n%s\nWASD drives the mech" % [
		rain.intensity, rain.wind, _storm_t, mode]
