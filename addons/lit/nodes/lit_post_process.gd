@tool
@icon("res://addons/lit/icons/lit_post_process.svg")
extends CanvasLayer
class_name LitPostProcess

## Post-processing chain (plan §7.5, D8).
##
## A CanvasLayer that builds an ordered chain of fullscreen passes as its INTERNAL
## children — one child CanvasLayer per enabled pass, each holding a fullscreen
## ColorRect with that pass's shader, reading the frame via hint_screen_texture.
##
## Chaining WITHOUT BackBufferCopy (deviation from plan D8, same result): sampling
## hint_screen_texture reads the screen as drawn so far, and the per-pass CanvasLayer
## boundary forces each pass to re-read the accumulated result, so passes compose in
## order. The generated children are internal (not saved to the scene) and rebuilt
## from the enabled-pass toggles.
##
## Placement: set this node's `layer` ABOVE your Lit receivers and BELOW your UI /
## menus (e.g. 99 in a project that reserves high layers for post). Pass child-layers
## increment from this node's `layer`, so wherever you park it, passes stay above it
## and in order.
##
## Phase 5: Threshold, Bloom, Color Grade, Vignette. Plus LUT (post-v1, see
## to_do_post_processing.md).
##
## Passes run in a fixed canonical order regardless of inspector order:
## threshold -> bloom -> halation -> glitch -> grade -> lut -> pixelate -> posterize ->
## outline -> halftone -> dither -> letterbox -> lens -> vhs -> crt -> aberration ->
## leaks -> grain -> vignette -> focus. Lower-layer passes render first, so each reads
## the result of the ones before it. (Halation is bloom's warm-halo companion, applied
## with it before grading; glitch corrupts the signal before color, so grading/stylize/
## display all process the glitched image; focus is the final lens — dream blur or
## sharpen on the completed image;
## pixelate blocks the image, posterize flattens the color, outline inks that flattened
## image, halftone dot-screens the result — dark ink lines survive as solid dots while
## fills break into dots — and dither does ordered color reduction; the high-frequency
## stylize passes (halftone/dither) come after outline so edges stay clean; letterbox
## mattes the finished content at the content/display boundary, so the display medium
## below renders over the bars — the tube curves them, scanlines/grain cross them, the
## vignette frames the whole tube; lens distortion is the device lens (first display
## pass, distinct from CRT's curvature); VHS is the tape signal, CRT the glass it's
## watched on, so VHS runs before CRT; aberration is the lens fringe and grain the film.)

const GRADE_SHADER := preload("res://addons/lit/shaders/lit_post_grade.gdshader")
const THRESHOLD_SHADER := preload("res://addons/lit/shaders/lit_post_threshold.gdshader")
const VIGNETTE_SHADER := preload("res://addons/lit/shaders/lit_post_vignette.gdshader")
const BLOOM_SHADER := preload("res://addons/lit/shaders/lit_post_bloom.gdshader")
const LUT_SHADER := preload("res://addons/lit/shaders/lit_post_lut.gdshader")
const CRT_SHADER := preload("res://addons/lit/shaders/lit_post_crt.gdshader")
const VHS_SHADER := preload("res://addons/lit/shaders/lit_post_vhs.gdshader")
const GRAIN_SHADER := preload("res://addons/lit/shaders/lit_post_grain.gdshader")
const ABERRATION_SHADER := preload("res://addons/lit/shaders/lit_post_aberration.gdshader")
const OUTLINE_SHADER := preload("res://addons/lit/shaders/lit_post_outline.gdshader")
const HALATION_SHADER := preload("res://addons/lit/shaders/lit_post_halation.gdshader")
const LETTERBOX_SHADER := preload("res://addons/lit/shaders/lit_post_letterbox.gdshader")
const POSTERIZE_SHADER := preload("res://addons/lit/shaders/lit_post_posterize.gdshader")
const PIXELATE_SHADER := preload("res://addons/lit/shaders/lit_post_pixelate.gdshader")
const HALFTONE_SHADER := preload("res://addons/lit/shaders/lit_post_halftone.gdshader")
const DITHER_SHADER := preload("res://addons/lit/shaders/lit_post_dither.gdshader")
const LENS_SHADER := preload("res://addons/lit/shaders/lit_post_lens_distortion.gdshader")
const LIGHT_LEAKS_SHADER := preload("res://addons/lit/shaders/lit_post_light_leaks.gdshader")
const GLITCH_SHADER := preload("res://addons/lit/shaders/lit_post_glitch.gdshader")
const FOCUS_SHADER := preload("res://addons/lit/shaders/lit_post_focus.gdshader")
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
## Luma above this blooms. LDR screen, so the useful range is ~0.4–0.8 (not 1.0).
@export_range(0.0, 1.0, 0.01) var bloom_threshold: float = 0.7:
	set(value):
		bloom_threshold = value
		_apply_params()
