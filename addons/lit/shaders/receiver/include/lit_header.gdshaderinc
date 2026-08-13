// Unit: uniforms, varyings, feature-derived defines, vertex(); every axis reads these.

// Shared body of the Lit receiver shader, compiled into thin wrapper variants along
// two axes (never-executed code still taxes a shader, so each feature exists only in
// the variants that need it; LitSprite2D swaps variants automatically and the uniforms
// exist in all of them so parameters survive the swap):
//  - LIT_SELF_EXCLUSION: self-shadow exclusion (lit_receiver.gdshader and the other
//    non-_fast wrappers); the _fast wrappers compile it out - identical output for
//    materials that never populate self_rects.
//  - LIT_YSORT: the y-sort shadow depth test (the _ysort wrappers).
//  - LIT_OCC_GX: globally excluded occluders as exempt rects riding the self-exclusion
//    machinery (the _gx wrappers; also implied by LIT_OCC_MASKS and LIT_OCC_RX).
//  - LIT_OCC_MASKS: per-light shadow-mask/owner exclusion (the _mask wrappers).
//  - LIT_OCC_RX: per-receiver exclusion (shadow_ignore_mask): shadows from occluders
//    matching rx_mask are ignored, tested per sample against the occluder identity
//    tiles (the _rx / _mask_rx wrappers).
//  - LIT_SHADOW_CONE / LIT_SHADOW_STOCH: the Cone Traced and Stochastic per-light
//    shadow algorithms (the _cone / _stoch / _cone_stoch wrappers). Base wrappers
//    support only the Raymarched algorithm and compile byte-identical to the
//    pre-algorithm-selection shader.

// Transport: global uniforms plus the per-frame light-data texture, packed by the
// manager. Read via texelFetch (integer coords, no filtering), so the texture's
// filter mode doesn't matter here.
global uniform sampler2D lit_light_data;
global uniform int       lit_light_count;
global uniform int       lit_directional_count;         // directionals occupy rows [0, this)
global uniform vec2      lit_viewport_size;             // pixels
global uniform float     lit_canvas_scale;              // world-to-screen px scale (camera/editor zoom)

// World-space shadow SDF, rendered by the registry's SubViewport over the region that
// can shadow the view. Texel .r is signed distance in world px; the basis/origin pair
// maps screen px to its UV. Marches sample this instead of the screen-tied engine SDF,
// so shadow casting is zoom- and pan-invariant.
global uniform sampler2D lit_world_sdf;
global uniform vec4      lit_wsdf_basis;                // screen-px -> UV, columns (xx, xy, yx, yy)
global uniform vec2      lit_wsdf_origin;
global uniform vec4      lit_ambient_color : source_color;
global uniform float     lit_ambient_energy;

// Lighting model selector, published by the manager (and the editor plugin) from the
// lit/render/lighting_model project setting. 0 = Blinn-Phong (ambient + Lambert +
// half-vector specular), 1 = PBR (metallic-roughness Cook-Torrance). The branch is on a
// global uniform, so every receiver honors the toggle live and all fragments take the
// same path (coherent, cheap). When Blinn-Phong is selected the PBR-only material inputs
// are never sampled, so it costs nothing.
global uniform int       lit_lighting_model;

// Atlas of the lights' cookie textures. A textured light (flags bit 2) carries its
// atlas UV rect in texel 5 and its screen-px-to-cookie-UV matrix in texel 6; a
// texture_offset (flags bit 18) shifts the cookie-UV center via texel 8. Linear
// filtered, no mipmaps, sampled with textureLod so the read is legal in divergent
// control flow.
global uniform sampler2D lit_cookie_atlas;

// Tiled light culling: the manager bins each positional light into a screen-tile grid
// and uploads a per-tile header (offset + count into the index list) plus a flat index
// list of light rows. A fragment then shades only the lights in its own tile instead of
// looping every light. texelFetch with nearest filtering, same as the data texture.
global uniform sampler2D lit_tile_headers;
global uniform sampler2D lit_tile_indices;
global uniform ivec2     lit_tile_grid;                 // tiles across, tiles down
global uniform int       lit_tile_size;                 // tile edge in pixels

