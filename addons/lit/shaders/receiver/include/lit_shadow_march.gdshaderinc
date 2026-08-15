// Unit: raymarched shadow (base axis): lit_shadow(), lit_shadow_contrast(), lit_tip_weight().

// Tip closure for length-limited shadows (shadow_length): weight for a darkening sample
// at march distance t. 1 below the tip band, easing to 0 at t_tip, so every occluder's
// umbra closes exactly at the cap through a penumbra-width tip instead of a hard cut.
// band <= 0 means the march is uncapped and every sample keeps full weight.
float lit_tip_weight(float t, float t_tip, float band) {
	return band > 0.0 ? clamp((t_tip - t) / band, 0.0, 1.0) : 1.0;
}

// Soft-shadow march of Godot's screen-space SDF (the IQ technique), run on |sdf| -
// the distance field of occluder outlines - so a shape casts from its light-facing
// silhouette and the shadow passes through its body. A fragment starting inside a
// shape takes that shape's shadow via the footprint_shadow ramp instead of a hard hit.
// Returns 1 fully lit, 0 occluded. The caller passes the unit march direction and
// length (dir, maxd, SDF space) and frag_d, its own texture_sdf sample, shared by
// every light's march. maxd may be capped short of the light (shadow_length); norm_d
// is the true fragment-to-light distance normalizing the footprint_shadow ramp, and
// tip_band is the tip-closure band width (0 = uncapped; see lit_tip_weight).
// k shapes the penumbra estimate k*d/t: the Raymarched algorithm
// derives it from shadow_hardness, the Cone Traced algorithm from the source's angular
// size (k = 1/tan(half-angle)) - same march, different cone width. When self_ex is
// true, samples whose nearest outline may belong to the receiver's own occluders are
// stepped through instead of occluding; self_canvas and sdf_to_canvas map SDF-space
// march offsets into canvas space, and self_scale is the canvas length of one SDF unit.
float lit_shadow(vec2 frag_sdf, vec2 dir, float maxd, float norm_d, float tip_band, float k,
		int max_steps, float frag_d,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	float t_tip = maxd;                      // tip anchor: the cap, before coverage clamps it
	maxd = min(maxd, lit_sdf_cov_exit(frag_sdf, dir));
	float t = shadow_min_step;
	float res = 1.0;
	float prev_d = frag_d;                   // signed; tracks outline crossings
	// A fragment starting inside a shape marches out of it without treating its own
	// outline as hits; the shape's shadow is applied once, at the exit.
	bool grace = prev_d < 0.0;
	int s = 0;
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);      // keep the compile-time cap
	float t_ex_end = 0.0;                                  // reach of the exclusion-aware phases

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
		t_ex_end = t_mk_end;
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
					float own_block = clamp(footprint_shadow * t / norm_d, 0.0, 1.0) * yw
							* lit_tip_weight(t, t_tip, tip_band);
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
					float cw = yw * lit_tip_weight(t, t_tip, tip_band);
					if (hit) {
						if (cw >= 1.0) {
							return 0.0;
						}
						res = min(res, 1.0 - cw);
						if (res <= 0.0) {
							return 0.0;
						}
						t += max(-d, shadow_min_step);
						continue;
					}
					res = min(res, mix(1.0, cand, cw));
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
		t_ex_end = max(t_ex_end, t_slow_end);
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
					float own_block = clamp(footprint_shadow * t / norm_d, 0.0, 1.0) * yw
							* lit_tip_weight(t, t_tip, tip_band);
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
					float cw = yw * lit_tip_weight(t, t_tip, tip_band);
					if (hit) {
						if (cw >= 1.0) {
							return 0.0;          // fully occluded
						}
						// Faded caster: darken by its weight, then step through it.
						res = min(res, 1.0 - cw);
						if (res <= 0.0) {
							return 0.0;
						}
						t += max(-d, shadow_min_step);
						continue;
					}
					res = min(res, mix(1.0, cand, cw));  // penumbra accumulation
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
	// Length-limited marches stop the hard-hit loops at the tip band; a weighted sweep
	// finishes the band so the umbra closes at t_tip instead of cutting.
	{
		float t_fast_end = tip_band > 0.0 ? min(maxd, max(t_tip - tip_band, 0.0)) : maxd;
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
				float own_block = clamp(footprint_shadow * t / norm_d, 0.0, 1.0)
						* lit_tip_weight(t, t_tip, tip_band);
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
				for (; s < max_steps && t < t_fast_end; s++) {
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
		for (; s < max_steps && t < t_fast_end; s++) {
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
		// Sphere tracing has no step bound on a near-tangent ray: it crawls one clearance
		// per step alongside an edge and can spend the whole budget short of the light,
		// leaving a caster beyond it unseen and the fragment reported lit. Finish such a
		// march with a bounded sweep whose floor forces the rest of the ray into the steps
		// that remain. It runs the plain tests, so it starts past the exclusion phases'
		// reach, where an exempt caster can no longer be mistaken for a real one.
		t = max(t, t_ex_end);
		if (t < t_fast_end) {
			int tail = max(max_steps >> 2, 4);
			for (int e = 0; e < tail && t < t_fast_end; e++) {
				float d = lit_sdf_sample(frag_sdf + dir * t);
				if (d < 0.001) {
					return 0.0;
				}
				if (d * best_t < best_d * t) {
					best_d = d;
					best_t = t;
				}
				t += max(d, (t_fast_end - t) / float(tail - e));
			}
		}
		// Tip band: every hit and penumbra sample fades by the tip weight, so the
		// shadow closes at t_tip. Same forced-floor sweep as the tail, since sphere
		// tracing has no step bound here either.
		if (tip_band > 0.0 && t < maxd) {
			t = max(t, t_ex_end);
			int bsteps = max(max_steps >> 2, 4);
			for (int e = 0; e < bsteps && t < maxd; e++) {
				float d = lit_sdf_sample(frag_sdf + dir * t);
				float tw = lit_tip_weight(t, t_tip, tip_band);
				if (d < 0.001) {
					res = min(res, 1.0 - tw);
					if (res <= 0.0) {
						return 0.0;
					}
				} else {
					res = min(res, mix(1.0, k * d / t, tw));
				}
				t += max(abs(d), (maxd - t) / float(bsteps - e));
			}
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