## Glow strength added on top of the frame. Crank past 1 for heavy fantasy bloom.
@export_range(0.0, 4.0, 0.01, "or_greater") var bloom_intensity: float = 0.5:
	set(value):
		bloom_intensity = value
		_apply_params()
## Glow width — spreads the sampled mip levels. Larger = wider, softer halo.
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
## Luma above this halates. LDR screen, so the useful range is ~0.4–0.8.
@export_range(0.0, 1.0, 0.01) var halation_threshold: float = 0.6:
	set(value):
		halation_threshold = value
		_apply_params()
## Halo strength added on top of the frame.
@export_range(0.0, 4.0, 0.01, "or_greater") var halation_intensity: float = 0.6:
	set(value):
		halation_intensity = value
		_apply_params()
## Halo width — spreads the sampled mip levels. Larger = wider, softer bleed.
@export_range(0.0, 8.0, 0.01, "or_greater") var halation_radius: float = 5.0:
	set(value):
		halation_radius = value
		_apply_params()
## Halo color. Warm red-orange by default — the classic film halation hue.
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
## Reshuffle rate — how many discrete glitch frames per second.
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
## Apply a color grade through a lookup table (256×16 neutral-LUT strip).
@export var lut_enabled: bool = false:
	set(value):
		lut_enabled = value
		_rebuild()
## Which baked-in LUT to use. Ignored when a `lut_custom` texture is assigned.
@export var lut_preset: LutPreset = LutPreset.NEUTRAL:
	set(value):
		lut_preset = value
		_apply_params()
## Optional custom LUT (256×16 strip). When set, it overrides `lut_preset`. Import
## with Filter on, Mipmaps off, Repeat disabled, Lossless.
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
## Screen rotation, in degrees (classic single-screen halftone is often ~15–45°).
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
## Collapse to luma first — true 1-bit black & white when levels = 2.
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
## Cinematic bars top and bottom — the matte on the finished content. Animate
## `letterbox_size` from 0 to ease them in/out for cutscenes. Sits at the
## content/display boundary, so the display passes below (VHS/CRT/etc.) render over
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
## Radial barrel / pincushion warp — the device lens. Positive bulges (fisheye),
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
## Worn-tape look: per-line wobble, chroma shift + smear, a rolling tracking-noise
## band, grain, and a slow brightness roll. Animated. Runs before CRT in the chain
## (tape signal -> glass), so enable both for "old tape on an old tube".
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
## Blur reach (mip level). ~1 for sharpen, ~2–4 for a wide dream blur.
@export_range(0.0, 6.0, 0.1, "or_greater") var focus_radius: float = 2.0:
	set(value):
		focus_radius = value
		_apply_params()
## Soft side only: hazy highlight glow blended back in for the dreamy look.
@export_range(0.0, 1.0, 0.01) var focus_dream: float = 0.2:
	set(value):
		focus_dream = value
		_apply_params()

# Generated pass materials, kept so parameter edits push without a rebuild.
var _threshold_material: ShaderMaterial
var _bloom_material: ShaderMaterial
var _halation_material: ShaderMaterial
var _glitch_material: ShaderMaterial
var _grade_material: ShaderMaterial
var _lut_material: ShaderMaterial
var _pixelate_material: ShaderMaterial
var _posterize_material: ShaderMaterial
var _outline_material: ShaderMaterial
var _halftone_material: ShaderMaterial
var _dither_material: ShaderMaterial
var _lens_material: ShaderMaterial
var _vhs_material: ShaderMaterial
var _crt_material: ShaderMaterial
var _aberration_material: ShaderMaterial
var _leaks_material: ShaderMaterial
var _grain_material: ShaderMaterial
var _vignette_material: ShaderMaterial
var _letterbox_material: ShaderMaterial
var _focus_material: ShaderMaterial
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


