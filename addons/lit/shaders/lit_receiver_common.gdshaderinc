// Shared body of the Lit receiver shader, compiled into thin wrapper variants along
// two axes (never-executed code still taxes a shader, so each feature exists only in
// the variants that need it; LitSprite2D swaps variants automatically and the uniforms
// exist in all of them so parameters survive the swap):
//  - LIT_SELF_EXCLUSION: self-shadow exclusion (lit_receiver.gdshader and the other
//    non-_fast wrappers); the _fast wrappers compile it out - identical output for
//    materials that never populate self_rects.
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
// atlas UV rect in texel 5 and its screen-px-to-cookie-UV matrix in texel 6. Linear
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
// onto it. LitSprite2D syncs one local-space box per owned occluder, unioning extras
// into the last slot; count 0 disables the test.
uniform bool self_shadow = false;
uniform int  self_rect_count = 0;
uniform vec4 self_rects[4];  // local-space min.xy | max.xy each

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

// How far a directional shadow marches across the SDF before it counts as open sky,
// in screen diagonals. Scaling to screen size keeps the fixed step budget
// well-sampled; a fixed huge distance would under-sample the penumbra.
uniform float directional_shadow_reach = 1.0;

// Fragment position in the item's local space, for the self-shadow bounds test.
varying vec2 v_local;

void vertex() {
	v_local = VERTEX;
}

// Slack for the self-bounds test, in SDF units: the SDF is generated at reduced
// resolution, so an outline's zero level sits a texel or two outside its polygon.
const float LIT_SELF_PAD_SDF = 2.0;

// Distance from a local-space point to the nearest self box (0 inside any).
float lit_self_dist(vec2 p_local) {
	float best = 1e20;
	for (int i = 0; i < 4; i++) {
		if (i >= self_rect_count) {
			break;
		}
		vec2 dv = max(max(self_rects[i].xy - p_local, vec2(0.0)), p_local - self_rects[i].zw);
		best = min(best, length(dv));
	}
	return best;
}

