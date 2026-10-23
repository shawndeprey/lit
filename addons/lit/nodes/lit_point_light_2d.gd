@tool
@icon("res://addons/lit/icons/lit_point_light_2d.svg")
extends LitPositionalLight2D
class_name LitPointLight2D

## A point light for the Lit system: radial attenuation from the node's position, an
## optional cookie texture and shadows marched from the node. Everything it exposes
## comes from LitPositionalLight2D (falloff, texture, shadow length and source) and
## LitLight2D (color, energy, height, the shadow gates, blend mode, z/layer ranges and
## the Light2D-style methods).
