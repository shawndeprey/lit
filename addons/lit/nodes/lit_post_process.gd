@tool
@icon("res://addons/lit/icons/lit_post_process.svg")
extends CanvasLayer
class_name LitPostProcess

## Post-processing chain.
##
## A CanvasLayer that builds an ordered chain of fullscreen passes as internal children:
## one child CanvasLayer per enabled pass, each holding a fullscreen ColorRect with that
## pass's shader, reading the frame via hint_screen_texture. No BackBufferCopy is needed.
## hint_screen_texture reads the screen as drawn so far, and the per-pass CanvasLayer
## boundary makes each pass re-read the accumulated result, so passes compose in order.
## The children are internal (not saved to the scene) and rebuilt from the enabled-pass
## toggles.
##
## Placement: set this node's `layer` above your Lit receivers and below your UI. Pass
## child-layers increment from this node's `layer`, so wherever you park it the passes
## stay above it and in order.
##
## Passes always run in a fixed order, regardless of inspector order:
##   threshold, bloom, halation, glitch, grade, lut, pixelate, posterize, outline,
##   halftone, dither, letterbox, lens, vhs, crt, aberration, leaks, grain, vignette,
##   focus.
## Lower layers render first, so each pass reads the result of the ones before it. The
## order follows a signal-to-display pipeline: correct and glow the image, grade its
## color, stylize it, then matte it and run it through the display medium (tape, then
## tube, then film grain). Letterbox sits at the content/display boundary, so the
## display passes render over the bars.

const GRADE_SHADER := preload("res://addons/lit/shaders/post/lit_post_grade.gdshader")
const THRESHOLD_SHADER := preload("res://addons/lit/shaders/post/lit_post_threshold.gdshader")
const VIGNETTE_SHADER := preload("res://addons/lit/shaders/post/lit_post_vignette.gdshader")
const BLOOM_SHADER := preload("res://addons/lit/shaders/post/lit_post_bloom.gdshader")
const LUT_SHADER := preload("res://addons/lit/shaders/post/lit_post_lut.gdshader")
const CRT_SHADER := preload("res://addons/lit/shaders/post/lit_post_crt.gdshader")
const VHS_SHADER := preload("res://addons/lit/shaders/post/lit_post_vhs.gdshader")
const GRAIN_SHADER := preload("res://addons/lit/shaders/post/lit_post_grain.gdshader")
const ABERRATION_SHADER := preload("res://addons/lit/shaders/post/lit_post_aberration.gdshader")
const OUTLINE_SHADER := preload("res://addons/lit/shaders/post/lit_post_outline.gdshader")
const HALATION_SHADER := preload("res://addons/lit/shaders/post/lit_post_halation.gdshader")
const LETTERBOX_SHADER := preload("res://addons/lit/shaders/post/lit_post_letterbox.gdshader")
const POSTERIZE_SHADER := preload("res://addons/lit/shaders/post/lit_post_posterize.gdshader")
const PIXELATE_SHADER := preload("res://addons/lit/shaders/post/lit_post_pixelate.gdshader")
const HALFTONE_SHADER := preload("res://addons/lit/shaders/post/lit_post_halftone.gdshader")
const DITHER_SHADER := preload("res://addons/lit/shaders/post/lit_post_dither.gdshader")
const LENS_SHADER := preload("res://addons/lit/shaders/post/lit_post_lens_distortion.gdshader")
const LIGHT_LEAKS_SHADER := preload("res://addons/lit/shaders/post/lit_post_light_leaks.gdshader")
const GLITCH_SHADER := preload("res://addons/lit/shaders/post/lit_post_glitch.gdshader")
const FOCUS_SHADER := preload("res://addons/lit/shaders/post/lit_post_focus.gdshader")
const PASS_META := "lit_post_pass"

## Baked-in LUT presets. The PRESET_LUTS entries are parallel to this enum order.
enum LutPreset { NEUTRAL, WARM, COOL, SEPIA, NOIR, TEAL_ORANGE, VINTAGE, VIBRANT }
const PRESET_LUTS := [
	preload("res://addons/lit/luts/lit_lut_neutral.png"),
	preload("res://addons/lit/luts/lit_lut_warm.png"),
	preload("res://addons/lit/luts/lit_lut_cool.png"),
	preload("res://addons/lit/luts/lit_lut_sepia.png"),
	preload("res://addons/lit/luts/lit_lut_noir.png"),
	preload("res://addons/lit/luts/lit_lut_teal_orange.png"),
	preload("res://addons/lit/luts/lit_lut_vintage.png"),
	preload("res://addons/lit/luts/lit_lut_vibrant.png"),
]

