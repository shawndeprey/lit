shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Transport: global uniforms plus the per-frame light-data texture, packed by the
// manager. Read via texelFetch (integer coords, no filtering), so the texture's
// filter mode doesn't matter here.
global uniform sampler2D lit_light_data;
global uniform int       lit_light_count;
global uniform int       lit_directional_count;         // directionals occupy rows [0, this)
global uniform vec2      lit_viewport_size;             // pixels
global uniform float     lit_canvas_scale;              // world-to-screen px scale (camera/editor zoom)
global uniform vec4      lit_ambient_color : source_color;
global uniform float     lit_ambient_energy;

// Lighting model selector, published by the manager (and the editor plugin) from the
// lit/render/lighting_model project setting. 0 = Blinn-Phong (ambient + Lambert +
// half-vector specular), 1 = PBR (metallic-roughness Cook-Torrance). The branch is on a
// global uniform, so every receiver honors the toggle live and all fragments take the
// same path (coherent, cheap). When Blinn-Phong is selected the PBR-only material inputs
// are never sampled, so it costs nothing.
global uniform int       lit_lighting_model;

// Tiled light culling: the manager bins each positional light into a screen-tile grid
// and uploads a per-tile header (offset + count into the index list) plus a flat index
// list of light rows. A fragment then shades only the lights in its own tile instead of
// looping every light. texelFetch with nearest filtering, same as the data texture.
global uniform sampler2D lit_tile_headers;
global uniform sampler2D lit_tile_indices;
global uniform ivec2     lit_tile_grid;                 // tiles across, tiles down
global uniform int       lit_tile_size;                 // tile edge in pixels

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

// Self-shadow exclusion: when self_shadow is off, shadow-march hits inside self_rect
// (this item's local rect) are ignored, so a sprite's own occluder casts behind it, not
// onto it. LitSprite2D syncs self_rect; the empty default disables the test entirely.
uniform bool self_shadow = false;
uniform vec4 self_rect = vec4(0.0);  // local-space min.xy | max.xy; empty = off

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

// Horizontal reach of a directional light's shading vector relative to its `height`;
// elevation is atan(height / scale). The default gives about 27 degrees at height 16,
// so the direction reads clearly. Larger is more grazing.
uniform float directional_horizontal_scale = 32.0;

// How far a directional shadow marches across the SDF before it counts as open sky,
// in screen diagonals. Scaling to screen size keeps the fixed step budget
// well-sampled; a fixed huge distance would under-sample the penumbra.
uniform float directional_shadow_reach = 1.0;

// Fragment position in the item's local space, for the self-shadow rect test.
varying vec2 v_local;

void vertex() {
	v_local = VERTEX;
}

// True when a local-space march sample falls inside this item's own rect.
bool lit_in_self(vec2 p_local) {
	return p_local.x >= self_rect.x && p_local.y >= self_rect.y
			&& p_local.x <= self_rect.z && p_local.y <= self_rect.w;
}

