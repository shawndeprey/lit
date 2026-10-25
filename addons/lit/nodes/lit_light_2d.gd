@tool
@abstract
extends Node2D
class_name LitLight2D

## Base of every Lit light: shared properties, registry wiring and Godot's Light2D
## method names. set_item_cull_mask() writes CanvasItem's `light_mask` (a receiver is
## lit when its `receiver_mask` shares a bit), set_item_shadow_cull_mask() writes
## `shadow_mask`. Lights draw nothing; the registry packs the `lit_lights` group each frame.

# Definitions live in LitShaderLibrary.
const BlendMode = LitShaderLibrary.BlendMode
const ShadowAlgorithm = LitShaderLibrary.ShadowAlgorithm

# See LitVersionStamp.
@export_storage var lit_version := ""

@export var enabled: bool = true:
	set(value):
		enabled = value
		LitLightRegistry.light_state_changed(self)
@export var color: Color = Color.WHITE
@export var energy: float = 1.0

@export_group("Shading")
## Height of the light above the surface; drives the normal-mapped shading direction.
## Lower values graze the surface (direction reads strongly), higher values face it
## head-on. Not affected by node scale (as in Godot).
@export var height: float = 16.0

@export_group("Shadow")
@export var shadow_enabled: bool = false:
	set(value):
		shadow_enabled = value
		LitLightRegistry.light_state_changed(self)
## Occluders cast this light's shadows only if their Occluder Light Mask (tileset
## occlusion layers: Light Mask) shares a bit with this mask.
@export_flags_2d_render var shadow_mask: int = 1:
	set(value):
		shadow_mask = value
		if value != 1:
			LitLightRegistry.light_masks_seen = true
		LitLightRegistry.light_state_changed(self)
## Occluders in this light's own scene (its owner's subtree) never cast its shadows.
@export var exclude_scene_occluders: bool = false:
	set(value):
		exclude_scene_occluders = value
		if value:
			LitLightRegistry.light_masks_seen = true
		LitLightRegistry.light_state_changed(self)
## How this light marches its shadows; the penumbra shape follows `source_radius`
## (`source_angle` on a directional light). Every Lit receiver in the scene is swapped
## to a shader variant compiled for the algorithms in use automatically (by the
## registry each frame).
@export var shadow_algorithm: ShadowAlgorithm = ShadowAlgorithm.CONE_TRACED:
	set(value):
		shadow_algorithm = value
		notify_property_list_changed()
		LitLightRegistry.light_state_changed(self)
@export var shadow_color: Color = Color.BLACK
## RAYMARCHED: 0 = very soft, 1 = hard. CONE_TRACED / STOCHASTIC: penumbra contrast -
## 0.5 is physically neutral, lower flattens the gradient, higher sharpens it.
@export_range(0.0, 1.0) var shadow_hardness: float = 0.5
## Shadow marches per fragment across the source (STOCHASTIC, and a line light's
## CONE_TRACED): more is smoother and slower. Clamped by lit/quality/shadow_samples_max.
@export_range(1, 32) var shadow_samples: int = 8
## STOCHASTIC dither inside each stratum. Samples are fractional sub-cone coverages,
## so any setting is smooth (no binary noise); the default is just enough dither to
## erase the faint per-stratum wedges a very wide/near source can show. 0 = fully
## deterministic, 1 = maximum per-pixel dither (fine grain).
@export_range(0.0, 1.0) var shadow_jitter: float = 0.35

@export_group("Advanced")
@export var blend_mode: BlendMode = BlendMode.ADD
## Lowest z_index this light reaches. A receiver is lit only while its final z_index
## (z_as_relative offsets summed up its parents) lies between Range Z Min and Range Z
## Max. The default spans the whole canvas range (Godot's Light2D defaults to
## -1024..1024). Lit receiver nodes read their z when they enter the tree; after
## changing z_index at runtime call refresh_light_ranges() on the receiver, or
## LitLightRegistry.refresh_light_ranges() on a subtree.
@export_range(-4096, 4096) var range_z_min: int = -4096:
	set(value):
		range_z_min = value
		_update_ranged()
## Highest z_index this light reaches (see Range Z Min).
@export_range(-4096, 4096) var range_z_max: int = 4096:
	set(value):
		range_z_max = value
		_update_ranged()
## Lowest CanvasLayer this light reaches. A receiver is lit only while the index of its
## CanvasLayer (0 on the base canvas) lies between Range Layer Min and Range Layer Max.
## The default spans every layer, which is how Lit has always behaved; 0..0 lights the
## base canvas only, as Godot's Light2D does by default.
@export_range(-4096, 4096) var range_layer_min: int = -4096:
	set(value):
		range_layer_min = value
		_update_ranged()
## Highest CanvasLayer this light reaches (see Range Layer Min).
@export_range(-4096, 4096) var range_layer_max: int = 4096:
	set(value):
		range_layer_max = value
		_update_ranged()
# Narrower than pass-all; the packer reads the ranges only then.
var ranged: bool = false
var range_pack := Vector3.ZERO

func _update_ranged() -> void:
	range_pack = LitLightRegistry.LightPackerScript.range_pack(range_z_min, range_z_max,
			range_layer_min, range_layer_max)
	ranged = range_pack.z != 0.0
	if ranged:
		LitLightRegistry.light_ranges_seen = true

func _enter_tree() -> void:
	add_to_group("lit_lights")
	LitVersionStamp.stamp(self)

func _exit_tree() -> void:
	remove_from_group("lit_lights")

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		LitLightRegistry.light_state_changed(self)

# Light2D method names.
func set_enabled(value: bool) -> void:
	enabled = value

func is_enabled() -> bool:
	return enabled

func set_color(value: Color) -> void:
	color = value

func get_color() -> Color:
	return color

func set_energy(value: float) -> void:
	energy = value

func get_energy() -> float:
	return energy

func set_height(value: float) -> void:
	height = value

func get_height() -> float:
	return height

func set_blend_mode(value: BlendMode) -> void:
	blend_mode = value

func get_blend_mode() -> BlendMode:
	return blend_mode

func set_shadow_enabled(value: bool) -> void:
	shadow_enabled = value

func is_shadow_enabled() -> bool:
	return shadow_enabled

func set_shadow_color(value: Color) -> void:
	shadow_color = value

func get_shadow_color() -> Color:
	return shadow_color

func set_item_cull_mask(value: int) -> void:
	light_mask = value

func get_item_cull_mask() -> int:
	return light_mask

func set_item_shadow_cull_mask(value: int) -> void:
	shadow_mask = value

func get_item_shadow_cull_mask() -> int:
	return shadow_mask

func set_z_range_min(value: int) -> void:
	range_z_min = value

func get_z_range_min() -> int:
	return range_z_min

func set_z_range_max(value: int) -> void:
	range_z_max = value

func get_z_range_max() -> int:
	return range_z_max

func set_layer_range_min(value: int) -> void:
	range_layer_min = value

func get_layer_range_min() -> int:
	return range_layer_min

func set_layer_range_max(value: int) -> void:
	range_layer_max = value

func get_layer_range_max() -> int:
	return range_layer_max