@export_group("Threshold")
@export var threshold_enabled: bool = false:
	set(value):
		threshold_enabled = value
		_rebuild()
## Luma below this fades to black (with a short soft knee); brighter pixels pass.
@export_range(0.0, 1.0, 0.01) var threshold_cutoff: float = 0.5:
	set(value):
		threshold_cutoff = value
		_apply_params()

@export_group("Bloom")
@export var bloom_enabled: bool = false:
	set(value):
		bloom_enabled = value
		_rebuild()
## Luma above this blooms. The screen is LDR, so the useful range is about 0.4 to 0.8.
@export_range(0.0, 1.0, 0.01) var bloom_threshold: float = 0.7:
	set(value):
		bloom_threshold = value
		_apply_params()
## Glow strength added on top of the frame. Crank past 1 for heavy fantasy bloom.
@export_range(0.0, 4.0, 0.01, "or_greater") var bloom_intensity: float = 0.5:
	set(value):
		bloom_intensity = value
		_apply_params()
## Glow width: spreads the sampled mip levels. Larger is wider and softer.
@export_range(0.0, 8.0, 0.01, "or_greater") var bloom_radius: float = 4.0:
	set(value):
		bloom_radius = value
		_apply_params()

@export_group("Halation")
## Warm red-leaning halo around highlights (film companion to bloom). Applied with
## bloom, before color grading.
@export var halation_enabled: bool = false:
	set(value):
		halation_enabled = value
		_rebuild()
## Luma above this halates. The screen is LDR, so the useful range is about 0.4 to 0.8.
@export_range(0.0, 1.0, 0.01) var halation_threshold: float = 0.6:
	set(value):
		halation_threshold = value
		_apply_params()
## Halo strength added on top of the frame.
@export_range(0.0, 4.0, 0.01, "or_greater") var halation_intensity: float = 0.6:
	set(value):
		halation_intensity = value
		_apply_params()
## Halo width: spreads the sampled mip levels. Larger is wider and softer.
@export_range(0.0, 8.0, 0.01, "or_greater") var halation_radius: float = 5.0:
	set(value):
		halation_radius = value
		_apply_params()
## Halo color. Warm red-orange by default, the classic film halation hue.
@export var halation_tint: Color = Color(1.0, 0.25, 0.1, 1.0):
	set(value):
		halation_tint = value
		_apply_params()

@export_group("Glitch")
## Intermittent digital corruption: horizontal tearing, RGB split, datamosh-lite block
## jumps, flicker. Animated. Runs before color grade (corrupt the signal, then grade).
@export var glitch_enabled: bool = false:
	set(value):
		glitch_enabled = value
		_rebuild()
## How many slices glitch and how far they tear (0 = clean).
@export_range(0.0, 1.0, 0.01) var glitch_intensity: float = 0.5:
	set(value):
		glitch_intensity = value
		_apply_params()
## Glitch slice height, in pixels. Smaller = finer tearing.
@export_range(1.0, 64.0, 1.0, "or_greater") var glitch_block_size: float = 12.0:
	set(value):
		glitch_block_size = value
		_apply_params()
## RGB channel split, in pixels.
@export_range(0.0, 32.0, 0.5, "or_greater") var glitch_rgb_shift: float = 4.0:
	set(value):
		glitch_rgb_shift = value
		_apply_params()
## Reshuffle rate: how many discrete glitch frames per second.
@export_range(0.0, 30.0, 1.0, "or_greater") var glitch_speed: float = 8.0:
	set(value):
		glitch_speed = value
		_apply_params()

@export_group("Color Grade")
@export var grade_enabled: bool = false:
	set(value):
		grade_enabled = value
		_rebuild()                 # toggling a pass changes the chain structure
@export_range(0.0, 4.0, 0.01, "or_greater") var exposure: float = 1.0:
	set(value):
		exposure = value
		_apply_params()            # parameter tweak: push to the live material