// Y-sort shadow depth: per-occluder rect + depth line, binned into the light tiles.
#ifdef LIT_YSORT
global uniform bool      lit_ysort_enabled;
global uniform float     lit_ysort_band;                // fade half-width, world px
#endif
// Occluder identity tiles (y-sort depth + per-receiver exclusion): per-occluder canvas
// rect and light mask, binned into the light tile grid.
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
global uniform sampler2D lit_occ_data;                  // t0 rect min.xy|max.xy (max.y depth line); t1.x mask
global uniform sampler2D lit_occ_headers;               // per tile: offset | count | min depth
global uniform sampler2D lit_occ_indices;
#endif

// Globally excluded occluders (no shadow-casting light's mask matches theirs): exempt
// canvas rects treated exactly like self rects, for every light at once.
#if defined(LIT_OCC_MASKS) && !defined(LIT_OCC_GX)
#define LIT_OCC_GX
#endif
#if defined(LIT_OCC_RX) && !defined(LIT_OCC_GX)
#define LIT_OCC_GX
#endif
#ifdef LIT_OCC_GX
global uniform int  lit_gx_count;
global uniform vec4 lit_gx_rect0;                       // canvas min.xy | max.xy each
global uniform vec4 lit_gx_rect1;
global uniform vec4 lit_gx_rect2;
global uniform vec4 lit_gx_rect3;                       // extras unioned into this slot
#endif

// Per-receiver shadow exclusion (shadow_ignore_mask, the _rx wrappers): this receiver
// ignores shadows from occluders whose light mask shares a bit with rx_mask. Tested
// per sample against the occluder identity tiles, so any number of casters (tilemap
// cells included) is exempted at per-occluder precision.
#ifdef LIT_OCC_RX
uniform int  rx_mask = 0;
// Clustered bounds of this receiver's ignored casters (canvas min.xy | max.xy per
// slot), synced by the registry: a march runs its slow phase only while crossing a
// cluster it actually intersects, so scattered ignored sets keep the fast phases
// instead of degenerating into one screen-sized union.
uniform vec4 rx_bounds[4];
uniform int  rx_bound_count = 0;
#endif

// Optional adaptive shadow march, driven by the lit/quality/* project settings via the
// manager. When scaling is on, a fragment spends march steps in proportion to how far
// it has to march, capped at lit_shadow_steps_max.
global uniform int  lit_shadow_steps_max;
global uniform bool lit_shadow_step_scaling;

// The index list is stored as a 2D texture this wide, so a flat index maps to
// (idx % WIDTH, idx / WIDTH). Must match INDEX_TEX_WIDTH in the registry.
const int LIT_INDEX_TEX_WIDTH = 2048;

// Compile-time ceiling on the shadow loop so it can be unrolled; lit_shadow_steps_max
// is clamped to this on the CPU.
const int LIT_MAX_SHADOW_STEPS = 256;

// Values of lit_lighting_model; must match LightingModel in lit_manager.gd / lit_plugin.gd.
const int   LIT_MODEL_PHONG = 0;
const int   LIT_MODEL_PBR   = 1;
const float LIT_PI = 3.14159265359;

uniform float emissive_strength = 0.0;
uniform sampler2D emissive_mask : hint_default_white;   // white default lets strength work alone

// A light affects this receiver only if (light_mask & receiver_mask) != 0. Plain int,
// since shader uniforms have no layers hint; LitSprite2D proxies it with a nicer
// 2D-render-layers control.
uniform int receiver_mask = 1;

// Self-shadow exclusion: when self_shadow is off, shadow-march hits inside the
// receiver's own occluder bounds are ignored, so its own occluders cast behind it, not
// onto it. LitSprite2D syncs one canvas-space box per owned occluder, unioning extras
// into the last slot; count 0 disables the test.
uniform bool self_shadow = false;
uniform int  self_rect_count = 0;
uniform vec4 self_rects[4];  // canvas-space min.xy | max.xy each

// Y-sort participation + depth line (the receiver's occluder footprint bottom).
#ifdef LIT_YSORT
uniform bool  ysort_on = false;
uniform float ysort_y = 0.0;
#endif

// Blinn-Phong specular controls (LIT_MODEL_PHONG only). Ignored in PBR mode.
// specular_k scales how the CanvasTexture shininess maps to the half-vector exponent.
uniform float specular_strength = 0.5;
uniform float specular_k = 32.0;

