extends Node2D

## Self-contained driver for the PBR "Short" showcase.
##
## Drives everything the vertical clip needs without touching project settings:
##   - Forces the Lit lighting model to PBR on the RenderingServer (the project
##     setting defaults to Phong; we flip the live global here and restore it on
##     exit so the rest of the project is unaffected).
##   - Sweeps two colored point lights across the panel so the normal map,
##     metallic rims and roughness variation all read as the light rakes over
##     them. One warm, one cool, orbiting opposite each other for two-sided
##     definition.
##   - Slowly pushes the camera in with a gentle drift + a touch of parallax so
##     the specular highlights travel across the surface (the thing that sells
##     PBR on video).
##   - Pulses the emissive strength subtly so the glowing strips read as alive.
##
## Wired to nodes by name (see PbrShort.tscn). Everything is animated in code so
## the clip loops cleanly for any recording length.

const LIT_MODEL_PBR := 1

# Panel is centered here in world space (matches the scene).
const CENTER: Vector2 = Vector2(540, 960)

# --- 15s beat map --------------------------------------------------------------
# Keyframed camera timeline so a recording from t=0 lands the right feature under
# each on-screen text overlay (text is added in edit; these are the visuals it
# sits on). Each key is {time_seconds, look_target_world, zoom}. The camera eases
# between consecutive keys with a smoothstep, so it settles on a feature exactly
# as its caption appears and is moving again by the next one.
#
#   0.0-2.5  "PBR just dropped" / Lit  -> upper emissive strip (ignition frames here)
#   3.0-5.5  "Real-time. In 2D."       -> wider, both lights raking the relief
#   6.0-8.5  "Metallic·Roughness·Normal"-> tight on a beveled metal corner
#   9.0-11.0 "Emissive that glows"      -> a strip, re-igniting
#   11.5-13  "Cook-Torrance specular"   -> tight metal, highlight travelling
#   13.0-15  end card                   -> pull back to center seam (loop point)
#
# The last key returns to the first key's framing so a 15s loop is seamless.
const CAM_KEYS: Array = [
	{ "t": 0.0,  "look": Vector2(540, 780),  "zoom": 2.3 },   # open: upper strip
	{ "t": 2.7,  "look": Vector2(540, 820),  "zoom": 2.3 },   # hold through the hook
	{ "t": 4.2,  "look": Vector2(540, 960),  "zoom": 1.9 },   # widen for "In 2D"
	{ "t": 6.8,  "look": Vector2(300, 700),  "zoom": 2.6 },   # tight beveled corner
	{ "t": 8.5,  "look": Vector2(320, 720),  "zoom": 2.6 },   # linger on the corner
	{ "t": 9.8,  "look": Vector2(540, 1140), "zoom": 2.4 },   # lower strip, re-ignites
	{ "t": 12.0, "look": Vector2(780, 1220), "zoom": 2.6 },   # metal, specular travel
	{ "t": 13.5, "look": Vector2(540, 900),  "zoom": 2.1 },   # begin pull-back
	{ "t": 15.0, "look": Vector2(540, 780),  "zoom": 2.3 },   # match the open (loop)
]
# Loop length; _t wraps here so the clip repeats cleanly for any recording length.
const TIMELINE_LEN: float = 15.0

# One-shot mode for rendering: play the 15s timeline exactly once, then quit so a
# frame capture stops itself after a complete loop (no manual stopping, and no
# guessing where in the loop it is). Set false to preview it looping forever in
# the editor instead.
const RENDER_ONCE: bool = true

# Emissive "flicker on" — the strips boot up like a fluorescent tube: dark, a
# few erratic stutters, then they hold steady. Two ignitions are scheduled to
# land under text beats: the open (t=0, under "PBR just dropped") and the
# "Emissive that glows" beat (~t=9). Each ignition plays over FLICKER_DURATION.
const FLICKER_DURATION: float = 3.2   # length of one ignition burst
const EMISSIVE_ON: float = 1.4        # steady strength once fully lit
# Times (in the 15s loop) at which a fresh ignition begins.
const FLICKER_IGNITIONS: Array[float] = [0.0, 9.0]
# Normalized flash windows within an ignition (start, end) in [0,1] of
# FLICKER_DURATION. Gaps between them are dark; irregular on purpose.
const FLICKER_FLASHES: Array[Vector2] = [
	Vector2(0.02, 0.05),   # first weak tick
	Vector2(0.10, 0.13),   # stutter
	Vector2(0.16, 0.17),   # quick blink out-in
	Vector2(0.28, 0.34),   # longer catch
	Vector2(0.40, 0.42),   # drop
	Vector2(0.52, 1.00),   # holds on from here
]