@export_range(0.0, 4.0, 0.01, "or_greater") var contrast: float = 1.0:
	set(value):
		contrast = value
		_apply_params()
@export_range(0.0, 2.0, 0.01, "or_greater") var saturation: float = 1.0:
	set(value):
		saturation = value
		_apply_params()
@export var tint: Color = Color.WHITE:
	set(value):
		tint = value
		_apply_params()

@export_group("LUT")
## Apply a color grade through a lookup table (256x16 LUT strip).
@export var lut_enabled: bool = false:
	set(value):
		lut_enabled = value
		_rebuild()
## Which baked-in LUT to use. Ignored when a `lut_custom` texture is assigned.
@export var lut_preset: LutPreset = LutPreset.NEUTRAL:
	set(value):
		lut_preset = value
		_apply_params()
## Optional custom LUT (256x16 strip). When set, it overrides `lut_preset`. Import with
## Filter on, Mipmaps off, Repeat disabled, Lossless.
@export var lut_custom: Texture2D:
	set(value):
		lut_custom = value
		_apply_params()
## Blend between the original and the LUT-graded color (0 = off, 1 = full LUT).
@export_range(0.0, 1.0, 0.01) var lut_amount: float = 1.0:
	set(value):
		lut_amount = value
		_apply_params()

@export_group("Pixelate")
## Snap the image to a coarse grid for a chunky low-res / mosaic look. Runs before the
## other stylize and display passes, so they all read the blocky image.
@export var pixelate_enabled: bool = false:
	set(value):
		pixelate_enabled = value
		_rebuild()
## Block edge in screen pixels. 1 = off, larger = chunkier blocks.
@export_range(1.0, 64.0, 1.0, "or_greater") var pixelate_size: float = 4.0:
	set(value):
		pixelate_size = value
		_apply_params()

@export_group("Posterize")
## Quantize colors into a few flat levels (screen-print / comic look). Runs before
## Edge Outline, so the outline inks the flattened color.
@export var posterize_enabled: bool = false:
	set(value):
		posterize_enabled = value
		_rebuild()
## Discrete steps per channel. 2 = harsh, higher = subtler banding.
@export_range(2.0, 16.0, 1.0, "or_greater") var posterize_levels: float = 4.0:
	set(value):
		posterize_levels = value
		_apply_params()
## Blend between the original and the posterized color.
@export_range(0.0, 1.0, 0.01) var posterize_strength: float = 1.0:
	set(value):
		posterize_strength = value
		_apply_params()

@export_group("Edge Outline")
## Sobel edge detection on luma, inked as a cel/comic outline. Computed before the
## tube/tape passes so edges stay crisp.
@export var outline_enabled: bool = false:
	set(value):
		outline_enabled = value
		_rebuild()
## Outline ink color (alpha scales opacity alongside Outline Strength).
@export var outline_color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		outline_color = value
		_apply_params()
## Sobel tap spacing in pixels. Larger = thicker, coarser outlines.
@export_range(0.5, 8.0, 0.1, "or_greater") var outline_thickness: float = 1.0:
	set(value):
		outline_thickness = value
		_apply_params()
## Edge magnitude needed before any ink shows. Higher = only strong edges.
@export_range(0.0, 1.0, 0.01) var outline_threshold: float = 0.1:
	set(value):
		outline_threshold = value
		_apply_params()
## Anti-alias knee above the threshold (0 = hard line, higher = softer).
@export_range(0.0, 1.0, 0.01) var outline_softness: float = 0.1:
	set(value):
		outline_softness = value
		_apply_params()
## Outline opacity.
@export_range(0.0, 1.0, 0.01) var outline_strength: float = 1.0:
	set(value):
		outline_strength = value
		_apply_params()

@export_group("Halftone")
## Dot-screen the image (comic / newsprint): a rotated grid of ink dots sized by local
## brightness. Runs after Edge Outline, so ink lines survive as solid dots while fills
## break into dots.
@export var halftone_enabled: bool = false:
	set(value):
		halftone_enabled = value
		_rebuild()
## Grid cell / max dot footprint, in screen pixels. Larger = coarser dots.
@export_range(2.0, 32.0, 0.5, "or_greater") var halftone_dot_size: float = 6.0:
	set(value):
		halftone_dot_size = value
		_apply_params()
