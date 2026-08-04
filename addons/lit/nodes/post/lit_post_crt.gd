@tool
@icon("res://addons/lit/icons/lit_post_effect.svg")
extends LitPostEffect
class_name LitPostCrt

## Old-tube look: barrel curvature + scanlines + RGB aperture mask + edge vignette
## + slight chromatic aberration. A steady (non-animated) effect; pair with VHS for
## motion artifacts.

const SHADER := preload("res://addons/lit/shaders/post/lit_post_crt.gdshader")

## Barrel bulge toward the edges. 0 = flat glass.
@export_range(0.0, 1.0, 0.01, "or_greater") var curvature: float = 0.2:
	set(value):
		curvature = value
		apply_params()
## How dark the scanline troughs get (0 = none, 1 = black lines).
@export_range(0.0, 1.0, 0.01) var scanline_strength: float = 0.3:
	set(value):
		scanline_strength = value
		apply_params()
## Number of scanline pairs down the screen. Lower = chunkier / more retro.
@export_range(0.0, 1080.0, 1.0, "or_greater") var scanline_count: float = 240.0:
	set(value):
		scanline_count = value
		apply_params()
## Depth of the R/G/B phosphor stripe mask. 0 = off.
@export_range(0.0, 1.0, 0.01) var mask_strength: float = 0.3:
	set(value):
		mask_strength = value
		apply_params()
## Max RGB split at the edges, in pixels.
@export_range(0.0, 8.0, 0.1, "or_greater") var aberration: float = 1.5:
	set(value):
		aberration = value
		apply_params()
## Edge darkening from the tube falloff. 0 = none.
@export_range(0.0, 1.0, 0.01) var vignette: float = 0.3:
	set(value):
		vignette = value
		apply_params()
## Brightness lift to offset the darkening from the mask and scanlines.
@export_range(0.0, 2.0, 0.01, "or_greater") var brightness: float = 1.2:
	set(value):
		brightness = value
		apply_params()


func _shader() -> Shader:
	return SHADER


func _rank() -> int:
	return 150


func _param_map() -> Dictionary:
	return {"curvature": "curvature", "scanline_strength": "scanline_strength",
		"scanline_count": "scanline_count", "mask_strength": "mask_strength",
		"aberration": "aberration", "vignette": "vignette", "brightness": "brightness"}