// Soft-shadow march of Godot's screen-space SDF (the IQ technique). Works in SDF
// space, marching from the fragment toward the light and tracking the running minimum
// of k * d / t for the penumbra. Returns 1 fully lit, 0 occluded. max_steps lets the
// caller spend fewer iterations on short marches; the loop bound stays constant so it
// can unroll. When self_ex is true, hits inside the receiver's own rect (mapped via
// self_local + sdf_to_local) are stepped through instead of occluding.
float lit_shadow(vec2 frag_sdf, vec2 light_sdf, float hardness, int max_steps,
		bool self_ex, vec2 self_local, mat2 sdf_to_local) {
	// Screen-space SDF has no notion of 2D draw order. A fragment sitting inside
	// an occluder's footprint is treated as on top of it, so a sprite drawn over
	// an occluder stays lit instead of self-shadowing. (Distinct occluders that
	// lie between this fragment and the light still cast normally.)
	if (texture_sdf(frag_sdf) <= 0.0) {
		return 1.0;
	}
	vec2 delta = light_sdf - frag_sdf;
	float maxd = length(delta);
	if (maxd < 0.0001) {
		return 1.0;                          // light is on the fragment
	}
	vec2 dir = delta / maxd;
	float t = shadow_min_step;
	float res = 1.0;
	float k = mix(8.0, 256.0, hardness);     // low hardness is soft, high is crisp
	for (int s = 0; s < LIT_MAX_SHADOW_STEPS; s++) {
		if (s >= max_steps || t >= maxd) {
			break;
		}
		vec2 offset = dir * t;
		float d = texture_sdf(frag_sdf + offset);
		float cand = k * d / t;
		// Test self-exclusion only when the sample matters (hit or lower penumbra).
		if (d < 0.001 || cand < res) {
			if (self_ex && lit_in_self(self_local + sdf_to_local * offset)) {
				if (d < 0.001) {
					// Cross the excluded occluder: -d is the distance to its far edge.
					t += max(-d, shadow_min_step);
					continue;
				}
			} else {
				if (d < 0.001) {
					return 0.0;              // fully occluded
				}
				res = cand;                  // penumbra accumulation
			}
		}
		t += max(d, shadow_min_step);
	}
	return clamp(res, 0.0, 1.0);
}

// --- PBR helpers (Cook-Torrance microfacet BRDF) ------------------------------------
// Trowbridge-Reitz / GGX normal distribution.
float lit_d_ggx(float n_dot_h, float roughness) {
	float a = roughness * roughness;
	float a2 = a * a;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	return a2 / max(LIT_PI * d * d, 1e-6);
}

// Smith geometry term (Schlick-GGX) using the direct-lighting k remap.
float lit_g_smith(float n_dot_v, float n_dot_l, float roughness) {
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;
	float gv = n_dot_v / (n_dot_v * (1.0 - k) + k);
	float gl = n_dot_l / (n_dot_l * (1.0 - k) + k);
	return gv * gl;
}

// Schlick Fresnel approximation.
vec3 lit_f_schlick(float v_dot_h, vec3 f0) {
	return f0 + (1.0 - f0) * pow(clamp(1.0 - v_dot_h, 0.0, 1.0), 5.0);
}

