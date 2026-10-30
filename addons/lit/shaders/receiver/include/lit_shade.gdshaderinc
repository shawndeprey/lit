// Unit: per-light shading core: lit_shade().

#ifdef LIT_LINE
// The source a line light's strata tile: the part of the segment within range of the
// fragment, as its middle (screen UV, xy) and half-vector (screen px, zw), so no stratum
// stands for light that never reaches the fragment. t4 = half.xy | glow | half width.
vec4 lit_line_window(vec4 t4, vec2 light_uv, vec2 frag_uv, float range) {
	vec2 d = (light_uv - frag_uv) * lit_viewport_size;
	float r_px = range * lit_canvas_scale;
	float inv2 = 1.0 / max(dot(t4.xy, t4.xy), 1e-6);
	float b = dot(d, t4.xy) * inv2;
	float e = sqrt(max((r_px * r_px - dot(d, d)) * inv2 + b * b, 0.0));
	float u0 = max(-b - e, -1.0);
	float u1 = min(-b + e, 1.0);
	return vec4(light_uv + t4.xy * (0.5 * (u0 + u1)) / lit_viewport_size, t4.xy * (0.5 * (u1 - u0)));
}

// Nearest point of a curved line light's arc chain to `p` (screen px): path texture row
// `row`, `count` arcs from texel 1 on, each texel a point and the bulge (the tangent of
// a quarter of the sweep) of the arc leaving it. Returns the point and its distance.
vec3 lit_path_nearest(int row, int count, vec2 p) {
	vec4 cur = texelFetch(lit_light_path, ivec2(1, row), 0);
	float best = 1e30;
	vec2 q = cur.xy;
	for (int k = 1; k <= count; k++) {
		vec4 nxt = texelFetch(lit_light_path, ivec2(1 + k, row), 0);
		vec2 a = cur.xy;
		vec2 ab = nxt.xy - a;
		float bu = cur.z;
		float l2 = dot(ab, ab);
		vec2 cq;
		if (abs(bu) < 1e-3 || l2 < 1e-8) {
			cq = a + ab * clamp(dot(p - a, ab) / max(l2, 1e-8), 0.0, 1.0);
		} else {
			// The circle through a and nxt: its sagitta and radius ride on 1 / bu, the
			// sector test and the projection on one inversesqrt of |v|^2 |ab|^2.
			vec2 perp = vec2(-ab.y, ab.x);
			float rb = 1.0 / bu;
			float bu2 = bu * bu;
			vec2 c = a + ab * 0.5 - perp * ((1.0 - bu2) * 0.25 * rb);
			vec2 v = p - c;
			float s = inversesqrt(max(dot(v, v), 1e-12) * l2);
			if (dot(v, perp) * sign(bu) * s * (1.0 + bu2) >= 1.0 - bu2) {
				cq = c + v * ((1.0 + bu2) * 0.25 * abs(rb) * l2 * s);
			} else {
				cq = dot(p - a, p - a) < dot(p - nxt.xy, p - nxt.xy) ? a : nxt.xy;
			}
		}
		float d2 = dot(p - cq, p - cq);
		if (d2 < best) {
			best = d2;
			q = cq;
		}
		cur = nxt;
	}
	return vec3(q, sqrt(best));
}
#endif