## Screen rotation, in degrees (classic single-screen halftone is often 15 to 45).
@export_range(0.0, 360.0, 1.0) var halftone_angle: float = 0.0:
	set(value):
		halftone_angle = value
		_apply_params()
## Blend between the original and the dot screen (1 = full halftone).
@export_range(0.0, 1.0, 0.01) var halftone_amount: float = 1.0:
	set(value):
		halftone_amount = value
		_apply_params()
## Dot (ink) color.
@export var halftone_ink_color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		halftone_ink_color = value
		_apply_params()
## Background (paper) color.
@export var halftone_paper_color: Color = Color(1.0, 1.0, 1.0, 1.0):
	set(value):
		halftone_paper_color = value
		_apply_params()

@export_group("Dither")
## Ordered Bayer dithering into a few levels (PICO-8 / 1-bit / Game-Boy look). Runs
## after the edge/print passes since it adds high-frequency detail.
@export var dither_enabled: bool = false:
	set(value):
		dither_enabled = value
		_rebuild()
## Quantization steps per channel. 2 = 1-bit per channel; higher = subtler.
@export_range(2.0, 16.0, 1.0, "or_greater") var dither_levels: float = 4.0:
	set(value):
		dither_levels = value
		_apply_params()
## Bayer cell size in screen pixels. Larger = chunkier dither.
@export_range(1.0, 8.0, 1.0, "or_greater") var dither_scale: float = 1.0:
	set(value):
		dither_scale = value
		_apply_params()
## Collapse to luma first: true 1-bit black and white when levels = 2.
@export var dither_monochrome: bool = false:
	set(value):
		dither_monochrome = value
		_apply_params()
## Blend between the original and the dithered result.
@export_range(0.0, 1.0, 0.01) var dither_strength: float = 1.0:
	set(value):
		dither_strength = value
		_apply_params()

@export_group("Letterbox")
## Cinematic bars top and bottom, the matte on the finished content. Animate
## `letterbox_size` from 0 to ease them in and out for cutscenes. Sits at the
## content/display boundary, so the display passes below (VHS, CRT, etc.) render over
## the bars: the tube curves them, scanlines and grain cross them.
@export var letterbox_enabled: bool = false:
	set(value):
		letterbox_enabled = value
		_rebuild()
## Fraction of screen height covered by EACH bar (0 = none, 0.5 = bars meet center).
@export_range(0.0, 0.5, 0.001) var letterbox_size: float = 0.12:
	set(value):
		letterbox_size = value
		_apply_params()
## Feathered inner edge of the bars (0 = hard edge).
@export_range(0.0, 0.2, 0.001) var letterbox_softness: float = 0.0:
	set(value):
		letterbox_softness = value
		_apply_params()
## Bar color. Black by default; alpha makes the bars translucent.
@export var letterbox_color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		letterbox_color = value
		_apply_params()

@export_group("Lens Distortion")
## Radial barrel / pincushion warp, the device lens. Positive bulges (fisheye),
## negative pinches. Distinct from CRT curvature; stack or use either.
@export var lens_enabled: bool = false:
	set(value):
		lens_enabled = value
		_rebuild()
## + = barrel/bulge (fisheye), - = pincushion/pinch. 0 = flat.
@export_range(-2.0, 2.0, 0.01, "or_greater", "or_less") var lens_amount: float = 0.2:
	set(value):
		lens_amount = value
		_apply_params()
## Scale around center. >1 pushes the warped edges off screen to hide the bezel.
@export_range(0.5, 2.0, 0.01, "or_greater") var lens_zoom: float = 1.0:
	set(value):
		lens_zoom = value
		_apply_params()
## Bezel color shown where the warp pulls the image off screen.
@export var lens_edge_color: Color = Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		lens_edge_color = value
		_apply_params()

@export_group("VHS")
## Worn-tape look: per-line wobble, chroma shift and smear, a rolling tracking-noise
## band, grain, and a slow brightness roll. Animated. Runs before CRT in the chain
## (tape signal, then glass), so enable both for "old tape on an old tube".
@export var vhs_enabled: bool = false:
	set(value):
		vhs_enabled = value
		_rebuild()