// Soft-shadow march of Godot's screen-space SDF (the IQ technique), run on |sdf| -
// the distance field of occluder outlines - so a shape casts from its light-facing
// silhouette and the shadow passes through its body. A fragment starting inside a
// shape takes that shape's shadow via the footprint_shadow ramp instead of a hard hit.
// Returns 1 fully lit, 0 occluded. The caller passes the unit march direction and
// length (dir, maxd, SDF space) and frag_d, its own texture_sdf sample, shared by
// every light's march. k shapes the penumbra estimate k*d/t: the Raymarched algorithm
// derives it from shadow_hardness, the Cone Traced algorithm from the source's angular
// size (k = 1/tan(half-angle)) - same march, different cone width. When self_ex is
// true, samples whose nearest outline may belong to the receiver's own occluders are
// stepped through instead of occluding; self_local and sdf_to_local map SDF-space
// march offsets into local space, and self_scale is the local length of one SDF unit.
float lit_shadow(vec2 frag_sdf, vec2 dir, float maxd, float k, int max_steps, float frag_d,
		bool self_ex, vec2 self_local, mat2 sdf_to_local, float self_scale) {
	float t = shadow_min_step;
	float res = 1.0;
	float prev_d = frag_d;                   // signed; tracks outline crossings
	// A fragment starting inside a shape marches out of it without treating its own
	// outline as hits; the shape's shadow is applied once, at the exit.
	bool grace = prev_d < 0.0;

	// Fast path (no self-exclusion): the three phases - grace, receding, steady - each
	// run at most once, in order, so run each as its own minimal loop sharing the step
	// budget: identical samples, none of the per-step phase bookkeeping. Past the grace
	// exit every sample is non-negative, so the full loop's hit test (|d| < 0.001 ||
	// sign flip) collapses to d < 0.001 and prev_d/abs() drop out. The state-machine
	// loop below remains for self-excluding receivers.
	if (!self_ex) {
		int s = 0;
		max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);  // keep the compile-time cap
		if (grace) {
			// Grace: march out of the containing shape without treating its outline as
			// hits; apply its footprint shadow once, at the exit sample.
			bool receding = false;
			float prev_ad = 0.0;
			for (; s < max_steps && t < maxd; s++) {
				float d = texture_sdf(frag_sdf + dir * t); // signed: negative inside a shape
				if (d < 0.0) {
					t += max(-d, shadow_min_step);         // -d is the distance to the far edge
					continue;
				}
				float own_block = clamp(footprint_shadow * t / maxd, 0.0, 1.0);
				res = min(res, 1.0 - own_block);
				if (res <= 0.0) {
					return 0.0;                            // fully occluded
				}
				prev_ad = d;
				t += max(d, shadow_min_step);
				s++;                                       // this sample consumed a step
				receding = true;
				break;
			}
			// Receding: mute penumbra accumulation until the ray stops receding from
			// the exited edge; the breaking sample follows the steady-state rules.
			if (receding) {
				for (; s < max_steps && t < maxd; s++) {
					float d = texture_sdf(frag_sdf + dir * t);
					if (d >= 0.001 && d >= prev_ad) {
						prev_ad = d;
						t += max(d, shadow_min_step);
						continue;
					}
					if (d < 0.001) {
						return 0.0;                        // fully occluded
					}
					res = min(res, k * d / t);
					t += max(d, shadow_min_step);
					s++;                                   // this sample consumed a step
					break;
				}
			}
		}
		// Steady state: bare IQ march. Track the minimizing (d, t) pair with a
		// cross-multiplied compare and divide once after the loop.
		float best_d = 1e20;
		float best_t = 1.0;
		for (; s < max_steps && t < maxd; s++) {
			float d = texture_sdf(frag_sdf + dir * t);
			if (d < 0.001) {
				return 0.0;                  // fully occluded: inside, on, or across an outline
			}
			if (d * best_t < best_d * t) {   // d/t < best_d/best_t, division-free
				best_d = d;
				best_t = t;
			}
			t += max(d, shadow_min_step);    // sphere-trace advance
		}
		return clamp(min(res, k * best_d / best_t), 0.0, 1.0);
	}

	// Mutes penumbra accumulation while the ray is still receding from the exited edge.
	bool receding = false;
	float prev_ad = 0.0;
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
	// Dynamic loop bounds on purpose: a constant bound invites unrolling this body,
	// which taxes the whole shader even on fragments that never take this path.
	for (int s = 0; s < max_steps && t < maxd; s++) {
		vec2 offset = dir * t;
		float d = texture_sdf(frag_sdf + offset);  // signed: negative inside a shape
		float ad = abs(d);                         // distance to the nearest outline
		if (grace) {
			prev_d = d;
			if (d < 0.0) {
				t += max(-d, shadow_min_step);     // -d is the distance to the far edge
				continue;
			}
			// First exit from the containing shape: apply its shadow, ramped by depth
			// crossed over light distance, unless it is an owned occluder.
			grace = false;
			receding = true;
			prev_ad = ad;
			bool own_exempt = self_ex && lit_self_dist(self_local + sdf_to_local * offset)
					<= (ad + LIT_SELF_PAD_SDF) * self_scale;
			if (!own_exempt) {
				float own_block = clamp(footprint_shadow * t / maxd, 0.0, 1.0);
				res = min(res, 1.0 - own_block);
				if (res <= 0.0) {
					return 0.0;              // fully occluded
				}
			}
			t += max(ad, shadow_min_step);
			continue;
		}
		// A sign flip between consecutive samples catches crossings a min-step
		// advance can hop over.
		bool hit = ad < 0.001 || (d < 0.0) != (prev_d < 0.0);
		prev_d = d;
		if (receding) {
			if (!hit && ad >= prev_ad) {
				prev_ad = ad;
				t += max(ad, shadow_min_step);
				continue;
			}
			receding = false;
		}
		float cand = k * ad / t;
		// Test self-exclusion only when the sample matters (hit or lower penumbra).
		// The nearest outline may be the receiver's own whenever the self bounds lie
		// within |d| of the sample.
		if (hit || cand < res) {
			if (self_ex && lit_self_dist(self_local + sdf_to_local * offset)
					<= (ad + LIT_SELF_PAD_SDF) * self_scale) {
				if (hit) {
					// Crossing an owned occluder: inside it, -d is the distance to
					// the far edge.
					t += max(-d, shadow_min_step);
					continue;
				}
			} else {
				if (hit) {
					return 0.0;              // fully occluded
				}
				res = cand;                  // penumbra accumulation
			}
		}
		t += max(ad, shadow_min_step);
	}
	return clamp(res, 0.0, 1.0);
}