// Shade this fragment by light row `i` and return its contribution (negative for a
// subtractive light). Called once per light affecting the fragment, from the directional
// sweep and the per-tile loop in fragment(). metallic/roughness are sampled once per
// fragment by the caller and used only in PBR mode. In the _line variants `positional`
// is a call-site constant: the directional sweep passes false, so its inlined copy
// folds the line light's blocks away instead of carrying them for every full-screen light.
vec3 lit_shade(int i LIT_LINE_PARAMS, vec3 albedo, vec3 N, vec3 spec_shin, float shininess,
		float metallic, float roughness,
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag, float frag_d,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS) {
	// Texel 0 carries the cheap fields (z code | flags | mask + z code high bits |
	// falloff) so masked-out and z-rejected lights bail after a single fetch, before
	// any position/color/shadow texels.
	vec4 t0 = texelFetch(lit_light_data, ivec2(0, i), 0);

	// flags bit 0 = shadow_enabled, bit 1 = subtractive, bits 20-21 = type (0 = point,
	// 1 = directional, 2 = spot, 3 = line).
	int flags = int(round(t0.y));
	int type = (flags >> 20) & 3;
	bool is_directional = type == 1;
	bool is_spot = type == 2;
#ifdef LIT_LINE
	bool is_line = positional && type == 3;
#endif
	bool shadow_enabled = (flags & 1) != 0;
	bool subtractive = (flags & 2) != 0;
	float falloff = t0.w;

	// Skip lights this receiver's mask doesn't share a bit with, and ranged lights
	// (flags bit 19 z, bit 22 layer) whose range misses it, before paying for any of the
	// work below. The mask is the low 20 bits of t0.z. One exit for both: extra early
	// returns here cost every light on every pixel, ranged or not.
	int t0z = int(round(t0.z));
	int light_mask = t0z & 1048575;
	bool reject = (light_mask & receiver_mask) == 0;
	if ((flags & 4718592) != 0) {
		// z range in texel 0: z_min + 4096 in the low 14 bits of t0.x, z_max + 4096 split
		// between the bits above and t0.z bits 20-23, so it rejects without another fetch.
		if ((flags & 524288) != 0) {
			int zc = int(round(t0.x));
			int z_min = zc & 16383;
			int z_max = (zc >> 14) | ((t0z >> 20) << 10);
			int rz = receiver_z + 4096;
			reject = reject || rz < z_min || rz > z_max;
		}
		if ((flags & 4194304) != 0) {
			vec4 t9 = texelFetch(lit_light_data, ivec2(9, i), 0); // z_min | z_max | layer_min | layer_max
			float rl = float(receiver_layer);
			reject = reject || rl < t9.z || rl > t9.w;
		}
	}
	if (reject) {
		return vec3(0.0);
	}

#ifdef LIT_LINE
	// A curved line light's Q, the nearest point of its arc chain, found in the line block;
	// the shadow block marches from it, the cookie keeps the node's position.
	vec2 q_px = vec2(0.0);
	int path_row = -1;                       // a curved line light's path texture row
	vec4 line_t4 = vec4(0.0);                // a line light's texel 4
	vec3 line_tube = vec3(0.0);              // its tube: height px | half width px | 1 when its chain is open
	float line_irr = -1.0;                   // its diffuse term, in place of N.L x atten
#endif

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
#ifdef LIT_LINE
		float half_w = 0.0;
		if (is_line) {
			// A line light's body is the distance field of its segment (texel 4 holds the
			// half-vector from the node to one end, the glow and the half width, see
			// _pack_line) or of its arc chain (Q): `beam` is this pixel's coverage by the
			// tube (a 1 px box filter on its edge, 0 everywhere at zero width), the range
			// runs from the tube's surface, and outside the tube the glow is t4.z of the
			// beam's brightness. The light itself is integrated along the tube below. The
			// cookie stays on the node.
			line_t4 = texelFetch(lit_light_data, ivec2(4, i), 0); // half.xy | glow | half width
			vec2 p = frag_uv * lit_viewport_size;
			vec4 circle = vec4(0.0);                 // a curved line's path texel 0: center.xy | radius | shading chord count
			if ((flags & 8388608) != 0) {
				path_row = int(round(line_t4.x));
				// Path texel 0's circle encloses every arc: a pixel farther from it than the
				// range fails the range exit below without Q.
				circle = texelFetch(lit_light_path, ivec2(0, path_row), 0);
				if (length(p - circle.xy) - circle.z > range_px + 1.0) {
					return vec3(0.0);
				}
				q_px = lit_path_nearest(path_row, int(round(line_t4.y)), p).xy;
				to_light_px = q_px - p;
			} else {
				float u = clamp(-dot(to_light_px, line_t4.xy) / max(dot(line_t4.xy, line_t4.xy), 1e-6), -1.0, 1.0);
				to_light_px += line_t4.xy * u;
			}
			dist = length(to_light_px);
			half_w = line_t4.w * lit_canvas_scale;
			float beam = clamp(min(dist + 0.5, half_w) - max(dist - 0.5, -half_w), 0.0, 1.0);
			float surf = max(dist - half_w, 0.0);
			to_light_px *= surf / max(dist, 1e-4);
			range_px -= half_w;
			dist = surf;
			energy *= mix(line_t4.z, 1.0, beam);
			line_tube = vec3(height_px, half_w, 1.0);
			if (dist > range_px) {
				return vec3(0.0);                // beyond range
			}
			Ldir = normalize(vec3(to_light_px, height_px));
			atten = pow(clamp(1.0 - dist / range_px, 0.0, 1.0), falloff);
			// The tube as a line source: its mean cosine at the pixel is the sum of its
			// chords' line integrals of max(N.u, 0) / |u|^2 (lit_line_chord) over the angle
			// 2 atan(L / 2D) an endless straight tube subtends at the nearest point. Beside a
			// straight tube's middle, and at length 0, that is exactly N.L toward the tube's
			// surface: a line light reads as the point light does at the same distance, and
			// range and falloff keep their meaning; inside a bend the tube wraps around the
			// pixel and the cosine rises, past an end it tapers. A straight light is its one
			// chord, a curved one loops its path row's shading chords. The light direction
			// is the shares' mean direction; the specular amplitude keeps its ratio to N.L.
			// Under a wide tube and out to a half width past its surface the light is lifted
			// to the nearest point's where the tube's mean falls short of it (the body is lit
			// from overhead, its caps as its sides), never lowered, so where two parts of the
			// tube face each other their light still adds up.
			vec3 acc_l = vec3(0.0);
			float cosine = 0.0;
			float len;
			if (path_row >= 0) {
				int count = int(round(circle.w));
				vec4 info = texelFetch(lit_light_path, ivec2(LIT_PATH_INFO, path_row), 0); // z 1 when closed | w length px
				len = info.w;
				line_tube.z = info.z < 0.5 ? 1.0 : 0.0;
				// LOD: the coarse chords (pairs merged) past LIT_PATH_LOD_K bounding radii.
				int chord0 = LIT_PATH_CHORDS;
				vec2 dc = p - circle.xy;
				if (count > LIT_PATH_SHADE / 2 && dot(dc, dc) > LIT_PATH_LOD_K * LIT_PATH_LOD_K * circle.z * circle.z) {
					chord0 = LIT_PATH_COARSE;
					count = (count + 1) / 2;
				}
				for (int k = 0; k < count; k++) {
					vec2 free = vec2(k == 0 ? line_tube.z : 0.0, k == count - 1 ? line_tube.z : 0.0);
					cosine += lit_line_chord(texelFetch(lit_light_path, ivec2(chord0 + k, path_row), 0), p, N, height_px, half_w, free, acc_l);
				}
			} else {
				len = 2.0 * length(line_t4.xy);
				cosine = lit_line_chord(vec4(light_uv * lit_viewport_size, line_t4.xy), p, N, height_px, half_w, vec2(1.0), acc_l);
			}
			if (len > 1e-3) {
				cosine /= 2.0 * atan(len, 2.0 * sqrt(dist * dist + height_px * height_px));
				float body = half_w > 0.0 ? 1.0 - smoothstep(0.0, half_w, dist) : 0.0;
				cosine += body * max(max(dot(N, Ldir), 0.0) - cosine, 0.0);
				if (dot(acc_l, acc_l) > 1e-12) {
					Ldir = normalize(mix(normalize(acc_l), Ldir, body));
				}
			} else {
				cosine = max(dot(N, Ldir), 0.0);
			}
			line_irr = atten * cosine;
			atten = line_irr / max(dot(N, Ldir), 0.1);
		} else {
#endif
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
#ifdef LIT_LINE
		}
#endif
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
#ifdef LIT_LINE
	float irr = is_line ? line_irr : ndotl * atten;
#else
	float irr = ndotl * atten;
#endif

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

		contribution = (diffuse + spec) * light_color * energy * irr;
	} else {
		vec3 diffuse = albedo * light_color * energy * irr;

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
		// Per-light exclusions (flags bit 5): t11 = union bounds of the exempt rects.
		bool mk_on = (flags & 32) != 0;
		int mk_row = i;
		vec4 mk_rect = mk_on ? texelFetch(lit_light_data, ivec2(11, i), 0) : vec4(0.0);
#endif
#ifdef LIT_OCC_RX
		// The light's shadow mask (t7.w), for the effective-layer rx ignore test.
		int rx_smask = int(round(texelFetch(lit_light_data, ivec2(7, i), 0).w));
#endif
		// SDF units per screen pixel, to convert world-px shadow fields.
		float px_to_sdf = sdf_diag / length(lit_viewport_size);

		vec2 march_dir;
		float march_len;
#ifdef LIT_LINE
		vec2 line_seg = vec2(0.0);               // a line light's strata half-vector (SDF units)
		float line_frac = 1.0;                   // the window's share of the tube
#endif
		if (is_directional) {
			// March a fixed direction across the SDF. screen_uv_to_sdf is affine, so
			// the SDF-space direction comes from offsetting the fragment UV along the
			// toward-light dir. t1.z is the light's shadow_reach in world px, so the
			// march length is zoom-invariant - never a screen-derived distance.
			march_dir = normalize(screen_uv_to_sdf(frag_uv + shadow_dir_uv) - frag_sdf);
			march_len = t1.z * lit_canvas_scale * px_to_sdf;
#ifdef LIT_LINE
		} else if (is_line) {
			// A line light marches toward Q (its nearest point) when raymarched, and as
			// an area source toward the middle of the part of its segment within range of
			// the fragment, the source its strata tile. Its own branch, so point and spot
			// keep the branch below unchanged.
			vec2 target_uv = light_uv;
			if ((flags & 8388608) != 0) {
				target_uv = q_px / lit_viewport_size;
			} else {
				vec4 t4 = texelFetch(lit_light_data, ivec2(4, i), 0); // half.xy | glow | half width
				vec2 d = (light_uv - frag_uv) * lit_viewport_size;
				target_uv = light_uv + t4.xy * clamp(-dot(d, t4.xy) / max(dot(t4.xy, t4.xy), 1e-6), -1.0, 1.0)
						/ lit_viewport_size;
				if ((flags & 24) != 0) {
					vec4 win = lit_line_window(t4, light_uv, frag_uv, range);
					target_uv = win.xy;
					line_seg = win.zw * px_to_sdf;
					line_frac = sqrt(dot(win.zw, win.zw) / max(dot(t4.xy, t4.xy), 1e-6));
				}
			}
			vec2 delta = screen_uv_to_sdf(target_uv) - frag_sdf;
			march_len = length(delta);
			march_dir = delta / max(march_len, 0.0001);
#endif
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
			// Cone Traced runs here as the stochastic gate alone (0 samples).
#ifdef LIT_LINE
			if ((flags & 24) == 16 || (is_line && (flags & 24) != 0)) {
#else
			if (algo != 0) {
#endif
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
#ifdef LIT_LINE
				// Point/spot: t7.x is the source disc's radius in world px. Directional:
				// t7.x is tan(source half-angle), used as an angular extent directly.
				// Line: the radius plus its strata source's apparent half-width across
				// the march, for the gate; line_seg spreads the strata.
				float src_r = is_directional ? t7.x : t7.x * lit_canvas_scale * px_to_sdf;
				float src = src_r;
				// One cone cannot stand for a tube (its wide cross section reads occluders
				// beside the tube from every direction), so a line light marches its
				// strata as Stochastic does, without the dither, unless its window is
				// under a pixel long: that is a point, and the point's single cone is
				// exact there.
				bool stoch = algo == 2;
				bool strata = stoch || is_line;
				int n = max(int(round(t7.y)), 1);
				src += abs(line_seg.x * march_dir.y - line_seg.y * march_dir.x);
				strata = stoch || dot(line_seg, line_seg) > px_to_sdf * px_to_sdf;
				// Samples are per tube: a window that is part of the tube marches
				// that part's share of them, so no pixel's strata are wider than the
				// tube's middle gets, and none narrower.
				n = clamp(int(ceil(float(n) * line_frac)), 1, n);
				if (path_row >= 0) {
					// Curved line: every chord stratum, weighted as the shading weights them.
					s = lit_shadow_path(frag_sdf, path_row, n, N, line_tube, t_cap / max(march_len, 1e-4), t_cap < march_len,
							src_r, stoch ? t7.z : 0.0, frag_uv * lit_viewport_size, steps, frag_d,
							self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
				} else {
					s = lit_shadow_stoch(frag_sdf, frag_sdf + march_dir * march_len, march_dir,
							march_len, t_cap, strata ? t_cap < march_len : capped, src, is_directional,
							strata ? n : 0, stoch ? t7.z : 0.0,
							frag_uv * lit_viewport_size, steps, frag_d LIT_SEG_ARGS,
							self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
				}
#else
				// Point/spot: t7.x is the source disc's radius in world px. Directional:
				// t7.x is tan(source half-angle), used as an angular extent directly.
				float src = is_directional ? t7.x : t7.x * lit_canvas_scale * px_to_sdf;
				// A stochastic light always marches at least one stratum.
				bool stoch = algo == 2;
				s = lit_shadow_stoch(frag_sdf, frag_sdf + march_dir * march_len, march_dir,
						march_len, t_cap, stoch ? t_cap < march_len : capped, src, is_directional,
						stoch ? max(int(round(t7.y)), 1) : 0, t7.z,
						frag_uv * lit_viewport_size, steps, frag_d,
						self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
#endif
				s = lit_shadow_contrast(s, t3.w);
#ifdef LIT_LINE
			} else if ((flags & 24) == 8) {
				// A cone-traced point, spot or directional beside the lines: the gate alone.
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
				float src = is_directional ? t7.x : t7.x * lit_canvas_scale * px_to_sdf;
				s = lit_shadow_stoch(frag_sdf, frag_sdf + march_dir * march_len, march_dir,
						march_len, t_cap, capped, src, is_directional, 0, 0.0,
						frag_uv * lit_viewport_size, steps, frag_d, vec2(0.0), src,
						self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
				s = lit_shadow_contrast(s, t3.w);
#endif
			} else
#elif defined(LIT_SHADOW_CONE)
			if (algo == 1) {
				vec4 t7 = texelFetch(lit_light_data, ivec2(7, i), 0); // source | samples | jitter
				// Cone half-angle tangent: source size over source distance (directional
				// packs the tangent directly).
				float w = max(is_directional ? t7.x
						: t7.x * lit_canvas_scale * px_to_sdf / max(march_len, 1e-4), 1e-4);
				s = lit_shadow_cone(frag_sdf, march_dir, t_cap,
						capped ? w * t_cap : 0.0, w, steps,
						frag_d, !is_directional && !capped, self_ex, self_canvas, sdf_to_canvas,
						self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
				s = lit_shadow_contrast(s, t3.w);
			} else
#endif
			{
				float k = mix(8.0, 256.0, t3.w);
#ifdef LIT_LINE
				s = path_row >= 0
						? lit_shadow_path_hard(frag_sdf, path_row, int(round(texelFetch(lit_light_data, ivec2(7, i), 0).y)),
								N, line_tube, t_cap / max(march_len, 1e-4), capped, k, frag_uv * lit_viewport_size, steps, frag_d,
								self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS)
						: lit_shadow(frag_sdf, march_dir, t_cap, capped ? t_cap / k : 0.0,
								k, steps, frag_d, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
#else
				s = lit_shadow(frag_sdf, march_dir, t_cap, capped ? t_cap / k : 0.0,
						k, steps, frag_d, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
#endif
			}
#else
			// Low hardness is soft, high is crisp.
			float k = mix(8.0, 256.0, t3.w);
			s = lit_shadow(frag_sdf, march_dir, t_cap, capped ? t_cap / k : 0.0,
					k, steps, frag_d, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
#endif
		}
		contribution *= mix(t3.rgb, vec3(1.0), s);
	}

	// Subtract mode is negative light: it carves darkness below ambient, and the
	// final COLOR clamps at display.
	return subtractive ? -contribution : contribution;
}