// Per-instance: is a specular map actually present on this receiver? LitSprite2D
// auto-detects it from the CanvasTexture's specular slot; other receiver types can set it
// by hand. Godot reports the same SPECULAR_SHININESS for "no map" and "white map", so the
// shader can't tell on its own. When true the Blinn-Phong path uses the true half-vector
// specular (crisp, view-aware, shaped by the map). When false it falls back to the
// original sharpened-N.L lobe, which stays well-behaved on flat, un-normal-mapped surfaces
// where the half-vector would otherwise blow the highlight out. PBR mode ignores this.
uniform bool has_specular_map = false;

// --- PBR (metallic-roughness) material inputs ---------------------------------------
// Sampled only when lit_lighting_model == LIT_MODEL_PBR. Each map multiplies its scalar,
// and the maps default to white so an unassigned map falls back to the scalar alone:
// leave the scalar and drop in a map, or skip the map and dial the scalar. Metallic 0 is
// dielectric; roughness 1 is fully matte, the safe default that reads like the plain
// diffuse look until dialed down. AO modulates the ambient term only. In Phong mode none
// of these are read, so a PBR-authored material still renders correctly after switching
// back to Phong (the extra data is simply ignored). Import metallic/roughness/AO maps as
// linear (uncheck sRGB) for correct values.
uniform sampler2D metallic_map : hint_default_white;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D roughness_map : hint_default_white;
uniform float roughness_value : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D ao_map : hint_default_white;

uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

// How strongly an occluder's own shadow lands on its footprint:
// block = footprint_shadow * depth crossed / light distance, clamped to 1. Higher
// values darken footprints sooner. Dimensionless, so zoom does not change the look.
uniform float footprint_shadow = 16.0;

// Horizontal reach of a directional light's shading vector relative to its `height`;
// elevation is atan(height / scale). The default gives about 27 degrees at height 16,
// so the direction reads clearly. Larger is more grazing.
uniform float directional_horizontal_scale = 32.0;

// Screen-pixel march basis, needed by the tile lookups of y-sort and per-receiver
// exclusion; the macros erase it from variants with neither.
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
#define LIT_PX_PARAMS , mat2 sdf_to_px, vec2 frag_px
#define LIT_PX_ARGS , sdf_to_px, frag_px
#else
#define LIT_PX_PARAMS
#define LIT_PX_ARGS
#endif

// Y-sort march context; the macros erase it from non-_ysort variants entirely.
#ifdef LIT_YSORT
#define LIT_YS_PARAMS , bool ys_on
#define LIT_YS_ARGS , ys_on
#define LIT_YS_ON ys_on
#else
#define LIT_YS_PARAMS
#define LIT_YS_ARGS
#define LIT_YS_ON false
#endif

// Per-receiver exclusion context: rx_mask is a uniform, so beyond the on-flag and the
// per-sample tile test only the light's shadow mask (rx_smask, from its data row)
// threads through the march. LIT_RX_EXEMPT's arguments are macro tokens, so in non-rx
// variants they are never evaluated (frag_px need not exist).
#ifdef LIT_OCC_RX
#define LIT_RX_PARAMS , int rx_smask
#define LIT_RX_ARGS , rx_smask
#define LIT_RX_ON (rx_mask != 0)
#define LIT_RX_EXEMPT(p_canvas, p_px, reach) lit_rx_exempt(p_canvas, p_px, reach, rx_smask)
#else
#define LIT_RX_PARAMS
#define LIT_RX_ARGS
#define LIT_RX_ON false
#define LIT_RX_EXEMPT(p_canvas, p_px, reach) false
#endif

// Per-light shadow exclusion context (the _mask variants): the light's exempt-occluder
// rects live in its own data row (texels 9-14), so the march carries only a row index
// and the coarse union rect.
#ifdef LIT_OCC_MASKS
#define LIT_MK_PARAMS , bool mk_on, int mk_row, vec4 mk_rect
#define LIT_MK_ARGS , mk_on, mk_row, mk_rect
#define LIT_MK_ON mk_on
#else
#define LIT_MK_PARAMS
#define LIT_MK_ARGS
#define LIT_MK_ON false
#endif

// Fragment position in canvas space, for the self-shadow bounds test. Canvas space
// rather than VERTEX so the rects stay valid for items that don't draw in their
// owner's local space (a y-sorted TileMapLayer renders per-row child items).
varying vec2 v_canvas;

void vertex() {
	v_canvas = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

