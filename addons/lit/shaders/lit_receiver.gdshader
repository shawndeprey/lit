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

// Stained-glass tint buffer. A screen-space RGBA image where translucent occluders
// (gems) have painted their body color (RGB) and how much they tint passing light (A).
// When a shadow march crosses one of these, the blocked light is recolored by the tint
// instead of going fully black, which is how a gem casts a colored glow of the light
// shining through it. Published by whoever fills the buffer (the demo's SubViewport);
// when nothing publishes it the default-black/zero-alpha texture leaves shadows neutral,
// so this is a no-op for ordinary scenes. Sampled with screen UVs. filter_linear so a
// reduced-resolution buffer (the demo renders it at half res) reads as naturally soft
// cast edges instead of blocky texels, regardless of the receiver's own texture filter.
global uniform sampler2D lit_tint_buffer : filter_linear;
global uniform bool      lit_tint_enabled = false;

// Colored light projection (the "stained-glass pools" cast onto the background). Separate
// from the shadow-recolor above: this is an ADDITIVE pass that throws each translucent
// gem's body color onto nearby lit surfaces as a soft glowing pool, the way light through
// coloured glass lands on a wall. It samples the tint buffer in a ring around each fragment
// (so the colour bleeds outward from every gem, not only inside a hard shadow) and adds it,
// scaled by lit_cast_strength, spread over lit_cast_radius screen-UV units. 0 strength =
// off. The pools inherit the scene's light energy so they brighten with the lighting.
global uniform float lit_cast_strength = 0.0;
global uniform float lit_cast_radius = 0.06;

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

// --- Translucency / transmission -----------------------------------------------------
// Subsurface-style wrap lighting: light striking the BACK of the surface (N.L < 0) bleeds
// through and glows on the lit side, tinted by albedo. transmission_strength scales the
// whole effect; the transmission_map masks it per-texel (thin/edge areas transmit more);
// transmission_wrap softens how far past the terminator the glow reaches. Works in both
// Phong and PBR. 0 strength is fully opaque (the original look), so this is opt-in.
uniform float transmission_strength : hint_range(0.0, 4.0) = 0.0;
uniform sampler2D transmission_map : hint_default_white;
uniform float transmission_wrap : hint_range(0.0, 1.0) = 0.5;

// --- Internal facets (refraction sparkle) -------------------------------------------
// Gems read as gems because you see light bouncing off their INNER facets through the
// body, not just off the outer surface. We fake that with a second normal map (the old
// internal_n art) driving an extra specular lobe: bright, tight glints that sit under the
// surface, tinted by the gem color and gated by transmission so they only appear where
// the stone is translucent. internal_strength scales it; internal_sharpness controls how
// tight the sparkle is (higher = smaller, brighter facets). This is a stylised effect,
// not real refraction, but it restores the internal structure the flat outer normal loses.
// 0 strength = off, so ordinary receivers are unaffected. Works in both lighting models.
uniform float internal_strength : hint_range(0.0, 4.0) = 0.0;
uniform sampler2D internal_normal_map : hint_normal;
uniform float internal_sharpness : hint_range(1.0, 128.0) = 48.0;

// --- Refractive glass (transparency + background refraction + dispersion) ------------
// Turns the receiver from an opaque lit surface into a tinted glass body: the background
// behind the gem is sampled from the screen, bent by the surface normal (refraction) and
// split per-RGB-channel (chromatic dispersion / diffraction), then the lit gem is composed
// over it. glass_strength is the master switch (0 = fully opaque, the original behaviour).
// glass_refraction is how far the normal bends the background sample (in screen UVs);
// glass_dispersion adds the rainbow channel split; glass_tint_depth controls how strongly
// the gem body color filters what you see through it; glass_opacity is the gem's own
// surface presence over the refracted background (higher = more solid/frosted). The screen
// read uses hint_screen_texture, which Godot backs with a copy of the framebuffer behind
// this draw, so gems must draw after the background (they do: they're in front).
uniform float glass_strength : hint_range(0.0, 1.0) = 0.0;
uniform float glass_refraction : hint_range(0.0, 0.2) = 0.04;
uniform float glass_dispersion : hint_range(0.0, 0.1) = 0.02;
uniform float glass_tint_depth : hint_range(0.0, 2.0) = 0.8;
uniform float glass_opacity : hint_range(0.0, 1.0) = 0.35;
uniform sampler2D lit_screen_tex : hint_screen_texture;

uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

// --- Area-light soft shadows ----------------------------------------------------------
// A single SDF march gives the IQ k*d/t penumbra, whose softness is capped by the
// hardness constant and doesn't grow with occluder distance the way a real light's
// does. When shadow_penumbra_px > 0 the light is treated as a disc of that radius (in
// screen pixels): several marches aim at points spread across the light's width,
// perpendicular to the ray and jittered per fragment, and the results average. Shadows
// then stay crisp where the caster touches the receiver and fan out with distance --
// contact-hardening, the signature of area lighting. Cost is one full march per tap on
// shadowed key lights only; 0 radius keeps the original single cheap march, so ordinary
// receivers pay nothing. Works for directionals too (the offset reads as angular size).
uniform float shadow_penumbra_px : hint_range(0.0, 128.0) = 0.0;
uniform int   shadow_penumbra_taps : hint_range(1, 4) = 3;

// Stained-glass shadow transmittance: what FRACTION of a blocked light passes through a
// gem and lands as its colored shadow. A real gem absorbs most of the light hitting it and
// transmits only a little, so its cast shadow is DIMMER than the fully-lit surface, just
// tinted. Without this the colored shadow was lifted toward the light's full brightness
// (light_color * gem_hue), so grazing a bright point light produced bright colored patches
// instead of dim colored shadows -- the blown-out pools on the outer wall. 0 = opaque
// (plain dark shadow, no color passes), 1 = fully transparent (no dimming). Keep it low;
// the colored shadow should read as a shadow first, a color second.
uniform float lit_shadow_transmittance : hint_range(0.0, 1.0) = 0.35;

// Distance falloff of the colored cast along its streak, in screen pixels. Real caustic
// pools are brightest just past the object and die off with distance; this measures the
// ray distance from the shadowed fragment back to the FIRST gem crossing and attenuates
// the transmitted color by exp(-dist / falloff). 0 disables (constant brightness along
// the whole streak, the previous behaviour), so ordinary receivers are unaffected.
uniform float tint_cast_falloff : hint_range(0.0, 4000.0) = 0.0;

// Animated shimmer on the colored casts: two slow drifting sine bands multiplied into
// the transmitted color, so the pools ripple faintly like light through imperfect glass.
// Value is the peak amplitude as a fraction of cast brightness; 0 disables. Purely a
// brightness modulation, so it can't push the cast negative or shift its hue.
uniform float tint_shimmer : hint_range(0.0, 1.0) = 0.0;

// Horizontal reach of a directional light's shading vector relative to its `height`;
// elevation is atan(height / scale). The default gives about 27 degrees at height 16,
// so the direction reads clearly. Larger is more grazing.
uniform float directional_horizontal_scale = 32.0;

// How far a directional shadow marches across the SDF before it counts as open sky,
// in screen diagonals. Scaling to screen size keeps the fixed step budget
// well-sampled; a fixed huge distance would under-sample the penumbra.
uniform float directional_shadow_reach = 1.0;