@onready var _cam: Camera2D = $Camera2D
@onready var _panel: LitSprite2D = $Panel
@onready var _warm: LitPointLight2D = $Lights/Warm
@onready var _cool: LitPointLight2D = $Lights/Cool
@onready var _key: LitDirectionalLight2D = $Lights/Key

# Restored on teardown so we leave the global as we found it.
var _prev_model := 0
var _t := 0.0
# Current camera framing, filled each frame by _sample_timeline from the beat
# map. The lights orbit _look so the framed detail is always the thing raked.
var _look: Vector2 = CENTER
var _zoom: float = 2.3
# Set once we've rendered the final frame in RENDER_ONCE mode, so the quit is
# requested exactly once.
var _finished := false


func _ready() -> void:
	# Frame as a vertical Short (9:16). Set the window and viewport to 1080x1920 so
	# the panel, centered at (540, 960), sits correctly regardless of the project's
	# default window size. Remove this block if your project is already portrait.
	var portrait := Vector2i(1080, 1920)
	var win := get_window()
	if win:
		win.size = portrait
		win.content_scale_size = portrait
		win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP

	# Pure black background: anything outside the panel (and any unlit area, since
	# ambient is black) reads as true black rather than the default grey clear.
	RenderingServer.set_default_clear_color(Color.BLACK)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set("lit_lighting_model", _prev_model)


func _process(dt: float) -> void:
	# Advance time at the END of this function (see bottom), so the first rendered
	# frame is exactly t=0 — the true opening framing. This makes a fixed-timestep
	# Movie Maker capture frame-accurate: frame 1 = t0, and the run covers the
	# half-open range [0, TIMELINE_LEN) — exactly TIMELINE_LEN * fps frames.

	# In one-shot render mode, clamp to the end of the timeline so the last frame
	# rendered is exactly the loop-point framing (which matches t=0), instead of
	# wrapping back toward 0. Otherwise wrap normally for endless preview looping.
	var loop_t := 0.0
	if RENDER_ONCE:
		# Stop just before drawing t=TIMELINE_LEN: that frame is identical to the
		# t=0 opening, so rendering it would duplicate frame 1. Ending here gives
		# exactly TIMELINE_LEN * fps frames (e.g. 900 at 60fps = 15.000s) with a
		# clean loop point and no duplicated frame.
		if not _finished and _t >= TIMELINE_LEN:
			_finished = true
			get_tree().quit()
			return
		loop_t = minf(_t, TIMELINE_LEN)
	else:
		loop_t = fmod(_t, TIMELINE_LEN)   # position within the 15s beat map

	# --- Where the camera is looking ----------------------------------------
	# Sample the keyframed timeline for this instant (fills _look and _zoom), so
	# the camera settles on each feature as its caption appears. Computed first so
	# the lights below orbit whatever is framed.
	_sample_timeline(loop_t)

	# --- Raking lights -------------------------------------------------------
	# Two point lights orbit the panel on an ellipse, half a turn apart, close to
	# the surface (low height) so the shading vector grazes and the normal map
	# pops. The radius breathes a little so the highlight sweep isn't perfectly
	# mechanical.
	# Orbit around whatever the camera is framing (_look, set by _sample_timeline
	# above) so the framed detail is always raked, not just screen center.
	# All periodic motion below uses loop_t at an integer number of cycles across
	# TIMELINE_LEN, so every sine returns to the same value AND slope at the loop
	# seam — no jump in light position, energy, key angle, or camera drift when the
	# clip wraps. w(n) = angular speed for n whole cycles over the timeline.
	var orbit := 220.0 + 40.0 * sin(loop_t * _w(1))
	var warm_ang := loop_t * _w(2)                 # 2 full orbits per loop
	var cool_ang := loop_t * _w(2) + PI

	_warm.position = _look + Vector2(cos(warm_ang), sin(warm_ang) * 0.75) * orbit
	_cool.position = _look + Vector2(cos(cool_ang), sin(cool_ang) * 0.75) * orbit

	# Gentle energy pulse, offset between the two so the mood keeps shifting.
	_warm.energy = 2.2 + 0.5 * sin(loop_t * _w(3))
	_cool.energy = 1.7 + 0.4 * sin(loop_t * _w(3) + 1.7)

	# Slowly swing the directional key so there's always a moving broad wash
	# under the two orbiters (keeps the matte areas from going flat-dark).
	_key.rotation = 0.5 * sin(loop_t * _w(1))

	# --- Camera: apply the timeline framing ---------------------------------
	# _look / _zoom come from the beat map; add a little hand-held drift on top so
	# it never feels locked to a rail. Drift also loops (1 and 2 cycles).
	_cam.position = _look + Vector2(10.0 * sin(loop_t * _w(1)), 8.0 * sin(loop_t * _w(2) + 1.0))
	_cam.zoom = Vector2(_zoom, _zoom)

	# --- Emissive flicker-on -------------------------------------------------
	# Ignitions are scheduled (FLICKER_IGNITIONS) to land under text beats rather
	# than on a fixed loop. Between ignitions the strips hold their steady glow.
	_panel.emissive_strength = _emissive_at(loop_t)

	# Advance time for the next frame (done last so frame 1 rendered at t=0).
	_t += dt


