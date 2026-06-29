@tool
@icon("res://addons/lit/icons/lit_sprite_2d.svg")
extends Sprite2D
class_name LitSprite2D

## A Sprite2D that ships pre-wired with the lit_receiver ShaderMaterial and a
## CanvasTexture, so its diffuse/normal/specular slots show up in the inspector right
## away and it's lit by Lit with no manual setup. This is the from-scratch path; the
## "Make Selected Nodes Lit" editor tool is the batch path for existing art. It is just
## a shortcut, equivalent to assigning the receiver material to a plain Sprite2D by hand.
##
## Exposes the receiver shader's per-instance parameters as @exports. These are pure
## VIEWS over the material's shader parameters: the setter writes to the material, the
## getter reads it back, and there is deliberately NO backing field. The material's
## shader_parameter/* entries are the single source of truth and the only thing persisted.
##
## Why no backing field: a @tool export with a backing field is re-assigned by the scene
## deserializer on every load, AFTER the saved material has been applied, and that
## assignment fires the setter (documented Godot behaviour). With a backing field the node
## would carry its own copy of the value — at the export default unless separately saved —
## and stamp that default back onto the freshly-loaded material, wiping the saved
## shader_parameter and dropping the line on the next save. A view with no storage has no
## stale copy to write, so the material's saved value survives load untouched.

# Loaded lazily in _init rather than via a top-level `const preload`. Because this script
# has a `class_name`, the editor parses it at startup to build the global class list, and a
# `preload` const would compile the receiver shader right then, before the plugin's
# _enter_tree has registered the lit_* global uniforms. On a fresh install that produces a
# benign "Global uniform does not exist" error. Deferring to _init means the shader isn't
# compiled until a LitSprite2D is actually instantiated, by which point the globals exist.
const RECEIVER_SHADER_PATH := "res://addons/lit/shaders/lit_receiver.gdshader"

# Per-parameter defaults, matching the uniform defaults declared in lit_receiver.gdshader.
# Used by the getters when the material hasn't set a value yet, and by _init to seed a
# freshly created material. Keeping them here in one place keeps the views in sync with
# the shader.
const _DEFAULTS := {
	"emissive_strength": 0.0,
	"transmission_strength": 0.0,
	"transmission_color": Color.WHITE,
	"transmission_wrap": 0.5,
	"transmission_alpha_amount": 0.0,
	"internal_strength": 0.0,
	"internal_k": 96.0,
	"absorption_strength": 0.0,
	"absorption_color": Color(0.2, 0.0, 0.15),
	"dispersion_amount": 0.0,
	"refraction_strength": 0.0,
	"refraction_amount": 0.03,
	"refraction_tint": 0.6,
	"receiver_mask": 1,
}

## Emissive strength: these pixels ignore the dark. View over the material's
## `emissive_strength` uniform.
@export var emissive_strength: float:
	set(value): _set_param("emissive_strength", value)
	get: return _get_param("emissive_strength")

## Translucency strength: how strongly Lit lights glow through this sprite from the far
## side. 0 is opaque (no transmission). View over `transmission_strength`.
@export var transmission_strength: float:
	set(value): _set_param("transmission_strength", value)
	get: return _get_param("transmission_strength")

## Internal tint of transmitted light, e.g. the body color of a gem. View over
## `transmission_color`.
@export var transmission_color: Color:
	set(value): _set_param("transmission_color", value)
	get: return _get_param("transmission_color")

## 0.0 = only the edge facing away from the light glows; 1.0 = the whole body glows
## evenly. Mid values read as a gem. View over `transmission_wrap`.
@export_range(0.0, 1.0) var transmission_wrap: float:
	set(value): _set_param("transmission_wrap", value)
	get: return _get_param("transmission_wrap")

## How strongly the transmission map's green channel drives per-pixel alpha. 0 keeps the
## sprite's own texture alpha (opaque metal stays opaque); 1 lets glass pixels go
## see-through. View over `transmission_alpha_amount`.
@export_range(0.0, 1.0) var transmission_alpha_amount: float:
	set(value): _set_param("transmission_alpha_amount", value)
	get: return _get_param("transmission_alpha_amount")

## Internal reflections: strength of the second, tighter specular lobe that glints off the
## gem's INTERNAL facets (driven by internal_normal_map), giving a cut-stone sparkle that
## walks across the body as a light moves. 0 is off (no cost). View over `internal_strength`.
@export var internal_strength: float:
	set(value): _set_param("internal_strength", value)
	get: return _get_param("internal_strength")

