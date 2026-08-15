// Unit: per-light shading core: lit_shade().

// Shade this fragment by light row `i` and return its contribution (negative for a
// subtractive light). Called once per light affecting the fragment, from the directional
// sweep and the per-tile loop in fragment(). metallic/roughness are sampled once per
// fragment by the caller and used only in PBR mode.
vec3 lit_shade(int i, vec3 albedo, vec3 N, vec3 spec_shin, float shininess,
		float metallic, float roughness,
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag, float frag_d,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS) {
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
		// texture_offset (flags bit 18): t8.xy replaces the node-centered 0.5.
		vec2 center = (flags & 262144) != 0
				? texelFetch(lit_light_data, ivec2(8, i), 0).xy : vec2(0.5);
		vec2 cookie_uv = center + vec2(dot(t6.xz, off_px), dot(t6.yw, off_px));
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
#ifdef LIT_OCC_MASKS
		// Per-light exclusions (flags bit 5): t10 = union bounds of the exempt rects.
		bool mk_on = (flags & 32) != 0;
		int mk_row = i;
		vec4 mk_rect = mk_on ? texelFetch(lit_light_data, ivec2(10, i), 0) : vec4(0.0);
#endif
#ifdef LIT_OCC_RX
		// The light's shadow mask (t7.w), for the effective-layer rx ignore test.
		int rx_smask = int(round(texelFetch(lit_light_data, ivec2(7, i), 0).w));
#endif
		// SDF units per screen pixel, to convert world-px shadow fields.
		float px_to_sdf = sdf_diag / length(lit_viewport_size);

		vec2 march_dir;
		float march_len;
		if (is_directional) {
			// March a fixed direction across the SDF. screen_uv_to_sdf is affine, so
			// the SDF-space direction comes from offsetting the fragment UV along the
			// toward-light dir. t1.z is the light's shadow_reach in world px, so the
			// march length is zoom-invariant - never a screen-derived distance.
			march_dir = normalize(screen_uv_to_sdf(frag_uv + shadow_dir_uv) - frag_sdf);
			march_len = t1.z * lit_canvas_scale * px_to_sdf;
		} else {
			// Point and spot both march toward the light's screen position.
			vec2 delta = screen_uv_to_sdf(light_uv) - frag_sdf;
			march_len = length(delta);
			march_dir = delta / max(march_len, 0.0001);
		}

		// shadow_length (flags bits 6-17, quantized 12 bits): fraction of the march the
		// shadow may cover; the marchers close every umbra at t_cap over a tip band one
		// cone-width wide (lit_tip_weight). Directional: fraction of shadow_reach, whose
		// end is a real world boundary, so the closure always applies. Point/spot:
		// fraction of the fragment-to-light distance; 0 = full march, uncapped.
		int cap_q = (flags >> 6) & 4095;
		float t_cap = march_len;
		bool capped = is_directional;
		if (is_directional) {
			t_cap = march_len * float(cap_q) * (1.0 / 4095.0);
		} else if (cap_q != 0) {
			t_cap = march_len * float(cap_q) * (1.0 / 4095.0);
			capped = true;
		}

		// Adaptive step budget: shorter marches need fewer steps to stay well-sampled.
		// Scale by the march length as a fraction of the screen diagonal; keep a floor
		// so very short marches still resolve a penumbra. Off by default (fixed budget).
		int steps = shadow_steps;
		if (lit_shadow_step_scaling) {
			float frac = clamp(t_cap / max(sdf_diag, 0.0001), 0.0, 1.0);
			steps = int(ceil(frac * float(lit_shadow_steps_max)));
			steps = clamp(steps, 16, lit_shadow_steps_max);
		}

		// A light sitting on the fragment is fully lit, no march.
		float s;
#ifdef LIT_OCC_RX
		// Effective-layer algebra: a caster contributes only when m & smask != 0, and
		// its cast is ignored when (m & smask) & rx_mask != 0. With smask inside
		// rx_mask every possible contribution is ignored, so the march is skipped as
		// exactly lit. smask == 0 means the mask wasn't packed; never skip on it.
		if (rx_mask != 0 && rx_smask != 0 && (rx_smask & ~rx_mask) == 0) {
			s = 1.0;
		} else
#endif
		if (t_cap < 0.0001) {
			s = 1.0;
		} else {
#if defined(LIT_SHADOW_CONE) || defined(LIT_SHADOW_STOCH)
			// Per-light algorithm (flags bits 3-4): 0 raymarched, 1 cone traced,
			// 2 stochastic. Decoded only in the extended shader variants; the base
			// variants compile the raymarched call alone, so scenes that never use the
			// physical algorithms pay nothing for them.
			int algo = (flags >> 3) & 3;
#ifdef LIT_SHADOW_STOCH
			if (algo == 2) {
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
				// Point/spot: t7.x is the source disc's radius in world px. Directional:
				// t7.x is tan(source half-angle), used as an angular extent directly.
				float src = is_directional ? t7.x : t7.x * lit_canvas_scale * px_to_sdf;
				s = lit_shadow_stoch(frag_sdf, frag_sdf + march_dir * march_len, march_dir,
						march_len, t_cap, src, is_directional, int(round(t7.y)), t7.z,
						frag_uv * lit_viewport_size, steps, frag_d,
						self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
				s = lit_shadow_contrast(s, t3.w);
			} else
#endif
#ifdef LIT_SHADOW_CONE
			if (algo == 1) {
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
				// Cone half-angle tangent: source size over source distance (directional
				// packs the tangent directly).
				float w = max(is_directional ? t7.x
						: t7.x * lit_canvas_scale * px_to_sdf / max(march_len, 1e-4), 1e-4);
				s = lit_shadow_cone(frag_sdf, march_dir, t_cap, march_len,
						capped ? w * t_cap : 0.0, w, steps,
						frag_d, !is_directional && !capped, self_ex, self_canvas, sdf_to_canvas,
						self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
				s = lit_shadow_contrast(s, t3.w);
			} else
#endif
			{
				float k = mix(8.0, 256.0, t3.w);
				s = lit_shadow(frag_sdf, march_dir, t_cap, march_len, capped ? t_cap / k : 0.0,
						k, steps, frag_d, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
			}
#else
			// Low hardness is soft, high is crisp.
			float k = mix(8.0, 256.0, t3.w);
			s = lit_shadow(frag_sdf, march_dir, t_cap, march_len, capped ? t_cap / k : 0.0,
					k, steps, frag_d, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
#endif
		}
		contribution *= mix(t3.rgb, vec3(1.0), s);
	}

	// Subtract mode is negative light: it carves darkness below ambient, and the
	// final COLOR clamps at display.
	return subtractive ? -contribution : contribution;
}