## Per-line horizontal jitter, in pixels.
@export_range(0.0, 16.0, 0.1, "or_greater") var vhs_wobble_strength: float = 2.0:
	set(value):
		vhs_wobble_strength = value
		_apply_params()
## How fast the jitter reshuffles.
@export_range(0.0, 20.0, 0.1, "or_greater") var vhs_wobble_speed: float = 4.0:
	set(value):
		vhs_wobble_speed = value
		_apply_params()
## R/B horizontal split, in pixels.
@export_range(0.0, 16.0, 0.1, "or_greater") var vhs_chroma_shift: float = 2.0:
	set(value):
		vhs_chroma_shift = value
		_apply_params()
## Horizontal chroma smear (0 = crisp, 1 = full trailing bleed).
@export_range(0.0, 1.0, 0.01) var vhs_bleed: float = 0.5:
	set(value):
		vhs_bleed = value
		_apply_params()
## Animated static-noise overlay.
@export_range(0.0, 1.0, 0.01) var vhs_grain: float = 0.12:
	set(value):
		vhs_grain = value
		_apply_params()
## Severity of the rolling damaged band (0 = none).
@export_range(0.0, 1.0, 0.01) var vhs_tracking_strength: float = 0.6:
	set(value):
		vhs_tracking_strength = value
		_apply_params()
## How fast the tracking band rolls up the screen (0 = parked).
@export_range(0.0, 2.0, 0.01, "or_greater") var vhs_tracking_speed: float = 0.2:
	set(value):
		vhs_tracking_speed = value
		_apply_params()
## Strength of the slow vertical brightness roll.
@export_range(0.0, 1.0, 0.01) var vhs_roll_strength: float = 0.1:
	set(value):
		vhs_roll_strength = value
		_apply_params()

@export_group("CRT")
## Old-tube look: barrel curvature + scanlines + RGB aperture mask + edge vignette
## + slight chromatic aberration. A steady (non-animated) effect; pair with VHS for
## motion artifacts.
@export var crt_enabled: bool = false:
	set(value):
		crt_enabled = value
		_rebuild()
## Barrel bulge toward the edges. 0 = flat glass.
@export_range(0.0, 1.0, 0.01, "or_greater") var crt_curvature: float = 0.2:
	set(value):
		crt_curvature = value
		_apply_params()
## How dark the scanline troughs get (0 = none, 1 = black lines).
@export_range(0.0, 1.0, 0.01) var crt_scanline_strength: float = 0.3:
	set(value):
		crt_scanline_strength = value
		_apply_params()
## Number of scanline pairs down the screen. Lower = chunkier / more retro.
@export_range(0.0, 1080.0, 1.0, "or_greater") var crt_scanline_count: float = 240.0:
	set(value):
		crt_scanline_count = value
		_apply_params()
## Depth of the R/G/B phosphor stripe mask. 0 = off.
@export_range(0.0, 1.0, 0.01) var crt_mask_strength: float = 0.3:
	set(value):
		crt_mask_strength = value
		_apply_params()
## Max RGB split at the edges, in pixels.
@export_range(0.0, 8.0, 0.1, "or_greater") var crt_aberration: float = 1.5:
	set(value):
		crt_aberration = value
		_apply_params()
## Edge darkening from the tube falloff. 0 = none.
@export_range(0.0, 1.0, 0.01) var crt_vignette: float = 0.3:
	set(value):
		crt_vignette = value
		_apply_params()
## Brightness lift to offset the darkening from the mask and scanlines.
@export_range(0.0, 2.0, 0.01, "or_greater") var crt_brightness: float = 1.2:
	set(value):
		crt_brightness = value
		_apply_params()

@export_group("Chromatic Aberration")
## Radial RGB lens fringe that grows toward the screen edges; center stays sharp.
@export var aberration_enabled: bool = false:
	set(value):
		aberration_enabled = value
		_rebuild()
## Max R/B split at the corners, in pixels.
@export_range(0.0, 16.0, 0.1, "or_greater") var aberration_amount: float = 3.0:
	set(value):
		aberration_amount = value
		_apply_params()
## Edge concentration. Higher keeps the center sharper and pushes the fringe outward.
@export_range(0.0, 6.0, 0.1, "or_greater") var aberration_edge_falloff: float = 2.0:
	set(value):
		aberration_edge_falloff = value
		_apply_params()