// Soft-shadow march of Godot's screen-space SDF (the IQ technique). Works in SDF
// space, marching from the fragment toward the light and tracking the running minimum
// of k * d / t for the penumbra. Returns 1 fully lit, 0 occluded. max_steps lets the
// caller spend fewer iterations on short marches; the loop bound stays constant so it
// can unroll.
float lit_shadow(vec2 frag_sdf, vec2 light_sdf, float hardness, int max_steps) {
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
		float d = texture_sdf(frag_sdf + dir * t);
		if (d < 0.001) {
			return 0.0;                      // fully occluded
		}
		res = min(res, k * d / t);           // penumbra accumulation
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
		float metallic, float roughness, vec3 transmission_col,
		vec3 internal_N, float internal_amt,
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag) {
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

	// --- Translucency: light coming through the surface from behind ---------------------
	// A wrapped back-light term. On the front face ndotl handles it; here we capture the
	// light hitting the far side (dot(N, Ldir) < 0) and let it bleed through, softened by
	// transmission_wrap so the glow eases past the terminator instead of switching on hard.
	// Tinted by transmission_col (albedo * the _t map), so a red gem glows red where the
	// light shines through it. Scaled by atten/energy/light_color like the direct terms, so
	// it respects range, cone, and the light's hue.
	if (transmission_strength > 0.0) {
		float back = dot(N, Ldir);                       // negative on the far side
		float wrap = mix(0.0, 1.0, transmission_wrap);
		// Remap so the glow peaks when the light is straight behind the surface and fades
		// to nothing as it comes around to the front.
		float t_amount = clamp((-back + wrap) / (1.0 + wrap), 0.0, 1.0);
		t_amount *= t_amount;                            // soften the falloff
		contribution += transmission_col * light_color * energy * atten * t_amount * transmission_strength;
	}

	// --- Internal facets: sparkle off the inner normals seen through the body -----------
	// A second Blinn-Phong-style specular lobe using internal_N (the internal_normal_map)
	// instead of the surface normal N. The half-vector uses a straight-on 2D view (+Z), so
	// this reads as tight glints from the gem's back facets. Tinted toward the gem color
	// (transmission_col) so the sparkle carries the stone's hue, and scaled by internal_amt
	// which the caller has already multiplied by the transmission mask, so inner facets only
	// shine where the gem is actually translucent. Gated on both strengths for zero cost off.
	if (internal_strength > 0.0 && internal_amt > 0.0) {
		vec3 V = vec3(0.0, 0.0, 1.0);
		vec3 H = normalize(Ldir + V);
		float in_dot = max(dot(internal_N, H), 0.0);
		float sparkle = pow(in_dot, internal_sharpness);
		// Only when the light is on the front side of the internal facet.
		float face = clamp(dot(internal_N, Ldir), 0.0, 1.0);
		vec3 tint = mix(vec3(1.0), transmission_col, 0.6);   // mostly white glint, gem-tinted
		contribution += tint * light_color * energy * atten * sparkle * face * internal_amt * internal_strength;
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

		float s;
		if (shadow_penumbra_px > 0.0) {
			// Disc light: spread the march targets across the light's width, perpendicular
			// to the fragment->light ray. Tap positions are stratified across [-1, 1] and
			// the whole comb slides by a per-fragment hash (a different seed than the tint
			// jitter so the two noises don't correlate), turning the 3-4 discrete penumbra
			// bands into smooth gradient noise.
			vec2 ray = light_sdf - frag_sdf;
			float rl = max(length(ray), 1e-4);
			vec2 perp = vec2(-ray.y, ray.x) / rl;
			// Screen pixels -> SDF units, via the diagonal ratio (screen_uv_to_sdf is affine).
			float radius = shadow_penumbra_px * sdf_diag / length(lit_viewport_size);
			float jj = fract(sin(dot(frag_uv, vec2(41.317, 17.923))) * 24571.213) - 0.5;
			int taps = clamp(shadow_penumbra_taps, 1, 4);
			s = 0.0;
			for (int pt = 0; pt < 4; pt++) {
				if (pt >= taps) {
					break;                       // constant loop bound so it can unroll
				}
				float u = (float(pt) + 0.5 + jj) / float(taps) * 2.0 - 1.0;
				s += lit_shadow(frag_sdf, light_sdf + perp * radius * u, t3.w, steps);
			}
			s /= float(taps);
		} else {
			s = lit_shadow(frag_sdf, light_sdf, t3.w, steps);
		}

		// Stained-glass cast: where this fragment is shadowed, check whether the occluder
		// between it and the light is a translucent tinted body (a gem). If so, the light
		// it blocks doesn't go fully dark -- some passes through, recolored by the gem. We
		// sample the tint buffer partway along the march (toward the light, where the
		// caster sits) and, weighted by the tint's alpha, lift the shadowed result toward
		// the light's hue times the gem color. Only runs when a tint buffer is published
		// and this light is actually occluded, so unshadowed pixels and ordinary scenes
		// pay nothing extra.
		vec3 shadow_rgb = t3.rgb;
		if (lit_tint_enabled && s < 0.999) {
			// March the blocked ray from fragment to light and treat every gem the ray
			// crosses as a colored filter, the way real light travels through a stack of
			// stained glass. Three discrete taps gave a cascade of shrinking copies with
			// gaps between them (nothing was sampled between the fixed fractions); a dense
			// walk samples the ray continuously so the colored shadow is unbroken.
			//
			// The march target depends on the light type. Point/spot lights have a screen
			// position (light_uv). Directionals DON'T: their t1.xy is a unit screen-space
			// direction, so treating it as a UV would march toward a fixed bogus point
			// (e.g. (0.7, -0.7), off-screen) and paint garbage. Instead, walk along the
			// same toward-light direction and reach the SDF shadow march uses, so the tint
			// samples the exact corridor the occlusion came from.
			vec2 tint_end;
			if (is_directional) {
				// shadow_dir_uv is a unit pixel direction expressed in UVs; scale by the
				// screen diagonal in pixels for the same reach as the SDF march.
				tint_end = frag_uv + shadow_dir_uv * length(lit_viewport_size) * directional_shadow_reach;
			} else {
				tint_end = light_uv;
			}
			//
			// Filtering is MULTIPLICATIVE: transmitted light starts white and each gem the
			// ray passes through multiplies it by that gem's body color (weighted by its
			// coverage alpha). Overlapping gems therefore darken and saturate toward the
			// product of their colors instead of summing toward white, which is how colored
			// glass actually stacks. `ray_cov` tracks peak coverage so we know how much of
			// the shadow to recolor vs. leave as the plain shadow color.
			//
			// Sample count scales with the segment length (aiming for a sample every
			// ~12 px, clamped) so a directional's full-diagonal march doesn't step 50+ px
			// at a time and skip small gems, while short fragment->light rays don't waste
			// taps. Count-dependence of the result is negligible: the hue is renormalized
			// below and coverage is a max, so only "which gems did the ray cross" matters.
			const int LIT_TINT_MARCH_MAX = 48;
			float seg_px = length((tint_end - frag_uv) * lit_viewport_size);
			int tint_steps = clamp(int(ceil(seg_px / 12.0)), 8, LIT_TINT_MARCH_MAX);
			// Per-fragment jitter de-bands the discrete sampling. Each fixed fraction f
			// projects an enlarged copy of the gem footprint about the light (scale
			// 1/(1-f)); where consecutive copies of a small feature separate, the gaps
			// read as a cascade of repeated silhouettes marching toward the light.
			// Sliding every fragment's sample comb by a screen-hash phase decorrelates
			// neighbouring fragments, turning those coherent gaps into sub-pixel noise.
			float jitter = fract(sin(dot(frag_uv, vec2(12.9898, 78.233))) * 43758.5453);
			vec3 filtered = vec3(1.0);            // running transmitted color, starts clear
			float ray_cov = 0.0;                  // strongest gem coverage along the ray
			float hit_f = 1.0;                    // ray fraction of the FIRST gem crossing (1 = none)
			for (int ts = 1; ts <= LIT_TINT_MARCH_MAX; ts++) {
				if (ts > tint_steps) {
					break;                        // constant loop bound so it can unroll
				}
				float f = (float(ts) - jitter) / float(tint_steps + 1);
				vec4 tt = texture(lit_tint_buffer, mix(frag_uv, tint_end, f));
				// Per-sample filter: mix toward this gem's color by its coverage. A ray that
				// grazes only the edge (low alpha) barely tints; a solid crossing tints fully.
				filtered *= mix(vec3(1.0), tt.rgb, tt.a);
				ray_cov = max(ray_cov, tt.a);
				// First substantive crossing, as a fraction of the march. Since the march runs
				// fragment -> light, this is how far the caster sits from THIS fragment, which
				// is exactly the distance a caustic pool fades over.
				if (tt.a > 0.05) {
					hit_f = min(hit_f, f);
				}
			}
			// Saturate the transmitted hue so a gem the ray only partly crossed still casts a
			// readable color instead of a washed near-white. We renormalize `filtered` to its
			// brightest channel (pushing it to a pure hue) and then reintroduce brightness via
			// transmittance below. This is what stops the grazing-ray majority -- where the raw
			// `filtered` stays near white -- from producing a colorless shadow.
			float mx = max(filtered.r, max(filtered.g, filtered.b));
			vec3 hue = (mx > 0.001) ? filtered / mx : vec3(1.0);
			// Light that survives the stack: the light's hue, tinted to the gem hue, and
			// ATTENUATED by transmittance so the colored shadow is DIMMER than the lit surface
			// (a gem absorbs most of the light; only a fraction transmits). Brightness comes
			// from transmittance; color comes from `hue`. Kept independent so the earlier bug --
			// lifting the shadow toward full-brightness colored light and blowing out the wall --
			// can't recur, while the tint stays vivid.
			vec3 through = light_color * hue * lit_shadow_transmittance;
			// Caustic falloff: the pool is brightest just past the gem and dies off along the
			// streak. hit_f * seg_px is the pixel distance from this fragment back to the gem
			// that cast on it. Gated so a scene that never sets the uniform pays nothing and
			// keeps the constant-brightness streak.
			if (tint_cast_falloff > 0.0) {
				through *= exp(-(hit_f * seg_px) / tint_cast_falloff);
			}
			// Watery shimmer: two drifting sine bands at unrelated scales/speeds, multiplied
			// into brightness only. Cheap (no texture), tiles nothing, and stays positive for
			// any tint_shimmer <= 1 since the combined term is in [-2, 2] * 0.25.
			if (tint_shimmer > 0.0) {
				vec2 p = frag_uv * lit_viewport_size;
				float n = sin(p.x * 0.021 + p.y * 0.017 + TIME * 1.3)
						+ sin(p.x * 0.007 - p.y * 0.011 - TIME * 0.7);
				through *= 1.0 + tint_shimmer * 0.25 * n;
			}
			// How much of THIS shadow is actually a gem-cast (vs. a plain occluder). Driven by
			// the ray's peak coverage, so a ray that genuinely crossed a gem recolors fully and
			// open stretches stay the plain shadow color. Grazing rays (low coverage) fade in
			// smoothly rather than snapping off, keeping the streak edges soft.
			shadow_rgb = mix(shadow_rgb, through, ray_cov);
		}
		contribution *= mix(shadow_rgb, vec3(1.0), s);
	}

	// Subtract mode is negative light: it carves darkness below ambient, and the
	// final COLOR clamps at display.
	return subtractive ? -contribution : contribution;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 albedo = tex.rgb * COLOR.rgb;
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

	// Per-fragment transmission color: the gem's body color (albedo) masked by the _t map.
	// Sampled once and handed to every light's lit_shade so the back-light glow is tinted
	// per-texel. Skipped entirely when transmission is off (the common case).
	vec3 transmission_col = vec3(0.0);
	if (transmission_strength > 0.0) {
		transmission_col = albedo * texture(transmission_map, UV).rgb;
	}

	// Internal-facet normal + how much this texel sparkles. Decode the internal_normal_map
	// (tangent-space RGB -> vector) and gate the effect by the transmission mask so inner
	// facets only glint where the gem is translucent. Skipped when internal facets are off.
	vec3 internal_N = N;
	float internal_amt = 0.0;
	if (internal_strength > 0.0) {
		vec3 in_rgb = texture(internal_normal_map, UV).rgb;
		internal_N = normalize(in_rgb * 2.0 - 1.0);
		// Coverage: the transmission map doubles as "where is the gem body", so reuse it.
		internal_amt = texture(transmission_map, UV).r;
	}

	vec2 frag_uv = SCREEN_UV;                     // canonical screen-UV space
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  // shadow-march space

	// Screen diagonal in SDF units: the natural scale for a directional shadow's march
	// distance, keeping the step budget well-sampled at any resolution.
	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	// Tiling is only used once the manager has published a grid; until then (and in the
	// zero-light case) fall back to looping every light.
	bool tiling_valid = lit_tile_grid.x > 0 && lit_tile_grid.y > 0 && lit_tile_size > 0;

	if (tiling_valid) {
		// Directional lights cover the whole screen, so they're never tiled: shade the
		// leading directional rows for every fragment.
		for (int i = 0; i < lit_directional_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, transmission_col, internal_N, internal_amt, frag_uv, frag_sdf, sdf_diag);
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
			lit += lit_shade(li, albedo, N, spec_shin, shininess, metallic, roughness, transmission_col, internal_N, internal_amt, frag_uv, frag_sdf, sdf_diag);
		}
	} else {
		// Fallback: no tile grid published, so iterate every light.
		for (int i = 0; i < lit_light_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, transmission_col, internal_N, internal_amt, frag_uv, frag_sdf, sdf_diag);
		}
	}

	// Emissive ignores the dark and composes with ambient and lights by construction.
	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	// NOTE: Colored "stained-glass pools" on the wall are produced entirely by the
	// per-light shadow-tint march inside lit_shade (the block that samples lit_tint_buffer
	// along the fragment->light ray and recolors the shadow). That is the physically
	// correct projection: a wall fragment sitting behind a gem relative to the light has a
	// ray that passes through the gem, picks up its color, and casts it onto the wall in the
	// correct direction, streaking away from the light.
	//
	// A separate additive "cast" pass used to live here. It ring-sampled the tint buffer in
	// 8 directions around each fragment with no knowledge of the light position, so it drew a
	// direction-agnostic halo of each gem's own footprint (the ring of copies circling a lone
	// gem) and blew out on the wall near any gem regardless of whether light actually passed
	// through one. It was removed: it was never a light projection, just a proximity blur, and
	// it fought the correct shadow-march result. lit_cast_strength / lit_cast_radius are now
	// unused by the shader (kept as globals so the manager/demo don't error on the set calls).

	// --- Refractive glass compositing --------------------------------------------------
	// When glass is on, the gem stops being an opaque lit lump. We look at the background
	// through it: sample the screen behind, bent by the surface normal so facets warp what's
	// behind them, with a per-channel offset for chromatic dispersion (the rainbow diffraction
	// the Blinn-Phong version had). The gem body color filters that view (colored glass), and
	// the lit terms we already computed (specular, transmission glow, internal sparkle,
	// emissive) add on top as surface light. Alpha stays high enough to read as a solid object
	// but the refracted background is baked into RGB, so it looks see-through.
	if (glass_strength > 0.0) {
		// Bend the background sample by the surface normal's xy. Deeper (more tilted) facets
		// refract more. Screen-space, so it warps whatever wall is behind the gem.
		vec2 bend = N.xy * glass_refraction * glass_strength;
		vec2 disp = N.xy * glass_dispersion * glass_strength;
		// Per-channel offset = dispersion: R bent a touch more than B, so edges rainbow-split.
		vec3 refracted;
		refracted.r = texture(lit_screen_tex, SCREEN_UV + bend + disp).r;
		refracted.g = texture(lit_screen_tex, SCREEN_UV + bend).g;
		refracted.b = texture(lit_screen_tex, SCREEN_UV + bend - disp).b;

		// Filter the view through the gem's body color (colored glass). glass_tint_depth
		// controls how strongly the color absorbs the transmitted background. Up to 1.0 it
		// blends white->albedo; past 1.0 it keeps darkening toward albedo^depth, so deeply
		// tinted gems absorb more and stacked overlaps saturate like real stained glass
		// instead of washing back toward the raw background.
		float td = clamp(glass_tint_depth, 0.0, 2.0);
		vec3 body = mix(vec3(1.0), albedo, min(td, 1.0));
		if (td > 1.0) {
			body *= mix(vec3(1.0), albedo, td - 1.0);   // extra absorption pass
		}
		vec3 through = refracted * body;
		// A little of the gem's own transmission color adds saturation to the glass.
		through += transmission_col * 0.15;

		// The lit surface (specular highlights, internal sparkle, transmission wrap, emissive)
		// sits ON TOP of the see-through body. The ambient/diffuse part of `lit` is folded in
		// lightly via glass_opacity so the gem still has some body presence, not pure window.
		vec3 surface = lit * glass_opacity + emissive;
		// Specular/sparkle peaks should punch through, but they must NOT accumulate through the
		// glass-layering back-buffer chain: each gem reads the gems behind it via lit_screen_tex,
		// so a raw `+ surface` at every layer sums N surface terms across N overlapping gems and
		// runs the overlaps (and the tilted edges, where specular peaks) to white. That feedback
		// was the real blow-out. So we (a) tint the surface light by the gem body first, so it
		// filters like the rest of the glass instead of adding neutral white, and (b) roll it off
		// with a soft knee per channel so a bright layer over an already-bright background adds
		// progressively less, converging instead of clipping. Single gems look the same; stacks
		// now saturate toward the product of their colors.
		vec3 surface_tinted = surface * mix(vec3(1.0), albedo, 0.5);
		vec3 base = through * (1.0 - glass_opacity * 0.5);
		vec3 headroom = max(vec3(1.0) - base, 0.0);        // how much room to white is left
		vec3 glass_rgb = base + surface_tinted * headroom; // fades the add as the pixel fills up

		// Alpha: glass is mostly opaque at the framebuffer (we've already composited the
		// background into RGB), but we let the very thinnest edges fade a touch for softness.
		float a = tex.a * COLOR.a;
		COLOR = vec4(glass_rgb, a);
	} else {
		COLOR = vec4(lit + emissive, tex.a * COLOR.a);
	}
}