// Shade this fragment by light row `i` and return its contribution (negative for a
// subtractive light). Called once per light affecting the fragment, from the directional
// sweep and the per-tile loop in fragment(). metallic/roughness are sampled once per
// fragment by the caller and used only in PBR mode.
vec3 lit_shade(int i, vec3 albedo, vec3 N, vec3 spec_shin, float shininess,
		float metallic, float roughness,
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag,
		bool self_ex, vec2 self_local, mat2 sdf_to_local) {
	// Texel 0 carries the cheap fields (type | flags | mask | falloff) so masked-out
	// lights bail after a single fetch, before any position/color/shadow texels.
	vec4 t0 = texelFetch(lit_light_data, ivec2(0, i), 0);

	// type: 0 = point, 1 = directional, 2 = spot. flags bit 0 = shadow_enabled,
	// bit 1 = subtractive.
	int type = int(round(t0.x));
	bool is_directional = type == 1;
	bool is_spot = type == 2;
	int flags = int(round(t0.y));
	bool shadow_enabled = (flags & 1) != 0;
	bool subtractive = (flags & 2) != 0;
	float falloff = t0.w;

	// Skip lights this receiver's mask doesn't share a bit with, before paying for
	// any of the work below.
	int light_mask = int(round(t0.z));
	if ((light_mask & receiver_mask) == 0) {
		return vec3(0.0);
	}

	vec4 t1 = texelFetch(lit_light_data, ivec2(1, i), 0); // uv.xy / dir.xy | range | energy
	vec4 t2 = texelFetch(lit_light_data, ivec2(2, i), 0); // color.rgb | height

	vec2 light_uv = t1.xy;
	float range = t1.z;
	float energy = t1.w;
	vec3 light_color = t2.rgb;
	float height = t2.w;

	vec3 Ldir;
	float atten;
	vec2 shadow_dir_uv = vec2(0.0);          // toward-light dir in screen-UV space (directional only)

	if (is_directional) {
		// t1.xy is a unit screen-space direction toward the light. No position, no
		// attenuation; `height` sets the elevation.
		vec2 dir_px = t1.xy;
		Ldir = normalize(vec3(dir_px * directional_horizontal_scale, height));
		atten = 1.0;
		shadow_dir_uv = dir_px / lit_viewport_size; // pixel dir to UV dir
	} else {
		// Point or spot: work in screen pixels. `range` and `height` are authored in
		// world units, so scale them by the world-to-screen factor (camera/editor zoom)
		// into the same space as to_light_px below. The factor cancels in both dist/range
		// and the Ldir normalize, so point/spot shading is identical at any zoom.
		float range_px = range * lit_canvas_scale;
		float height_px = height * lit_canvas_scale;
		vec2 to_light_px = (light_uv - frag_uv) * lit_viewport_size;
		float dist = length(to_light_px);
		if (dist > range_px) {
			return vec3(0.0);                // beyond range
		}
		Ldir = normalize(vec3(to_light_px, height_px));
		atten = pow(clamp(1.0 - dist / range_px, 0.0, 1.0), falloff);

		// A spot is a point light masked to a cone (texel 4): aim.xy is the
		// screen-space direction it points. The fragment is lit if it falls inside
		// the cone, with a soft edge between the inner and outer angle.
		if (is_spot) {
			vec4 t4 = texelFetch(lit_light_data, ivec2(4, i), 0); // aim.xy | cos_outer | cos_inner
			vec2 dir_to_frag = (dist > 0.0001) ? (-to_light_px / dist) : t4.xy;
			float cone = smoothstep(t4.z, t4.w, dot(t4.xy, dir_to_frag));
			atten *= cone;
		}
	}

	// Fully attenuated (out of range, or outside a spot's cone): nothing to add
	// and no shadow to march.
	if (atten <= 0.0) {
		return vec3(0.0);
	}

	float ndotl = max(dot(N, Ldir), 0.0);

	vec3 contribution;
	if (lit_lighting_model == LIT_MODEL_PBR) {
		// Orthographic 2D view: the eye looks straight down +Z at the canvas, so the view
		// vector is a constant. This is the 2.5D PBR simplification; there's no per-pixel
		// view ray, so the half-vector and Fresnel are evaluated against a fixed V.
		vec3 V = vec3(0.0, 0.0, 1.0);
		vec3 H = normalize(Ldir + V);
		float n_dot_v = max(dot(N, V), 1e-4);
		float n_dot_h = max(dot(N, H), 0.0);
		float v_dot_h = max(dot(V, H), 0.0);

		// Dielectric reflectance is a flat 0.04; metals take their reflectance from albedo.
		vec3 f0 = mix(vec3(0.04), albedo, metallic);
		float D = lit_d_ggx(n_dot_h, roughness);
		float G = lit_g_smith(n_dot_v, ndotl, roughness);
		vec3 F = lit_f_schlick(v_dot_h, f0);

		vec3 spec = (D * G * F) / max(4.0 * n_dot_v * ndotl, 1e-4);

		// Energy left for diffuse after reflection; metals have no diffuse.
		vec3 kd = (vec3(1.0) - F) * (1.0 - metallic);

		// Lambert term. The canonical 1/PI is folded into the artist-authored light
		// energy so PBR sits at a brightness comparable to Phong for the same light,
		// keeping the toggle a look change rather than an exposure change.
		vec3 diffuse = kd * albedo;

		contribution = (diffuse + spec) * light_color * energy * ndotl * atten;
	} else {
		vec3 diffuse = albedo * light_color * energy * ndotl * atten;

		// Highlight tinted by light_color so it takes the light's hue instead of blowing
		// out to white. Gated by ndotl so it never appears on the side facing away from
		// the light, and skipped entirely when there's no specular strength or color.
		vec3 specular = vec3(0.0);
		if (specular_strength > 0.0 && ndotl > 0.0 && dot(spec_shin, spec_shin) > 0.0) {
			float exponent = 1.0 + shininess * specular_k;
			float lobe;
			if (has_specular_map) {
				// True (2.5D) Blinn-Phong: the half-vector between light and view. Same
				// fixed orthographic view as the PBR path (the eye looks down +Z, so V
				// points toward the viewer), so the highlight sits where the surface
				// reflects the light toward the eye. A specular map shapes/masks it, which
				// keeps it from blowing out on flat areas.
				vec3 V = vec3(0.0, 0.0, 1.0);
				vec3 H = normalize(Ldir + V);
				lobe = pow(max(dot(N, H), 0.0), exponent);
			} else {
				// No specular map to shape the half-vector lobe, which would otherwise read
				// as a flat blown-out wash on un-normal-mapped surfaces (H biases toward N).
				// Fall back to the sharpened N.L lobe, which behaves with or without a
				// normal map.
				lobe = pow(ndotl, exponent);
			}
			specular = light_color * spec_shin * energy * atten * lobe * specular_strength;
		}

		contribution = diffuse + specular;
	}

	// Negligible contribution: bail before the expensive SDF shadow march. Below this
	// the result is indistinguishable from black anyway.
	if (max(contribution.r, max(contribution.g, contribution.b)) < 0.004) {
		return vec3(0.0);
	}

	// Marched only for shadow-casting lights, so a light with shadows off pays nothing
	// here, not even the texel-3 fetch. In shadow the contribution is tinted by
	// shadow_color (black blocks the light entirely). Factor 1 is lit, 0 is occluded.
	if (shadow_enabled) {
		vec4 t3 = texelFetch(lit_light_data, ivec2(3, i), 0); // shadow_color.rgb | shadow_hardness
		vec2 light_sdf;
		if (is_directional) {
			// March a fixed direction across the SDF. screen_uv_to_sdf is affine, so
			// the SDF-space direction comes from offsetting the fragment UV along the
			// toward-light dir; the distance scales with the screen.
			vec2 dir_sdf = normalize(screen_uv_to_sdf(frag_uv + shadow_dir_uv) - frag_sdf);
			light_sdf = frag_sdf + dir_sdf * sdf_diag * directional_shadow_reach;
		} else {
			// Point and spot both march toward the light's screen position.
			light_sdf = screen_uv_to_sdf(light_uv);
		}

		// Adaptive step budget: shorter marches need fewer steps to stay well-sampled.
		// Scale by the march length as a fraction of the screen diagonal; keep a floor
		// so very short marches still resolve a penumbra. Off by default (fixed budget).
		int steps = shadow_steps;
		if (lit_shadow_step_scaling) {
			float march_len = length(light_sdf - frag_sdf);
			float frac = clamp(march_len / max(sdf_diag, 0.0001), 0.0, 1.0);
			steps = int(ceil(frac * float(lit_shadow_steps_max)));
			steps = clamp(steps, 16, lit_shadow_steps_max);
		}

		float s = lit_shadow(frag_sdf, light_sdf, t3.w, steps, self_ex, self_local, sdf_to_local);
		contribution *= mix(t3.rgb, vec3(1.0), s);
	}

	// Subtract mode is negative light: it carves darkness below ambient, and the
	// final COLOR clamps at display.
	return subtractive ? -contribution : contribution;
}