@export_group("Light Leaks")
## Soft animated colored glows bleeding from the edges (film light-leak look).
## Procedural by default; assign a Leak Texture to drive it from your own scrolling
## gradient instead. Screen-blended over the image.
@export var leaks_enabled: bool = false:
	set(value):
		leaks_enabled = value
		_rebuild()
## Overall leak strength.
@export_range(0.0, 2.0, 0.01, "or_greater") var leaks_intensity: float = 0.6:
	set(value):
		leaks_intensity = value
		_apply_params()
## Animation drift / pulse speed (0 = frozen).
@export_range(0.0, 4.0, 0.01, "or_greater") var leaks_speed: float = 1.0:
	set(value):
		leaks_speed = value
		_apply_params()
## First (warm) leak color. Ignored when a Leak Texture is assigned.
@export var leaks_color1: Color = Color(1.0, 0.5, 0.2, 1.0):
	set(value):
		leaks_color1 = value
		_apply_params()
## Second (red) leak color. Ignored when a Leak Texture is assigned.
@export var leaks_color2: Color = Color(1.0, 0.2, 0.3, 1.0):
	set(value):
		leaks_color2 = value
		_apply_params()
## Optional override: a scrolling gradient texture replaces the procedural leaks.
## Import with Filter on, Repeat enabled.
@export var leaks_texture: Texture2D:
	set(value):
		leaks_texture = value
		_apply_params()

@export_group("Film Grain")
## Animated film-grain noise over the final image. Cheap, pairs with everything.
@export var grain_enabled: bool = false:
	set(value):
		grain_enabled = value
		_rebuild()
## Grain amount.
@export_range(0.0, 0.5, 0.001, "or_greater") var grain_intensity: float = 0.05:
	set(value):
		grain_intensity = value
		_apply_params()
## Grain cell size in pixels. 1 = per-pixel; larger = chunkier, coarser grain.
@export_range(1.0, 8.0, 0.1, "or_greater") var grain_size: float = 1.0:
	set(value):
		grain_size = value
		_apply_params()
## How much grain fades toward black/white (0 = uniform, 1 = midtones only).
@export_range(0.0, 1.0, 0.01) var grain_luminance_response: float = 0.5:
	set(value):
		grain_luminance_response = value
		_apply_params()
## Monochrome film grain (off) vs. per-channel RGB sparkle (on).
@export var grain_colored: bool = false:
	set(value):
		grain_colored = value
		_apply_params()

@export_group("Vignette")
@export var vignette_enabled: bool = false:
	set(value):
		vignette_enabled = value
		_rebuild()
## How dark the edges get (0 = none, 1 = corners crushed to black).
@export_range(0.0, 1.0, 0.01) var vignette_strength: float = 0.4:
	set(value):
		vignette_strength = value
		_apply_params()
## Feather width of the vignette ramp (0 = tight to the corners, 1 = from center).
@export_range(0.0, 1.0, 0.01) var vignette_softness: float = 0.5:
	set(value):
		vignette_softness = value
		_apply_params()

@export_group("Focus")
## The final focus dial: negative = soft / dream blur, positive = sharpen. Runs last,
## on the completed image.
@export var focus_enabled: bool = false:
	set(value):
		focus_enabled = value
		_rebuild()
## < 0 = soft / dream blur, > 0 = sharpen, 0 = off.
@export_range(-1.0, 1.0, 0.01, "or_greater", "or_less") var focus_amount: float = -0.5:
	set(value):
		focus_amount = value
		_apply_params()
## Blur reach (mip level). About 1 for sharpen, 2 to 4 for a wide dream blur.
@export_range(0.0, 6.0, 0.1, "or_greater") var focus_radius: float = 2.0:
	set(value):
		focus_radius = value
		_apply_params()
## Soft side only: hazy highlight glow blended back in for the dreamy look.
@export_range(0.0, 1.0, 0.01) var focus_dream: float = 0.2:
	set(value):
		focus_dream = value
		_apply_params()

