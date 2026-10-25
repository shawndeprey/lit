@tool
@icon("res://addons/lit/icons/lit_spot_light_2d.svg")
extends LitPositionalLight2D
class_name LitSpotLight2D

## A spot light for the Lit system: a point light masked to a cone.
##
## Has a position like a point light plus an aim: the node's local +X (the way it
## points, set by rotation) is the direction the cone shines. `range` and `falloff`
## give the same radial attenuation as a point light, and `spot_angle` / `spot_softness`
## shape the cone. It reuses the point light's radial shadow march, so shadows come for
## free. Everything except the cone is inherited from LitPositionalLight2D and
## LitLight2D.

@export_group("Cone")
## Half-angle from the aim direction to the cone edge, in degrees.
@export_range(0.0, 90.0) var spot_angle: float = 30.0
## Edge feather: 0 = hard cone edge, 1 = fades all the way from the center.
@export_range(0.0, 1.0) var spot_softness: float = 0.5