#if defined(LIT_SHADOW_CONE) || defined(LIT_SHADOW_STOCH)
// Hardness for the physical algorithms: the source size sets the penumbra's width,
// hardness reshapes its profile. A contrast curve pivoting on half-lit - 0.5 is
// neutral (identity), higher sharpens the gradient, lower flattens it. Fixes 0, 0.5
// and 1, so umbra and fully-lit regions never shift.
float lit_shadow_contrast(float s, float hardness) {
	float c = exp2((hardness - 0.5) * 4.0);
	return s < 0.5 ? 0.5 * pow(2.0 * s, c) : 1.0 - 0.5 * pow(2.0 * (1.0 - s), c);
}
#endif

#ifdef LIT_SHADOW_CONE
// Cone-traced shadow: march a cone of half-angle tangent w (the source's angular
// radius) instead of a ray, estimating at each step the unblocked fraction of the
// cone's cross-section from the SIGNED distance: 0.5 + d/(w*t) - a sample on an
// outline blocks half the cone, deeper inside blocks more, farther outside less. The
// result is the minimum over the march. Unlike a center-ray hit test this lets the
// umbra CLOSE: far enough behind an occluder the cone is wider than the occluder's
// depth, the minimum rises above 0, and the shadow tapers to a point then re-brightens
// (an approximate antumbra) - the eclipse geometry, from one march. The march advances
// on |d| so it can pass through shape interiors; there is no early hit-exit, but a
// fully-black minimum still returns immediately. Grace/footprint/receding behavior
// matches lit_shadow; in the full variant, samples whose nearest outline may belong to
// the receiver's own occluders never darken (self-exclusion).
float lit_shadow_cone(vec2 frag_sdf, vec2 dir, float maxd, float w, int max_steps, float frag_d,
		bool self_ex, vec2 self_local, mat2 sdf_to_local, float self_scale) {
	float t = shadow_min_step;
	float res = 1.0;
	bool grace = frag_d < 0.0;
	bool receding = false;
	float prev_d = frag_d;
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
	for (int s = 0; s < max_steps && t < maxd; s++) {
		vec2 offset = dir * t;
		float d = texture_sdf(frag_sdf + offset);
		float ad = abs(d);
		if (grace) {
			// March out of the containing shape; apply its footprint shadow once, at
			// the exit sample, unless the shape is an owned occluder.
			if (d < 0.0) {
				t += max(-d, shadow_min_step);
				continue;
			}
			grace = false;
			receding = true;
			prev_d = d;
			bool own_exempt = self_ex && lit_self_dist(self_local + sdf_to_local * offset)
					<= (ad + LIT_SELF_PAD_SDF) * self_scale;
			if (!own_exempt) {
				res = 1.0 - clamp(footprint_shadow * t / maxd, 0.0, 1.0);
				if (res <= 0.0) {
					return 0.0;
				}
			}
			t += max(ad, shadow_min_step);
			continue;
		}
		if (receding) {
			// Mute accumulation while still receding from the exited edge, or the
			// receiver's own surface would count as half-blocking the cone.
			if (d >= prev_d) {
				prev_d = d;
				t += max(ad, shadow_min_step);
				continue;
			}
			receding = false;
		}
		// Half-plane coverage of the cone's cross-section (half-width w*t at distance
		// t): an edge at signed distance d from the cone's center leaves the fraction
		// 0.5 + d/(2*w*t) unblocked, hitting 0 only when the edge is a full half-width
		// past center - which is what lets the umbra close behind small occluders.
		float cand = 0.5 + d / (2.0 * w * t);
		if (cand < res) {
			if (self_ex && lit_self_dist(self_local + sdf_to_local * offset)
					<= (ad + LIT_SELF_PAD_SDF) * self_scale) {
				t += max(ad, shadow_min_step);   // owned occluder: contributes nothing
				continue;
			}
			res = max(cand, 0.0);
			if (res <= 0.0) {
				return 0.0;                      // cone fully blocked; minimum can't recover
			}
		}
		t += max(ad, shadow_min_step);
	}
	return clamp(res, 0.0, 1.0);
}
#endif

