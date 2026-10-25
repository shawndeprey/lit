@tool
@abstract
extends LitLight2D
class_name LitPositionalLight2D

## Base of every Lit light with a position: range falloff, an optional cookie and
## shadows marched from the light. Directional lights derive from LitLight2D instead.

const TextureSizeMode = LitShaderLibrary.TextureSizeMode

@export_group("Falloff")
## Radius of influence in pixels, multiplied by the node's global scale (larger axis,
## like a PointLight2D's texture footprint); drives attenuation and AABB culling.
@export var range: float = 256.0:
	set(value):
		range = value
		LitLightRegistry.light_state_changed(self)
## Attenuation curve exponent.
@export var falloff: float = 1.0

@export_group("Texture")
## Optional cookie: modulates the light (composing with a spot light's cone), centered
## on the node and rotating with it. RGB tints, alpha shapes; outside the texture the
## light is dark. Clipped to `range`. With `falloff` 0 the texture alone defines the
## light's shape.
@export var texture: Texture2D
## Multiplier on the cookie's footprint.
@export var texture_scale: float = 1.0
## How the cookie's footprint is sized.
@export var texture_size_mode: TextureSizeMode = TextureSizeMode.NATIVE
## Slides the cookie off the node's center, in the texture's local pixels: it rotates
## with the node (and in NATIVE mode scales with it). Falloff, cone, shadows, and
## shading stay centered on the node, so animating this reads as the fixture swinging.
## The cookie still clips at `range`.
@export var texture_offset: Vector2 = Vector2.ZERO

@export_group("Shadow")
## Caps each shadow at this fraction of the fragment's distance to the light; the
## shadow closes there through a natural penumbral tip. Shadows stretch with an
## occluder's distance from the light, reading like a light hung above the ground.
## 1 = shadows reach all the way to the light (the default).
@export_range(0.01, 1.0, 0.001) var shadow_length: float = 1.0
## Radius of the physical emitting disc in world pixels (CONE_TRACED / STOCHASTIC),
## scaled with the node like `range`. Bigger sources cast softer shadows: wider
## penumbras and shorter umbras - an occluder's dark core tapers closed after roughly
## (occluder width / source_radius) x its distance to the light, so radii comparable
## to your occluders give clearly visible soft-light behavior. Distinct from `range`,
## which is how far the light reaches.
@export_range(0.0, 256.0, 0.5, "or_greater") var source_radius: float = 32.0

func _shadow_source_property() -> StringName:
	return &"source_radius"

# PointLight2D method names.
func set_texture(value: Texture2D) -> void:
	texture = value

func get_texture() -> Texture2D:
	return texture

func set_texture_offset(value: Vector2) -> void:
	texture_offset = value

func get_texture_offset() -> Vector2:
	return texture_offset

func set_texture_scale(value: float) -> void:
	texture_scale = value

func get_texture_scale() -> float:
	return texture_scale
