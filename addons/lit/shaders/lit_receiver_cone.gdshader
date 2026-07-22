shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver (self-shadow exclusion) + the Cone Traced shadow algorithm.

// [receiver-uniforms] Edit in lit_receiver.gdshader, then run addons/lit/tools/sync_receiver_uniforms.gd (File > Run).

/**
 * Self-illumination: adds albedo * strength * emissive_mask on top of lighting, so it
 * stays visible in full shadow and darkness. 0 is off (the mask is not even sampled);
 * values above 1 overbright toward bloom.
 */
uniform float emissive_strength = 0.0;

/**
 * Grayscale mask shaping where emissive_strength applies: white glows fully, black
 * not at all. Defaults to white so the strength works alone on the whole sprite.
 */
uniform sampler2D emissive_mask : hint_default_white;

/**
 * Light layer mask: a light affects this receiver only if the light's mask and this
 * share a bit. A plain int because shader uniforms have no layers hint; LitSprite2D
 * proxies it with a friendlier 2D-render-layers control.
 */
uniform int receiver_mask = 1;

/**
 * When off, shadow-march hits inside this receiver's own occluder bounds (self_rects)
 * are ignored, so its occluders cast shadows behind it instead of onto it. When on,
 * the receiver darkens itself like anything else. Only the non-fast shader variants
 * apply the exclusion; LitSprite2D swaps variants automatically.
 */
uniform bool self_shadow = false;

/**
 * Number of valid entries in self_rects; 0 disables the self-shadow exclusion test.
 * Synced automatically by LitSprite2D from its owned occluders.
 */
uniform int  self_rect_count = 0;

/**
 * Local-space bounds of this receiver's own occluders, min.xy | max.xy per entry, for
 * the self-shadow exclusion test. LitSprite2D syncs one box per owned occluder,
 * unioning extras into the last slot.
 */
uniform vec4 self_rects [4];

/**
 * Blinn-Phong specular intensity (Blinn-Phong lighting model only; PBR ignores it).
 * 0 disables the highlight entirely and skips its cost.
 */
uniform float specular_strength = 0.5;

/**
 * Blinn-Phong specular exponent scale: the CanvasTexture shininess maps to the lobe
 * exponent as 1 + shininess * specular_k, so higher is a tighter, sharper highlight.
 * Ignored in PBR mode.
 */
uniform float specular_k = 32.0;

/**
 * Whether a specular map is actually present on this receiver's CanvasTexture.
 * LitSprite2D auto-detects it; other receivers set it by hand - Godot reports "no
 * map" and "white map" identically, so the shader can't tell on its own. When true
 * the Blinn-Phong path uses the true half-vector specular (crisp, view-aware, shaped
 * by the map); when false it falls back to a sharpened N.L lobe that stays
 * well-behaved on flat, un-normal-mapped surfaces. PBR mode ignores this.
 */
uniform bool has_specular_map = false;

/**
 * PBR metalness map (PBR lighting model only), multiplied by metallic_value.
 * Defaults to white so the scalar works alone. Import as linear (uncheck sRGB).
 */
uniform sampler2D metallic_map : hint_default_white;

/**
 * PBR metalness (PBR lighting model only), multiplied into metallic_map. 0 is
 * dielectric; 1 takes reflectance from albedo and removes diffuse. Phong mode reads
 * none of the PBR inputs, so a PBR-authored material still renders after switching
 * back.
 */
uniform float metallic_value : hint_range(0.0, 1.0) = 0.0;

/**
 * PBR roughness map (PBR lighting model only), multiplied by roughness_value.
 * Defaults to white so the scalar works alone. Import as linear (uncheck sRGB).
 */
uniform sampler2D roughness_map : hint_default_white;

/**
 * PBR roughness (PBR lighting model only), multiplied into roughness_map. 1 is fully
 * matte - the safe default that reads like the plain diffuse look - and lower values
 * tighten the specular toward a mirror.
 */
uniform float roughness_value : hint_range(0.0, 1.0) = 1.0;

/**
 * PBR ambient-occlusion map (PBR lighting model only): darkens the ambient term
 * where the map is dark, leaving direct light untouched. Defaults to white (no
 * occlusion). Import as linear (uncheck sRGB).
 */
uniform sampler2D ao_map : hint_default_white;

/**
 * Step budget for each per-light shadow march. More steps resolve longer, softer
 * penumbras; fewer is faster. When the lit/quality shadow-step-scaling project
 * setting is on, an adaptive budget derived from march length replaces this value.
 */
uniform int   shadow_steps = 64;

/**
 * Smallest advance per shadow-march step, in SDF units. Keeps the march from
 * stalling when it grazes an outline; larger values are faster but can step over
 * thin occluders.
 */
uniform float shadow_min_step = 0.2;

/**
 * How strongly an occluder's own shadow lands on its footprint (the pixels inside
 * its outline): blocking = footprint_shadow * depth crossed / light distance,
 * clamped to 1. Higher darkens footprints sooner. Dimensionless, so camera zoom
 * does not change the look.
 */
uniform float footprint_shadow = 16.0;

/**
 * Horizontal reach of a directional light's shading vector relative to its height;
 * elevation is atan(height / scale). The default reads about 27 degrees at height
 * 16, so the light's direction stays legible. Larger is more grazing.
 */
uniform float directional_horizontal_scale = 32.0;

/**
 * How far a directional shadow marches across the SDF before counting as open sky,
 * in screen diagonals. Scaling with the screen keeps the fixed step budget
 * well-sampled; a huge fixed distance would under-sample the penumbra.
 */
uniform float directional_shadow_reach = 1.0;
// [/receiver-uniforms]

#define LIT_SELF_EXCLUSION
#define LIT_SHADOW_CONE
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