# Steady "powered" glow with a barely-there live shimmer. Shared so the seam
# (t=0 re-strike) and the normal rest state agree on the same level.
func _emissive_steady(loop_t: float) -> float:
	return EMISSIVE_ON * (0.97 + 0.03 * sin(loop_t * _w(4)))


# Angular speed for exactly `cycles` whole periods across TIMELINE_LEN, so any
# sin/cos driven by loop_t * _w(cycles) returns to the same value and slope at
# the loop seam. Keeps all ambient motion seamless when the clip wraps.
func _w(cycles: float) -> float:
	return TAU * cycles / TIMELINE_LEN


# Emissive strength at a given point in the 15s loop. If we're inside one of the
# scheduled ignition windows, play the boot-up burst from its start; otherwise
# hold the steady glow. The ignition at t=0 is a "warm re-strike": because the
# loop's previous frame (t≈15) is fully lit, that ignition starts from the lit
# level and stutters down, rather than a cold boot from black — so the loop seam
# is continuous. The mid-clip ignition (t=9) stays a cold boot for drama.
func _emissive_at(loop_t: float) -> float:
	for start in FLICKER_IGNITIONS:
		if loop_t >= start and loop_t < start + FLICKER_DURATION:
			var warm := is_equal_approx(start, 0.0)
			return _emissive_flicker(loop_t - start, warm)
	return _emissive_steady(loop_t)


# Sample the keyframed camera timeline at loop time `lt`, writing _look and _zoom.
# Finds the key pair bracketing `lt` and smoothsteps between them so the camera
# eases (accelerate-settle) rather than sliding linearly. Before the first key or
# after the last, it clamps to the end key (the last key matches the first, so a
# 15s loop is seamless).
func _sample_timeline(lt: float) -> void:
	var last := CAM_KEYS.size() - 1
	# Past (or exactly at) the final key: hold its framing.
	if lt >= float(CAM_KEYS[last]["t"]):
		_look = CAM_KEYS[last]["look"]
		_zoom = float(CAM_KEYS[last]["zoom"])
		return
	for i in range(last):
		var a: Dictionary = CAM_KEYS[i]
		var b: Dictionary = CAM_KEYS[i + 1]
		var ta := float(a["t"])
		var tb := float(b["t"])
		if lt >= ta and lt < tb:
			var f := smoothstep(0.0, 1.0, (lt - ta) / (tb - ta))
			_look = (a["look"] as Vector2).lerp(b["look"], f)
			_zoom = lerpf(float(a["zoom"]), float(b["zoom"]), f)
			return
	# Before the first key (shouldn't happen with t0 = 0): use the first.
	_look = CAM_KEYS[0]["look"]
	_zoom = float(CAM_KEYS[0]["zoom"])


# Maps time-since-ignition to an emissive strength.
#   warm=false (cold boot, mid-clip): dark except inside the authored flash
#     windows, ramping up as the tube "catches" — a startup from black.
#   warm=true (seam re-strike at t=0): starts from the steady lit level and
#     surges/dips around it instead of going black, so the loop seam (t~15 lit ->
#     t=0) is continuous. Same flash rhythm, just anchored to the lit level.
# Both settle back to the shared steady glow as t -> FLICKER_DURATION.
func _emissive_flicker(t: float, warm: bool = false) -> float:
	if t < FLICKER_DURATION:
		var phase := t / FLICKER_DURATION            # 0..1 through the ignition
		var on := 0.0
		for w in FLICKER_FLASHES:
			if phase >= w.x and phase < w.y:
				on = 1.0
				break
		var buzz := 0.75 + 0.25 * sin(t * 60.0)
		var ramp := smoothstep(0.0, 1.0, phase)      # later flashes brighter
		if warm:
			# Re-strike: value = steady + a deviation that is zero at phase 0 and
			# phase 1 (so it matches the lit seam going in and the steady glow
			# coming out). Flashes push the deviation positive (surge), gaps push
			# it slightly negative (dip), never reaching black. An envelope that
			# rises then falls guarantees the endpoints are exactly steady.
			var steady := _emissive_steady(t)
			var env := sin(phase * PI)               # 0 at phase 0 and 1, 1 mid
			var dev: float = (1.1 * buzz) if on > 0.5 else -0.35
			return steady * (1.0 + env * dev)
		# Cold boot from black.
		return EMISSIVE_ON * on * buzz * (0.5 + 0.5 * ramp)
	# Settled: hand back to the shared steady glow.
	return _emissive_steady(t)