## Tear down the generated pass chain and rebuild it from the enabled toggles.
func _rebuild() -> void:
	if not is_inside_tree():
		return
	for child in get_children(true):        # include_internal: our passes are internal
		if child.has_meta(PASS_META):
			remove_child(child)
			child.queue_free()
	_threshold_material = null
	_bloom_material = null
	_halation_material = null
	_glitch_material = null
	_grade_material = null
	_lut_material = null
	_pixelate_material = null
	_posterize_material = null
	_outline_material = null
	_halftone_material = null
	_dither_material = null
	_lens_material = null
	_vhs_material = null
	_crt_material = null
	_aberration_material = null
	_leaks_material = null
	_grain_material = null
	_vignette_material = null
	_letterbox_material = null
	_focus_material = null

	# Fixed canonical order (see the class docstring for the rationale):
	# threshold -> bloom -> halation -> glitch -> grade -> lut -> pixelate -> posterize
	# -> outline -> halftone -> dither -> letterbox -> lens -> vhs -> crt -> aberration
	# -> leaks -> grain -> vignette -> focus.
	# Lower-layer passes render first, so each reads the prior result. Letterbox is the
	# content/display boundary: it mattes the finished image, then the display medium
	# (lens/vhs/crt/aberration/grain/vignette) renders over the bars.
	var index := 0
	if threshold_enabled:
		_threshold_material = _make_pass(THRESHOLD_SHADER, index)
		index += 1
	if bloom_enabled:
		_bloom_material = _make_pass(BLOOM_SHADER, index)
		index += 1
	if halation_enabled:
		_halation_material = _make_pass(HALATION_SHADER, index)
		index += 1
	if glitch_enabled:
		_glitch_material = _make_pass(GLITCH_SHADER, index)
		index += 1
	if grade_enabled:
		_grade_material = _make_pass(GRADE_SHADER, index)
		index += 1
	# A LUT is always available (a baked preset, or the custom override), so the
	# pass exists whenever it's enabled.
	if lut_enabled:
		_lut_material = _make_pass(LUT_SHADER, index)
		index += 1
	if pixelate_enabled:
		_pixelate_material = _make_pass(PIXELATE_SHADER, index)
		index += 1
	if posterize_enabled:
		_posterize_material = _make_pass(POSTERIZE_SHADER, index)
		index += 1
	if outline_enabled:
		_outline_material = _make_pass(OUTLINE_SHADER, index)
		index += 1
	if halftone_enabled:
		_halftone_material = _make_pass(HALFTONE_SHADER, index)
		index += 1
	if dither_enabled:
		_dither_material = _make_pass(DITHER_SHADER, index)
		index += 1
	# Letterbox mattes the finished content; the display medium below renders over it.
	if letterbox_enabled:
		_letterbox_material = _make_pass(LETTERBOX_SHADER, index)
		index += 1
	# Display medium: lens warps the framed content, then tape -> tube -> film.
	if lens_enabled:
		_lens_material = _make_pass(LENS_SHADER, index)
		index += 1
	if vhs_enabled:
		_vhs_material = _make_pass(VHS_SHADER, index)
		index += 1
	if crt_enabled:
		_crt_material = _make_pass(CRT_SHADER, index)
		index += 1
	if aberration_enabled:
		_aberration_material = _make_pass(ABERRATION_SHADER, index)
		index += 1
	if leaks_enabled:
		_leaks_material = _make_pass(LIGHT_LEAKS_SHADER, index)
		index += 1
	if grain_enabled:
		_grain_material = _make_pass(GRAIN_SHADER, index)
		index += 1
	if vignette_enabled:
		_vignette_material = _make_pass(VIGNETTE_SHADER, index)
		index += 1
	# Final lens focus: dream blur / sharpen on the completed image.
	if focus_enabled:
		_focus_material = _make_pass(FOCUS_SHADER, index)
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