#ifdef LIT_SHADOW_STOCH
// Compile-time ceiling on area-light samples; the packed count is clamped to this on
// the CPU as well (lit/quality/shadow_samples_max).
const int LIT_MAX_SHADOW_SAMPLES = 32;

// Hard (binary) march used per stochastic sample: the raymarched march minus the
// penumbra estimate - softness comes from averaging many of these rays, never from a
// single one. Keeps the grace/footprint behavior and (in the full variant) the
// self-exclusion step-through, so every algorithm agrees on those rules.
float lit_shadow_hard(vec2 frag_sdf, vec2 dir, float maxd, int max_steps, float frag_d,
		bool self_ex, vec2 self_local, mat2 sdf_to_local, float self_scale) {
	float t = shadow_min_step;
	float res = 1.0;
	float prev_d = frag_d;
	bool grace = prev_d < 0.0;
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
	for (int s = 0; s < max_steps && t < maxd; s++) {
		vec2 offset = dir * t;
		float d = texture_sdf(frag_sdf + offset);
		float ad = abs(d);
		if (grace) {
			prev_d = d;
			if (d < 0.0) {
				t += max(-d, shadow_min_step);
				continue;
			}
			grace = false;
			bool own_exempt = self_ex && lit_self_dist(self_local + sdf_to_local * offset)
					<= (ad + LIT_SELF_PAD_SDF) * self_scale;
			if (!own_exempt) {
				res = 1.0 - clamp(footprint_shadow * t / maxd, 0.0, 1.0);
				if (res <= 0.0) {
					return 0.0;
				}
			}
			t += max(ad, shadow_min_step);
			continue;
		}
		bool hit = ad < 0.001 || (d < 0.0) != (prev_d < 0.0);
		prev_d = d;
		if (hit) {
			if (self_ex && lit_self_dist(self_local + sdf_to_local * offset)
					<= (ad + LIT_SELF_PAD_SDF) * self_scale) {
				t += max(-d, shadow_min_step);   // step through an owned occluder
				continue;
			}
			return 0.0;
		}
		t += max(ad, shadow_min_step);
	}
	return res;
}

