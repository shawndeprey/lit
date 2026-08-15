@tool
@icon("res://addons/lit/icons/lit_spot_light_2d.svg")
extends Node2D
class_name LitSpotLight2D

## A spot light for the Lit system: a point light masked to a cone.
##
## Has a position like a point light plus an aim: the node's local +X (the way it
## points, set by rotation) is the direction the cone shines. `range` and `falloff`
## give the same radial attenuation as a point light, and `spot_angle` / `spot_softness`
## shape the cone. It reuses the point light's radial shadow march, so shadows come for
## free.
##
## As with the other lights, `light_mask` reuses the inherited CanvasItem property
## ("Visibility" in the inspector) and is matched against each receiver's `receiver_mask`.

# Shared contracts, aliased so LitSpotLight2D.BlendMode etc. remain the public
# names; the definitions (and the wire-format rules) live in LitShaderLibrary.
const BlendMode = LitShaderLibrary.BlendMode
const TextureSizeMode = LitShaderLibrary.TextureSizeMode
const ShadowAlgorithm = LitShaderLibrary.ShadowAlgorithm

@export var enabled: bool = true
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Falloff")
## Radius of influence in pixels; drives attenuation and AABB culling.
@export var range: float = 256.0
## Attenuation curve exponent.
@export var falloff: float = 1.0

@export_group("Texture")
## Optional cookie: modulates the light and composes with the cone, centered on the
## node and rotating with it. RGB tints, alpha shapes; outside the texture the light
## is dark. Clipped to `range`.
@export var texture: Texture2D
## Multiplier on the cookie's footprint.
@export var texture_scale: float = 1.0
## NATIVE: the cookie spans the texture's pixel size and follows node scale.
## FIT_RANGE: it spans the `range` footprint and ignores node scale.
@export var texture_size_mode: TextureSizeMode = TextureSizeMode.NATIVE
## Slides the cookie off the node's center, in the texture's local pixels: it rotates
## with the node (and in NATIVE mode scales with it). The cone, falloff, shadows, and
## shading stay centered on the node, so animating this reads as the fixture swinging.
## The cookie still clips at `range`.
@export var texture_offset: Vector2 = Vector2.ZERO

@export_group("Cone")
## Half-angle from the aim direction to the cone edge, in degrees.
@export_range(0.0, 90.0) var spot_angle: float = 30.0
## Edge feather: 0 = hard cone edge, 1 = fades all the way from the center.
@export_range(0.0, 1.0) var spot_softness: float = 0.5

@export_group("Shading")
## Z-height above the surface; drives normal-mapped shading direction.
@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false
## Occluders cast this light's shadows only if their Occluder Light Mask (tileset
## occlusion layers: Light Mask) shares a bit with this mask.
@export_flags_2d_render var shadow_mask: int = 1:
	set(value):
		shadow_mask = value
		if value != 1:
			LitLightRegistry.light_masks_seen = true
## Occluders in this light's own scene (its owner's subtree) never cast its shadows.
@export var exclude_scene_occluders: bool = false:
	set(value):
		exclude_scene_occluders = value
		if value:
			LitLightRegistry.light_masks_seen = true
## CONE_TRACED (the default): a single signed-coverage cone march - penumbras widen
## with distance, umbras taper closed, and an antumbra re-brightens, all driven
## physically by `source_radius`. RAYMARCHED: the classic estimated-penumbra march -
## fastest, stylized, hardness-driven. STOCHASTIC: splits the source into
## `shadow_samples` sub-cones for ground-truth area shadows (correct even with several
## occluders sharing one penumbra) - the most expensive option. Every Lit receiver in
## the scene is swapped to a shader variant compiled for the algorithms in use
## automatically (by the registry each frame).
@export var shadow_algorithm: ShadowAlgorithm = ShadowAlgorithm.CONE_TRACED:
	set(value):
		shadow_algorithm = value
		notify_property_list_changed()
@export var shadow_color: Color = Color.BLACK
## RAYMARCHED: 0 = very soft, 1 = hard. CONE_TRACED / STOCHASTIC: penumbra contrast -
## 0.5 is physically neutral, lower flattens the gradient, higher sharpens it.
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5
## Caps each shadow at this fraction of the fragment's distance to the light; the
## shadow closes there through a natural penumbral tip. Shadows stretch with an
## occluder's distance from the light, reading like a light hung above the ground.
## 1 = shadows reach all the way to the light (the default).
@export_range(0.01, 1.0, 0.001) var shadow_length: float = 1.0
## Radius of the physical emitting disc in world pixels (CONE_TRACED / STOCHASTIC).
## Bigger sources cast softer shadows: wider penumbras and shorter umbras — an
## occluder's dark core tapers closed after roughly (occluder width / source_radius) x
## its distance to the light, so radii comparable to your occluders give clearly
## visible soft-light behavior. Distinct from `range`, which is how far the light
## reaches.
@export_range(0.0, 256.0, 0.5, "or_greater") var source_radius: float = 32.0
## Shadow marches per fragment across the source disc (STOCHASTIC): more is smoother
## and slower. Clamped by lit/quality/shadow_samples_max.
@export_range(1, 32) var shadow_samples: int = 8
## STOCHASTIC dither inside each stratum. Samples are fractional sub-cone coverages,
## so any setting is smooth (no binary noise); the default is just enough dither to
## erase the faint per-stratum wedges a very wide/near source can show. 0 = fully
## deterministic, 1 = maximum per-pixel dither (fine grain).
@export_range(0.0, 1.0) var shadow_jitter: float = 0.35

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD


func _validate_property(property: Dictionary) -> void:
	LitShaderLibrary.validate_light_property(property, shadow_algorithm, "source_radius")


func _enter_tree() -> void:
	add_to_group("lit_lights")


func _exit_tree() -> void:
	remove_from_group("lit_lights")