## Push current parameters onto the generated pass materials (no rebuild needed).
func _apply_params() -> void:
	if _threshold_material != null:
		_threshold_material.set_shader_parameter("cutoff", threshold_cutoff)
	if _bloom_material != null:
		_bloom_material.set_shader_parameter("threshold", bloom_threshold)
		_bloom_material.set_shader_parameter("intensity", bloom_intensity)
		_bloom_material.set_shader_parameter("bloom_radius", bloom_radius)
	if _halation_material != null:
		_halation_material.set_shader_parameter("threshold", halation_threshold)
		_halation_material.set_shader_parameter("intensity", halation_intensity)
		_halation_material.set_shader_parameter("halation_radius", halation_radius)
		_halation_material.set_shader_parameter("tint", halation_tint)
	if _glitch_material != null:
		_glitch_material.set_shader_parameter("intensity", glitch_intensity)
		_glitch_material.set_shader_parameter("block_size", glitch_block_size)
		_glitch_material.set_shader_parameter("rgb_shift", glitch_rgb_shift)
		_glitch_material.set_shader_parameter("speed", glitch_speed)
	if _grade_material != null:
		_grade_material.set_shader_parameter("exposure", exposure)
		_grade_material.set_shader_parameter("contrast", contrast)
		_grade_material.set_shader_parameter("saturation", saturation)
		_grade_material.set_shader_parameter("tint", tint)
	if _lut_material != null:
		_lut_material.set_shader_parameter("lut", _active_lut())
		_lut_material.set_shader_parameter("amount", lut_amount)
	if _pixelate_material != null:
		_pixelate_material.set_shader_parameter("pixel_size", pixelate_size)
	if _posterize_material != null:
		_posterize_material.set_shader_parameter("levels", posterize_levels)
		_posterize_material.set_shader_parameter("strength", posterize_strength)
	if _outline_material != null:
		_outline_material.set_shader_parameter("outline_color", outline_color)
		_outline_material.set_shader_parameter("thickness", outline_thickness)
		_outline_material.set_shader_parameter("threshold", outline_threshold)
		_outline_material.set_shader_parameter("softness", outline_softness)
		_outline_material.set_shader_parameter("strength", outline_strength)
	if _halftone_material != null:
		_halftone_material.set_shader_parameter("dot_size", halftone_dot_size)
		_halftone_material.set_shader_parameter("angle", halftone_angle)
		_halftone_material.set_shader_parameter("amount", halftone_amount)
		_halftone_material.set_shader_parameter("ink_color", halftone_ink_color)
		_halftone_material.set_shader_parameter("paper_color", halftone_paper_color)
	if _dither_material != null:
		_dither_material.set_shader_parameter("levels", dither_levels)
		_dither_material.set_shader_parameter("scale", dither_scale)
		_dither_material.set_shader_parameter("monochrome", dither_monochrome)
		_dither_material.set_shader_parameter("strength", dither_strength)
	if _lens_material != null:
		_lens_material.set_shader_parameter("amount", lens_amount)
		_lens_material.set_shader_parameter("zoom", lens_zoom)
		_lens_material.set_shader_parameter("edge_color", lens_edge_color)
	if _vhs_material != null:
		_vhs_material.set_shader_parameter("wobble_strength", vhs_wobble_strength)
		_vhs_material.set_shader_parameter("wobble_speed", vhs_wobble_speed)
		_vhs_material.set_shader_parameter("chroma_shift", vhs_chroma_shift)
		_vhs_material.set_shader_parameter("bleed", vhs_bleed)
		_vhs_material.set_shader_parameter("grain", vhs_grain)
		_vhs_material.set_shader_parameter("tracking_strength", vhs_tracking_strength)
		_vhs_material.set_shader_parameter("tracking_speed", vhs_tracking_speed)
		_vhs_material.set_shader_parameter("roll_strength", vhs_roll_strength)
	if _crt_material != null:
		_crt_material.set_shader_parameter("curvature", crt_curvature)
		_crt_material.set_shader_parameter("scanline_strength", crt_scanline_strength)
		_crt_material.set_shader_parameter("scanline_count", crt_scanline_count)
		_crt_material.set_shader_parameter("mask_strength", crt_mask_strength)
		_crt_material.set_shader_parameter("aberration", crt_aberration)
		_crt_material.set_shader_parameter("vignette", crt_vignette)
		_crt_material.set_shader_parameter("brightness", crt_brightness)
	if _aberration_material != null:
		_aberration_material.set_shader_parameter("amount", aberration_amount)
		_aberration_material.set_shader_parameter("edge_falloff", aberration_edge_falloff)
	if _leaks_material != null:
		_leaks_material.set_shader_parameter("intensity", leaks_intensity)
		_leaks_material.set_shader_parameter("speed", leaks_speed)
		_leaks_material.set_shader_parameter("color1", leaks_color1)
		_leaks_material.set_shader_parameter("color2", leaks_color2)
		_leaks_material.set_shader_parameter("has_texture", leaks_texture != null)
		_leaks_material.set_shader_parameter("leak_texture", leaks_texture)
	if _grain_material != null:
		_grain_material.set_shader_parameter("intensity", grain_intensity)
		_grain_material.set_shader_parameter("grain_size", grain_size)
		_grain_material.set_shader_parameter("luminance_response", grain_luminance_response)
		_grain_material.set_shader_parameter("colored", grain_colored)
	if _vignette_material != null:
		_vignette_material.set_shader_parameter("strength", vignette_strength)
		_vignette_material.set_shader_parameter("softness", vignette_softness)
	if _letterbox_material != null:
		_letterbox_material.set_shader_parameter("bar_size", letterbox_size)
		_letterbox_material.set_shader_parameter("softness", letterbox_softness)
		_letterbox_material.set_shader_parameter("bar_color", letterbox_color)
	if _focus_material != null:
		_focus_material.set_shader_parameter("amount", focus_amount)
		_focus_material.set_shader_parameter("radius", focus_radius)
		_focus_material.set_shader_parameter("dream", focus_dream)
