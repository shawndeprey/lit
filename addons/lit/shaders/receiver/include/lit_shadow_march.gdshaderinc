// Unit: raymarched shadow (base axis): lit_shadow(), lit_shadow_contrast().

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
// stepped through instead of occluding; self_canvas and sdf_to_canvas map SDF-space
// march offsets into canvas space, and self_scale is the canvas length of one SDF unit.
float lit_shadow(vec2 frag_sdf, vec2 dir, float maxd, float k, int max_steps, float frag_d,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	maxd = min(maxd, lit_sdf_cov_exit(frag_sdf, dir));
	float t = shadow_min_step;
	float res = 1.0;
	float prev_d = frag_d;                   // signed; tracks outline crossings
	// A fragment starting inside a shape marches out of it without treating its own
	// outline as hits; the shape's shadow is applied once, at the exit.
	bool grace = prev_d < 0.0;
	int s = 0;
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);      // keep the compile-time cap

#ifdef LIT_OCC_MASKS
	// Mask pre-pass: exempt casters can only matter within this march's crossing of the
	// exempt bounds, so the exclusion tests live in this loop alone and the untouched
	// phases below run at full speed. Keep the body aligned with the slow phase below;
	// the alignment contract is gated behaviorally by Test/march_matrix.md.
	if (mk_on) {
		vec2 dir_canvas = sdf_to_canvas * dir;
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
		vec2 dir_px = sdf_to_px * dir;
#endif
		float pad = (max(maxd / k, shadow_min_step) + LIT_SELF_PAD_SDF) * self_scale;
		float t_mk_end = lit_rect_segment_exit(self_canvas, dir_canvas * maxd, mk_rect, pad) * maxd;
		bool receding = false;
		float prev_ad = 0.0;
		for (; s < max_steps && t < maxd && t <= t_mk_end; s++) {
			float d = lit_sdf_sample(frag_sdf + dir * t);
			float ad = abs(d);
			if (grace) {
				prev_d = d;
				if (d < 0.0) {
					t += max(-d, shadow_min_step);
					continue;
				}
				grace = false;
				receding = true;
				prev_ad = ad;
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) > own_r * own_r
						&& !lit_mk_exempt(mk_row, self_canvas + dir_canvas * t, own_r)
						&& !LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					float yw = 1.0;
#ifdef LIT_YSORT
					yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
							frag_px + dir_px * t, own_r) : 1.0;
#endif
					float own_block = clamp(footprint_shadow * t / maxd, 0.0, 1.0) * yw;
					res = min(res, 1.0 - own_block);
					if (res <= 0.0) {
						return 0.0;
					}
				}
				t += max(ad, shadow_min_step);
				continue;
			}
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
			if (hit || cand < res) {
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) <= own_r * own_r
						|| lit_mk_exempt(mk_row, self_canvas + dir_canvas * t, own_r)
						|| LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					if (hit) {
						t += max(-d, shadow_min_step);
						continue;
					}
				} else {
					float yw = 1.0;
#ifdef LIT_YSORT
					yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
							frag_px + dir_px * t, own_r) : 1.0;
#endif
					if (hit) {
						if (yw >= 1.0) {
							return 0.0;
						}
						res = min(res, 1.0 - yw);
						if (res <= 0.0) {
							return 0.0;
						}
						t += max(-d, shadow_min_step);
						continue;
					}
					res = min(res, mix(1.0, cand, yw));
				}
			}
			t += max(ad, shadow_min_step);
		}
	}
#endif

	// Own outlines only matter within penumbra reach; past the segment exit the fast
	// phases finish the march. Y-sort and rx cover the whole march instead.
	if (self_ex || LIT_YS_ON) {
		vec2 dir_canvas = sdf_to_canvas * dir;
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
		vec2 dir_px = sdf_to_px * dir;
#endif
		float pad = (max(maxd / k, shadow_min_step) + LIT_SELF_PAD_SDF) * self_scale;
		float t_self_end = self_ex
				? lit_self_segment_exit(self_canvas, dir_canvas * maxd, pad) * maxd : 0.0;
		float t_slow_end = LIT_YS_ON ? maxd : t_self_end;
#ifdef LIT_OCC_RX
		for (int bi = 0; bi < rx_bound_count; bi++) {
			t_slow_end = max(t_slow_end,
					lit_rect_segment_exit(self_canvas, dir_canvas * maxd, rx_bounds[bi], pad) * maxd);
		}
#endif
		// Mutes penumbra accumulation while the ray still recedes from the exited edge.
		bool receding = false;
		float prev_ad = 0.0;
		// Dynamic loop bounds on purpose: a constant bound invites unrolling this
		// body, which taxes the whole shader even on fragments that never take it.
		for (; s < max_steps && t < maxd && t <= t_slow_end; s++) {
			float d = lit_sdf_sample(frag_sdf + dir * t); // signed: negative inside a shape
			float ad = abs(d);                         // distance to the nearest outline
			if (grace) {
				prev_d = d;
				if (d < 0.0) {
					t += max(-d, shadow_min_step);     // -d is the distance to the far edge
					continue;
				}
				// First exit from the containing shape: apply its shadow, ramped by
				// depth crossed over light distance, unless it is an owned occluder.
				grace = false;
				receding = true;
				prev_ad = ad;
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) > own_r * own_r
						&& !LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					float yw = 1.0;
#ifdef LIT_YSORT
					yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
							frag_px + dir_px * t, own_r) : 1.0;
#endif
					float own_block = clamp(footprint_shadow * t / maxd, 0.0, 1.0) * yw;
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
			// The nearest outline may be the receiver's own whenever the self bounds
			// lie within |d| of the sample.
			if (hit || cand < res) {
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) <= own_r * own_r
						|| LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					if (hit) {
						// Crossing an owned occluder: inside it, -d is the distance
						// to the far edge.
						t += max(-d, shadow_min_step);
						continue;
					}
				} else {
					float yw = 1.0;
#ifdef LIT_YSORT
					yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
							frag_px + dir_px * t, own_r) : 1.0;
#endif
					if (hit) {
						if (yw >= 1.0) {
							return 0.0;          // fully occluded
						}
						// Faded caster: darken by its weight, then step through it.
						res = min(res, 1.0 - yw);
						if (res <= 0.0) {
							return 0.0;
						}
						t += max(-d, shadow_min_step);
						continue;
					}
					res = min(res, mix(1.0, cand, yw));  // penumbra accumulation
				}
			}
			t += max(ad, shadow_min_step);
		}
	}

	// Fast phases: grace, receding, steady - each runs at most once, in order, so run
	// each as its own minimal loop sharing the step budget: identical samples, none of
	// the per-step phase bookkeeping. Past the grace exit every sample is non-negative,
	// so the full hit test (|d| < 0.001 || sign flip) collapses to d < 0.001 and
	// prev_d/abs() drop out. Also the self-excluding tail: no self tests needed here.
	{
		if (grace) {
			// Grace: march out of the containing shape without treating its outline as
			// hits; apply its footprint shadow once, at the exit sample.
			bool receding = false;
			float prev_ad = 0.0;
			for (; s < max_steps && t < maxd; s++) {
				float d = lit_sdf_sample(frag_sdf + dir * t); // signed: negative inside a shape
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
					float d = lit_sdf_sample(frag_sdf + dir * t);
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
			float d = lit_sdf_sample(frag_sdf + dir * t);
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