void fragment() {
	vec3 albedo = COLOR.rgb;
	vec3 N = normalize(NORMAL);                  // from the CanvasTexture normal map; faces out when absent
	vec3 spec_shin = SPECULAR_SHININESS.rgb;
	float shininess = SPECULAR_SHININESS.a;

	// PBR material inputs, sampled once per fragment and only in PBR mode. In Phong mode
	// they stay at their neutral defaults (never read by lit_shade, and ao = 1 leaves the
	// ambient term unchanged), so Phong pays for none of these fetches.
	float metallic = 0.0;
	float roughness = 1.0;
	float ao = 1.0;
	if (lit_lighting_model == LIT_MODEL_PBR) {
		metallic = clamp(metallic_value * texture(metallic_map, UV).r, 0.0, 1.0);
		roughness = clamp(roughness_value * texture(roughness_map, UV).r, 0.04, 1.0);
		ao = texture(ao_map, UV).r;
	}

	// Ambient base: albedo lit by the (dark) ambient term, attenuated by AO in PBR
	// (ao = 1 in Phong, so this is a no-op there).
	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy * ao;

	vec2 frag_uv = SCREEN_UV;                     // canonical screen-UV space
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  // shadow-march space

	// Screen diagonal in SDF units: the natural scale for a directional shadow's march
	// distance, keeping the step budget well-sampled at any resolution.
	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	// Self-shadow basis: map SDF-space march offsets to local space. Both spaces are
	// affine images of the screen, so probing one pixel step in each and composing is
	// exact. The uniform condition keeps the derivative calls in uniform control flow.
	bool self_ex = !self_shadow && self_rect.z > self_rect.x && self_rect.w > self_rect.y;
	mat2 sdf_to_local = mat2(vec2(0.0), vec2(0.0));
	if (self_ex) {
		// Columns: per-pixel-step delta of each space, in x and y.
		mat2 px_to_sdf = mat2(
				screen_uv_to_sdf(SCREEN_UV + vec2(SCREEN_PIXEL_SIZE.x, 0.0)) - frag_sdf,
				screen_uv_to_sdf(SCREEN_UV + vec2(0.0, SCREEN_PIXEL_SIZE.y)) - frag_sdf);
		mat2 px_to_local = mat2(dFdx(v_local), dFdy(v_local));
		sdf_to_local = px_to_local * inverse(px_to_sdf);
	}

	// Tiling is only used once the manager has published a grid; until then (and in the
	// zero-light case) fall back to looping every light.
	bool tiling_valid = lit_tile_grid.x > 0 && lit_tile_grid.y > 0 && lit_tile_size > 0;

	if (tiling_valid) {
		// Directional lights cover the whole screen, so they're never tiled: shade the
		// leading directional rows for every fragment.
		for (int i = 0; i < lit_directional_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, self_ex, v_local, sdf_to_local);
		}

		// Positional lights: look up this fragment's tile and shade only the lights
		// binned into it. The header gives the offset/count into the flat index list.
		ivec2 tile = ivec2(SCREEN_UV * lit_viewport_size) / lit_tile_size;
		tile = clamp(tile, ivec2(0), lit_tile_grid - ivec2(1));
		vec4 header = texelFetch(lit_tile_headers, tile, 0); // offset | count
		int offset = int(round(header.x));
		int count = int(round(header.y));
		for (int j = 0; j < count; j++) {
			int flat_idx = offset + j;
			ivec2 icoord = ivec2(flat_idx % LIT_INDEX_TEX_WIDTH, flat_idx / LIT_INDEX_TEX_WIDTH);
			int li = int(round(texelFetch(lit_tile_indices, icoord, 0).x));
			lit += lit_shade(li, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, self_ex, v_local, sdf_to_local);
		}
	} else {
		// Fallback: no tile grid published, so iterate every light.
		for (int i = 0; i < lit_light_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, self_ex, v_local, sdf_to_local);
		}
	}

	// Emissive ignores the dark and composes with ambient and lights by construction.
	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	COLOR = vec4(lit + emissive, COLOR.a);
}