# The chain, in its fixed render order (the class doc explains the rationale): one
# row per pass with its enabled-gate property, shader, and shader_param -> property
# map. _rebuild and _apply_params iterate this; adding a pass is one row here plus
# its @export block above. Letterbox marks the content/display boundary; the display
# media (lens, vhs, crt, aberration, leaks, grain, vignette, focus) follow it.
const PASS_DEFS := [
	{"key": "threshold", "enabled": "threshold_enabled", "shader": THRESHOLD_SHADER,
		"params": {"cutoff": "threshold_cutoff"}},
	{"key": "bloom", "enabled": "bloom_enabled", "shader": BLOOM_SHADER,
		"params": {"threshold": "bloom_threshold", "intensity": "bloom_intensity",
			"bloom_radius": "bloom_radius"}},
	{"key": "halation", "enabled": "halation_enabled", "shader": HALATION_SHADER,
		"params": {"threshold": "halation_threshold", "intensity": "halation_intensity",
			"halation_radius": "halation_radius", "tint": "halation_tint"}},
	{"key": "glitch", "enabled": "glitch_enabled", "shader": GLITCH_SHADER,
		"params": {"intensity": "glitch_intensity", "block_size": "glitch_block_size",
			"rgb_shift": "glitch_rgb_shift", "speed": "glitch_speed"}},
	{"key": "grade", "enabled": "grade_enabled", "shader": GRADE_SHADER,
		"params": {"exposure": "exposure", "contrast": "contrast",
			"saturation": "saturation", "tint": "tint"}},
	{"key": "lut", "enabled": "lut_enabled", "shader": LUT_SHADER,
		"params": {"amount": "lut_amount"}},
	{"key": "pixelate", "enabled": "pixelate_enabled", "shader": PIXELATE_SHADER,
		"params": {"pixel_size": "pixelate_size"}},
	{"key": "posterize", "enabled": "posterize_enabled", "shader": POSTERIZE_SHADER,
		"params": {"levels": "posterize_levels", "strength": "posterize_strength"}},
	{"key": "outline", "enabled": "outline_enabled", "shader": OUTLINE_SHADER,
		"params": {"outline_color": "outline_color", "thickness": "outline_thickness",
			"threshold": "outline_threshold", "softness": "outline_softness",
			"strength": "outline_strength"}},
	{"key": "halftone", "enabled": "halftone_enabled", "shader": HALFTONE_SHADER,
		"params": {"dot_size": "halftone_dot_size", "angle": "halftone_angle",
			"amount": "halftone_amount", "ink_color": "halftone_ink_color",
			"paper_color": "halftone_paper_color"}},
	{"key": "dither", "enabled": "dither_enabled", "shader": DITHER_SHADER,
		"params": {"levels": "dither_levels", "scale": "dither_scale",
			"monochrome": "dither_monochrome", "strength": "dither_strength"}},
	{"key": "letterbox", "enabled": "letterbox_enabled", "shader": LETTERBOX_SHADER,
		"params": {"bar_size": "letterbox_size", "softness": "letterbox_softness",
			"bar_color": "letterbox_color"}},
	{"key": "lens", "enabled": "lens_enabled", "shader": LENS_SHADER,
		"params": {"amount": "lens_amount", "zoom": "lens_zoom",
			"edge_color": "lens_edge_color"}},
	{"key": "vhs", "enabled": "vhs_enabled", "shader": VHS_SHADER,
		"params": {"wobble_strength": "vhs_wobble_strength", "wobble_speed": "vhs_wobble_speed",
			"chroma_shift": "vhs_chroma_shift", "bleed": "vhs_bleed", "grain": "vhs_grain",
			"tracking_strength": "vhs_tracking_strength", "tracking_speed": "vhs_tracking_speed",
			"roll_strength": "vhs_roll_strength"}},
	{"key": "crt", "enabled": "crt_enabled", "shader": CRT_SHADER,
		"params": {"curvature": "crt_curvature", "scanline_strength": "crt_scanline_strength",
			"scanline_count": "crt_scanline_count", "mask_strength": "crt_mask_strength",
			"aberration": "crt_aberration", "vignette": "crt_vignette",
			"brightness": "crt_brightness"}},
	{"key": "aberration", "enabled": "aberration_enabled", "shader": ABERRATION_SHADER,
		"params": {"amount": "aberration_amount", "edge_falloff": "aberration_edge_falloff"}},
	{"key": "leaks", "enabled": "leaks_enabled", "shader": LIGHT_LEAKS_SHADER,
		"params": {"intensity": "leaks_intensity", "speed": "leaks_speed",
			"color1": "leaks_color1", "color2": "leaks_color2",
			"leak_texture": "leaks_texture"}},
	{"key": "grain", "enabled": "grain_enabled", "shader": GRAIN_SHADER,
		"params": {"intensity": "grain_intensity", "grain_size": "grain_size",
			"luminance_response": "grain_luminance_response", "colored": "grain_colored"}},
	{"key": "vignette", "enabled": "vignette_enabled", "shader": VIGNETTE_SHADER,
		"params": {"strength": "vignette_strength", "softness": "vignette_softness"}},
	{"key": "focus", "enabled": "focus_enabled", "shader": FOCUS_SHADER,
		"params": {"amount": "focus_amount", "radius": "focus_radius", "dream": "focus_dream"}},
]

