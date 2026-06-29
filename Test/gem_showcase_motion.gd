extends Node2D
## Showcase motion for the gemstone in the Props scene.
##
## Attached to a sibling Node2D (NOT the gem itself -- the gem keeps its LitSprite2D proxy
## script), this drives the target Gemstone each frame by NodePath, the same pattern
## GemLightOrbit uses to drive the light. It moves the STONE so the gem effects that respond
## to the gem's OWN movement get shown off -- the ones a circling light alone can't reveal.
## Pairs with GemLightOrbit (which moves the light); together they rake every facet through
## the light from independent directions.
##
## Each effect responds to a different kind of motion, so this drives three on their own
## periods (same trick as the light orbit: off-beat clocks so it never looks mechanical):
##
##   - rotation: slowly spins the stone in place. Rakes every internal facet through the
##               light from a second axis, so the internal-reflection glints and the
##               dispersion "fire" at facet edges travel across the body and flicker. The
##               main showcase for internal_strength + dispersion_amount.
##   - bob:      a small XY drift. Refraction samples the background BEHIND the gem, so as
##               the stone drifts each facet sweeps over different background content and the
##               bent image shifts -- the only motion that reveals refraction_strength. Keep
##               it small so the light orbit (which circles a FIXED point) stays roughly
##               centred on the gem.
##   - breathe:  a gentle scale pulse. Subtly shifts how the absorption depth-gradient reads
##               (thicker/thinner body) and adds life without distorting the silhouette.
##
## All values are @exported for live retuning from the inspector while the scene plays.
## home_position defaults to the target gem's authored position; the bob is an offset ON TOP
## of this, so the gem always returns to home.

@export_group("Target")
## The Gemstone sprite to drive. Defaults to a sibling named "Gemstone".
@export var gem_path: NodePath = NodePath("../Gemstone")

@export_group("Rotation")
## Whether to spin the stone. The single biggest showcase for the internal glints + fire.
@export var rotation_enabled: bool = true
## Revolutions per second. Low and slow reads best -- fast spin smears the sparkle into a
## blur instead of letting individual facet glints register.
@export var rotation_speed: float = 0.04

@export_group("Bob (XY drift -- shows refraction)")
## Whether to drift the stone in a small figure-ish path over the background.
@export var bob_enabled: bool = true
## How far the gem drifts from home, in pixels, on each axis. Small: the point is to slide
## facets over fresh background for the refraction, not to relocate the gem.
@export var bob_amount: Vector2 = Vector2(48.0, 32.0)
## Cycles per second for the horizontal drift.
@export var bob_speed_x: float = 0.13
## Cycles per second for the vertical drift. Deliberately off bob_speed_x so the path is an
## open Lissajous curve, not a straight diagonal -- the gem wanders rather than ping-pongs.
@export var bob_speed_y: float = 0.09

@export_group("Breathe (scale pulse -- shows absorption)")
## Whether to pulse the stone's scale.
@export var breathe_enabled: bool = true
## Base scale of the gem (its authored scale in Props.tscn is (5, 5)). The pulse swings
## around this. Set to match the gem's intended size.
@export var breathe_base: float = 1.0
## How far scale swings above/below base, in the same units as breathe_base. Keep small so
## the silhouette barely changes; this is a subtle volume cue, not a zoom.
@export var breathe_amount: float = 0.6
## Cycles per second for the breathe. Off the other two clocks.
@export var breathe_speed: float = 0.07

@export_group("Home")
## The gem's resting position. Captured from the gem on _ready unless overridden below.
@export var home_position: Vector2 = Vector2(469, 754)
## If true, capture the gem's current position as home on _ready instead of using the
## exported value. Convenient if you move the gem in the editor and don't want to retype.
@export var capture_home_on_ready: bool = true

@export_group("Wander (increasing randomness)")
## Whether to layer pseudo-random drift on top of the smooth bob/rotation. This makes the
## motion read as "alive" rather than a clean Lissajous loop.
@export var wander_enabled: bool = true
## Peak extra positional drift in pixels (per axis) once randomness has fully ramped in.
## Layered ON TOP of bob_amount, so total travel = bob + wander.
@export var wander_amount: Vector2 = Vector2(60.0, 60.0)
## Peak extra rotational jitter in radians once fully ramped in.
@export var wander_rotation: float = 0.6
## How fast the underlying noise evolves (higher = more frantic, jittery wander).
@export var wander_speed: float = 0.6
## Seconds for the randomness to ramp from 0 to full strength. The motion starts calm and
## becomes "more and more random" over this window. Set 0 for full randomness immediately.
@export var wander_ramp_time: float = 12.0
## Per-gem random seed so every stone wanders independently instead of in lockstep.
@export var wander_seed: float = 0.0

var _t: float = 0.0
var _gem: Node2D = null

const TAU := 6.283185307179586


func _ready() -> void:
	if gem_path != NodePath():
		_gem = get_node_or_null(gem_path) as Node2D
	if _gem == null:
		push_warning("GemShowcaseMotion: no gem found at gem_path; motion disabled.")
		return
	if capture_home_on_ready:
		home_position = _gem.position


func _process(dt: float) -> void:
	if _gem == null:
		return
	_t += dt

	# Wander ramp: 0 -> 1 over wander_ramp_time, so motion gets "more and more random".
	# A pseudo-noise value per axis from summed incommensurate sines (no Noise resource
	# needed). wander_seed offsets the phase so each gem wanders independently.
	var wander_x := 0.0
	var wander_y := 0.0
	var wander_rot := 0.0
	if wander_enabled:
		var ramp := 1.0
		if wander_ramp_time > 0.0:
			ramp = clamp(_t / wander_ramp_time, 0.0, 1.0)
		var wt := _t * wander_speed
		var sd := wander_seed
		# Three off-ratio sines per channel -> non-repeating, organic drift.
		var nx := sin(wt * 1.0 + sd) + 0.6 * sin(wt * 2.3 + sd * 1.7) + 0.4 * sin(wt * 4.1 + sd * 2.9)
		var ny := sin(wt * 1.3 + sd * 2.1) + 0.6 * sin(wt * 2.9 + sd * 0.7) + 0.4 * sin(wt * 4.7 + sd * 3.3)
		var nr := sin(wt * 1.7 + sd * 1.1) + 0.5 * sin(wt * 3.7 + sd * 2.3)
		# Normalize roughly to [-1, 1] (max sum of amplitudes is 2.0 / 1.5).
		wander_x = (nx / 2.0) * wander_amount.x * ramp
		wander_y = (ny / 2.0) * wander_amount.y * ramp
		wander_rot = (nr / 1.5) * wander_rotation * ramp

	# Rotation: rake the facets. rotation is in radians; spin continuously, plus jitter.
	if rotation_enabled:
		_gem.rotation = _t * rotation_speed * TAU + wander_rot

	# Bob: an open Lissajous drift around home on two off-beat clocks, plus the wander
	# offset on top. This is the motion that makes refraction read -- each facet slides
	# over new background.
	if bob_enabled:
		var offset := Vector2(
			sin(_t * bob_speed_x * TAU) * bob_amount.x + wander_x,
			sin(_t * bob_speed_y * TAU) * bob_amount.y + wander_y
		)
		_gem.position = home_position + offset
	else:
		_gem.position = home_position + Vector2(wander_x, wander_y)

	# Breathe: gentle scale pulse around base. Shifts the absorption depth read subtly.
	if breathe_enabled:
		var s := breathe_base + sin(_t * breathe_speed * TAU) * breathe_amount
		_gem.scale = Vector2(s, s)