// Stochastic area-light visibility: average n hard marches toward stratified points
// across the source, yielding the visible fraction of the light - true umbra (all rays
// blocked), penumbra (some blocked) and antumbra (a source wider than the occluder is
// never fully blocked). Point/spot: sample points span the emitting disc's diameter
// perpendicular to the light direction, src is its half-extent in SDF units.
// Directional: the march direction deflects across the source's angular extent, src is
// tan(half-angle). jitter blends stratum centers (banding at low n) toward per-pixel
// randomized positions (grain).
float lit_shadow_stoch(vec2 frag_sdf, vec2 light_sdf, vec2 dir, float maxd, float src,
		bool is_dir, int n, float jitter_amt, vec2 noise_px, int max_steps, float frag_d,
		bool self_ex, vec2 self_local, mat2 sdf_to_local, float self_scale) {
	n = clamp(n, 1, LIT_MAX_SHADOW_SAMPLES);
	vec2 perp = vec2(-dir.y, dir.x);
	// Interleaved gradient noise gives the per-pixel base; the golden-ratio sequence
	// decorrelates it across samples.
	float ign = fract(52.9829189 * fract(dot(noise_px, vec2(0.06711056, 0.00583715))));
	float sum = 0.0;
	for (int i = 0; i < n; i++) {
		float rnd = fract(ign + float(i) * 0.61803398875);
		float u = ((float(i) + 0.5 + jitter_amt * (rnd - 0.5)) / float(n)) * 2.0 - 1.0;
		vec2 sdir = dir;
		float smaxd = maxd;
		if (is_dir) {
			sdir = normalize(dir + perp * (u * src));
		} else {
			vec2 delta = (light_sdf + perp * (u * src)) - frag_sdf;
			smaxd = length(delta);
			sdir = delta / max(smaxd, 1e-4);
		}
		sum += lit_shadow_hard(frag_sdf, sdir, smaxd, max_steps, frag_d,
				self_ex, self_local, sdf_to_local, self_scale);
	}
	return sum / float(n);
}
#endif

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
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag, float frag_d,
		bool self_ex, vec2 self_local, mat2 sdf_to_local, float self_scale) {
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

	// Cookie (flags bit 2, point/spot only): modulate the light by its texture. RGB
	// tints, alpha shapes; outside the texture the light is masked to zero, which the
	// negligible-contribution bail below turns into a full skip. Single-exit on
	// purpose: an early return around the atlas read measurably slows every light,
	// textured or not.
	if ((flags & 4) != 0) {
		vec4 t6 = texelFetch(lit_light_data, ivec2(6, i), 0); // px-to-UV matrix columns
		vec2 off_px = (frag_uv - light_uv) * lit_viewport_size;
		vec2 cookie_uv = vec2(0.5) + vec2(dot(t6.xz, off_px), dot(t6.yw, off_px));
		vec2 cl = clamp(cookie_uv, vec2(0.0), vec2(1.0));
		float inside = all(equal(cl, cookie_uv)) ? 1.0 : 0.0;
		vec4 t5 = texelFetch(lit_light_data, ivec2(5, i), 0); // atlas UV rect: min.xy | size.xy
		vec4 cookie = textureLod(lit_cookie_atlas, t5.xy + cl * t5.zw, 0.0);
		light_color *= cookie.rgb * (cookie.a * inside);
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
		vec2 march_dir;
		float march_len;
		if (is_directional) {
			// March a fixed direction across the SDF. screen_uv_to_sdf is affine, so
			// the SDF-space direction comes from offsetting the fragment UV along the
			// toward-light dir; the distance scales with the screen.
			march_dir = normalize(screen_uv_to_sdf(frag_uv + shadow_dir_uv) - frag_sdf);
			march_len = sdf_diag * directional_shadow_reach;
		} else {
			// Point and spot both march toward the light's screen position.
			vec2 delta = screen_uv_to_sdf(light_uv) - frag_sdf;
			march_len = length(delta);
			march_dir = delta / max(march_len, 0.0001);
		}

		// Adaptive step budget: shorter marches need fewer steps to stay well-sampled.
		// Scale by the march length as a fraction of the screen diagonal; keep a floor
		// so very short marches still resolve a penumbra. Off by default (fixed budget).
		int steps = shadow_steps;
		if (lit_shadow_step_scaling) {
			float frac = clamp(march_len / max(sdf_diag, 0.0001), 0.0, 1.0);
			steps = int(ceil(frac * float(lit_shadow_steps_max)));
			steps = clamp(steps, 16, lit_shadow_steps_max);
		}

		// A light sitting on the fragment is fully lit, no march.
		float s;
		if (march_len < 0.0001) {
			s = 1.0;
		} else {
#if defined(LIT_SHADOW_CONE) || defined(LIT_SHADOW_STOCH)
			// Per-light algorithm (flags bits 3-4): 0 raymarched, 1 cone traced,
			// 2 stochastic. Decoded only in the extended shader variants; the base
			// variants compile the raymarched call alone, so scenes that never use the
			// physical algorithms pay nothing for them.
			int algo = (flags >> 3) & 3;
			// SDF units per screen pixel, to convert the packed source size.
			float px_to_sdf = sdf_diag / length(lit_viewport_size);
#ifdef LIT_SHADOW_STOCH
			if (algo == 2) {
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
				// Point/spot: t7.x is the source disc's radius in world px. Directional:
				// t7.x is tan(source half-angle), used as an angular extent directly.
				float src = is_directional ? t7.x : t7.x * lit_canvas_scale * px_to_sdf;
				s = lit_shadow_stoch(frag_sdf, frag_sdf + march_dir * march_len, march_dir,
						march_len, src, is_directional, int(round(t7.y)), t7.z,
						frag_uv * lit_viewport_size, steps, frag_d,
						self_ex, self_local, sdf_to_local, self_scale);
				s = lit_shadow_contrast(s, t3.w);
			} else
#endif
#ifdef LIT_SHADOW_CONE
			if (algo == 1) {
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
				// Cone half-angle tangent: source size over source distance (directional
				// packs the tangent directly).
				float w = is_directional ? t7.x
						: t7.x * lit_canvas_scale * px_to_sdf / max(march_len, 1e-4);
				s = lit_shadow_cone(frag_sdf, march_dir, march_len, max(w, 1e-4), steps,
						frag_d, self_ex, self_local, sdf_to_local, self_scale);
				s = lit_shadow_contrast(s, t3.w);
			} else
#endif
			{
				s = lit_shadow(frag_sdf, march_dir, march_len, mix(8.0, 256.0, t3.w),
						steps, frag_d, self_ex, self_local, sdf_to_local, self_scale);
			}
#else
			// Low hardness is soft, high is crisp.
			s = lit_shadow(frag_sdf, march_dir, march_len, mix(8.0, 256.0, t3.w),
					steps, frag_d, self_ex, self_local, sdf_to_local, self_scale);
#endif
		}
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

	// The fragment's own SDF sample, shared by every light's shadow march.
	float frag_d = texture_sdf(frag_sdf);

	// Screen diagonal in SDF units: the natural scale for a directional shadow's march
	// distance, keeping the step budget well-sampled at any resolution.
	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	// Self-shadow basis: map SDF-space march offsets to local space. Both spaces are
	// affine images of the screen, so probing one pixel step in each and composing is
	// exact. The uniform condition keeps the derivative calls in uniform control flow.
#ifdef LIT_SELF_EXCLUSION
	bool self_ex = !self_shadow && self_rect_count > 0;
#else
	// Fast variant: the constant false compiles the exclusion march, the self basis
	// below, and lit_self_dist out of the shader.
	bool self_ex = false;
#endif
	mat2 sdf_to_local = mat2(vec2(0.0), vec2(0.0));
	float self_scale = 0.0;
	if (self_ex) {
		// Columns: per-pixel-step delta of each space, in x and y.
		mat2 px_to_sdf = mat2(
				screen_uv_to_sdf(SCREEN_UV + vec2(SCREEN_PIXEL_SIZE.x, 0.0)) - frag_sdf,
				screen_uv_to_sdf(SCREEN_UV + vec2(0.0, SCREEN_PIXEL_SIZE.y)) - frag_sdf);
		mat2 px_to_local = mat2(dFdx(v_local), dFdy(v_local));
		sdf_to_local = px_to_local * inverse(px_to_sdf);
		// Local length of one SDF unit, for comparing SDF distances against the bounds.
		self_scale = max(length(sdf_to_local[0]), length(sdf_to_local[1]));
	}

	// Tiling is only used once the manager has published a grid; until then (and in the
	// zero-light case) fall back to looping every light.
	bool tiling_valid = lit_tile_grid.x > 0 && lit_tile_grid.y > 0 && lit_tile_size > 0;

	if (tiling_valid) {
		// Directional lights cover the whole screen, so they're never tiled: shade the
		// leading directional rows for every fragment. Kept separate from the tile loop
		// so the row index stays wave-uniform.
		for (int i = 0; i < lit_directional_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, frag_d, self_ex, v_local, sdf_to_local, self_scale);
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
			lit += lit_shade(li, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, frag_d, self_ex, v_local, sdf_to_local, self_scale);
		}
	} else {
		// Fallback: no tile grid published, so iterate every light.
		for (int i = 0; i < lit_light_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, frag_d, self_ex, v_local, sdf_to_local, self_scale);
		}
	}

	// Emissive ignores the dark and composes with ambient and lights by construction.
	// Zero strength skips the mask fetch.
	vec3 emissive = vec3(0.0);
	if (emissive_strength != 0.0) {
		emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;
	}

	COLOR = vec4(lit + emissive, COLOR.a);
}
