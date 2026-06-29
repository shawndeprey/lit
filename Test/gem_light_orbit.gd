extends Node2D
## Showcase orbit for the gemstone in the Props scene.
##
## Attached to a LitPointLight2D, this drives the light live each frame so the gem's
## faceted normal/specular shading is constantly hit from fresh angles -- the cheapest
## way to make a cut-stone effect read in a clip or screenshot.
##
## Three independent things move, each on its own period so the motion never looks like
## a single mechanical loop:
##   - position: orbits the gem in a circle (the XY sweep that walks highlights across facets)
##   - range:    the light's radius of influence, breathed in and out (its "distance" -- a
##               tighter range concentrates the falloff and pops specular hotspots)
##   - height:   the light's z-height above the surface, raised and lowered (drives the
##               normal-mapped shading direction; low height = long raking highlights that
##               skim the facets, high height = broad even fill)
##
## All values are @exported so they can be retuned live from the inspector while the scene
## plays. Center defaults to the gem's position in Props.tscn; override if the gem moves.

@export_group("Orbit")
## World-space point the light circles. Set to the gemstone's position.
@export var center: Vector2 = Vector2(469, 754)
## Radius of the circular path in pixels.
@export var orbit_radius: float = 360.0
## Orbit revolutions per second. Low and slow shows the facets off best.
@export var orbit_speed: float = 0.18

@export_group("Distance (light range)")
## Midpoint of the light's range as it breathes in/out, in pixels.
@export var range_center: float = 900.0
## How far range swings above/below the midpoint.
@export var range_amount: float = 380.0
## Cycles per second for the range breathing. Deliberately off the orbit speed.
@export var range_speed: float = 0.11

@export_group("Height")
## Midpoint of the light's z-height as it rises/falls.
@export var height_center: float = 60.0
## How far height swings above/below the midpoint. Keep height_center - height_amount > 0.
@export var height_amount: float = 45.0
## Cycles per second for the height bob. Off the other two speeds.
@export var height_speed: float = 0.07

## The LitPointLight2D this drives. Defaults to the first LitPointLight2D child.
@export var light_path: NodePath

var _t: float = 0.0
var _light: Node = null

const TAU := 6.283185307179586


func _ready() -> void:
	if light_path != NodePath():
		_light = get_node_or_null(light_path)
	if _light == null:
		# Fall back to the first child that looks like a Lit light.
		for c in get_children():
			if "range" in c and "height" in c:
				_light = c
				break


func _process(dt: float) -> void:
	if _light == null:
		return
	_t += dt

	# Circular sweep around the gem. The light is positioned in world space directly so
	# the group packer reads the orbit regardless of node nesting.
	var ang := _t * orbit_speed * TAU
	_light.global_position = center + Vector2(cos(ang), sin(ang)) * orbit_radius

	# Breathe the reach (distance) and bob the z-height on their own clocks.
	_light.range = range_center + sin(_t * range_speed * TAU) * range_amount
	_light.height = max(1.0, height_center + sin(_t * height_speed * TAU) * height_amount)