# Generated pass materials by PASS_DEFS key, kept so parameter edits push without a
# rebuild.
var _materials := {}
# The base `layer` the current chain was built against, so an inspector edit to the
# node's layer can re-sync the pass child-layers live (editor only).
var _built_layer: int = 0


func _ready() -> void:
	_rebuild()
	set_process(Engine.is_editor_hint())
	# Hiding this node should stop post-processing. The passes live in their own child
	# CanvasLayers, which don't inherit a parent CanvasLayer's visibility, so mirror it.
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	for child in get_children(true):
		if child.has_meta(PASS_META):
			(child as CanvasLayer).visible = visible


func _process(_delta: float) -> void:
	# Editor-only: keep pass layers ordered relative to the node if `layer` is edited.
	if layer != _built_layer:
		_rebuild()


## Tear down the generated pass chain and rebuild it from the enabled toggles, in
## PASS_DEFS order. Lower-layer passes render first, so each reads the result of the
## ones before it.
func _rebuild() -> void:
	if not is_inside_tree():
		return
	for child in get_children(true):        # include_internal: our passes are internal
		if child.has_meta(PASS_META):
			remove_child(child)
			child.queue_free()
	_materials.clear()

	var index := 0
	for def in PASS_DEFS:
		if get(def.enabled):
			_materials[def.key] = _make_pass(def.shader, index)
			index += 1

	_built_layer = layer
	_apply_params()


## Build one pass: an internal child CanvasLayer (for ordering + the per-pass screen
## re-read) holding a fullscreen, input-transparent ColorRect with the pass shader.
## Returns the pass material so callers can push parameters to it later.
func _make_pass(shader: Shader, index: int) -> ShaderMaterial:
	var pass_layer := CanvasLayer.new()
	pass_layer.layer = layer + index + 1    # above this node's base layer, in order
	pass_layer.visible = visible            # respect the node's current visibility
	pass_layer.set_meta(PASS_META, true)

	var mat := ShaderMaterial.new()
	mat.shader = shader

	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)   # cover the viewport
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE     # never eat UI input
	rect.material = mat

	pass_layer.add_child(rect)
	add_child(pass_layer, false, Node.INTERNAL_MODE_BACK)
	return mat


## The LUT texture currently in effect: the custom override if one is assigned,
## otherwise the selected baked-in preset.
func _active_lut() -> Texture2D:
	if lut_custom != null:
		return lut_custom
	return PRESET_LUTS[lut_preset]


## Push current parameters onto the generated pass materials (no rebuild needed):
## each pass's shader_param -> property map from PASS_DEFS, plus the two derived
## params below it.
func _apply_params() -> void:
	for def in PASS_DEFS:
		var mat: ShaderMaterial = _materials.get(def.key)
		if mat == null:
			continue
		for uniform in def.params:
			mat.set_shader_parameter(uniform, get(def.params[uniform]))
	# Derived params (not plain property mirrors).
	var lut_mat: ShaderMaterial = _materials.get("lut")
	if lut_mat != null:
		lut_mat.set_shader_parameter("lut", _active_lut())
	var leaks_mat: ShaderMaterial = _materials.get("leaks")
	if leaks_mat != null:
		leaks_mat.set_shader_parameter("has_texture", leaks_texture != null)