## Facet normal map for the internal glints, in tangent space. Distinct from the
## CanvasTexture normal that shades the surface -- the internal facets face their own way.
## Leave null to use the shader's flat fallback (then internal_strength alone does nothing
## visible). Written straight through to the `internal_normal_map` shader param.
@export var internal_normal_map: Texture2D:
	set(value): _set_param("internal_normal_map", value)
	get: return _get_param("internal_normal_map")

## Tightness of the internal glints: higher = smaller, sharper, more sparkle-like. Kept
## separate from the surface specular sharpness. View over `internal_k`.
@export var internal_k: float:
	set(value): _set_param("internal_k", value)
	get: return _get_param("internal_k")

## Depth absorption: how strongly thicker parts of the body deepen toward absorption_color
## and darken, giving the gem visible volume in a still frame (Beer-Lambert style). Driven by
## the transmission map's B-channel depth. 0 is off. View over `absorption_strength`.
@export_range(0.0, 1.0) var absorption_strength: float:
	set(value): _set_param("absorption_strength", value)
	get: return _get_param("absorption_strength")

## The colour the body deepens toward with thickness. A saturated, dark version of the gem's
## hue reads best. View over `absorption_color`.
@export var absorption_color: Color:
	set(value): _set_param("absorption_color", value)
	get: return _get_param("absorption_color")

## Gem fire: how far the internal glints split into spectral colour at their fringe. 0 is no
## dispersion (monochrome glint); higher fans the hotspot edge into rainbow. Has no effect
## unless internal_strength > 0. View over `dispersion_amount`.
@export_range(0.0, 1.0) var dispersion_amount: float:
	set(value): _set_param("dispersion_amount", value)
	get: return _get_param("dispersion_amount")

## Refraction: bend the background behind the gem using the internal facet normal as the
## offset direction (the cheap "option 2" fake -- no view ray traced). 0 is off (no screen
## sample, no cost). Needs a BackBufferCopy before this sprite in draw order so there's a
## rendered scene to sample. Reads best over a bright or busy background; near-black scenes
## have little to bend. View over `refraction_strength`.
@export_range(0.0, 1.0) var refraction_strength: float:
	set(value): _set_param("refraction_strength", value)
	get: return _get_param("refraction_strength")

## Max background shift at full facet tilt, in screen-UV units. Small (0.01-0.05) reads as a
## dense stone; large smears the scene. Scaled per-fragment by the internal normal's tilt, so
## steep facets push hardest. View over `refraction_amount`.
@export_range(0.0, 0.2) var refraction_amount: float:
	set(value): _set_param("refraction_amount", value)
	get: return _get_param("refraction_amount")

## How much the bent background is tinted by the gem's body colour on the way through. 0 is
## clear glass; 1 is deeply tinted stone. The reference magenta wants this fairly high. View
## over `refraction_tint`.
@export_range(0.0, 1.0) var refraction_tint: float:
	set(value): _set_param("refraction_tint", value)
	get: return _get_param("refraction_tint")

## Which lights affect this receiver: a light contributes only if its light_mask shares
## a bit with this mask. View over `receiver_mask`.
@export_flags_2d_render var receiver_mask: int:
	set(value): _set_param("receiver_mask", value)
	get: return int(_get_param("receiver_mask"))


func _init() -> void:
	# Pre-wire on creation. Only create and seed a material when none exists. A loaded
	# scene assigns its own saved material (with its shader_parameter/* values) AFTER
	# _init; because the @export views have no backing field, the deserializer has no node
	# property to re-stamp, so that saved material is left exactly as loaded.
	if material == null:
		var mat := ShaderMaterial.new()
		mat.shader = load(RECEIVER_SHADER_PATH)
		material = mat
		# Seed the fresh material with the shader's defaults so a brand-new node matches
		# the uniform defaults and the inspector shows them.
		for param in _DEFAULTS:
			_set_param(param, _DEFAULTS[param])
	if texture == null:
		texture = CanvasTexture.new()


func _set_param(param: String, value: Variant) -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(param, value)


func _get_param(param: String) -> Variant:
	if material is ShaderMaterial:
		var v: Variant = (material as ShaderMaterial).get_shader_parameter(param)
		if v != null:
			return v
	# Some params (e.g. the optional internal_normal_map texture) have no seedable default
	# and are legitimately null when unset, so they're absent from _DEFAULTS. Return null
	# rather than indexing a missing key.
	return _DEFAULTS.get(param, null)
