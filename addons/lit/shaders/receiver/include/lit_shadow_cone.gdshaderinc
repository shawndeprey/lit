// Unit: cone-traced shadow (LIT_SHADOW_CONE; also compiled for LIT_SHADOW_STOCH): lit_shadow_cone().

#if defined(LIT_SHADOW_CONE) || defined(LIT_SHADOW_STOCH)
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
// the receiver's own occluders never darken (self-exclusion). Compiled for the
// stochastic variants too: lit_shadow_stoch runs it as its penumbra gate.
//
// src_plane (point/spot only - a directional march's far end is sky, not a source):
// take one final clamped sample AT t = maxd, the source plane, where the cone is
// widest. Sphere-trace steps are sized by off-ray distances, so when an occluder sits
// near or overlapping the emitting disc, the march routinely exits without a sample in
// the last step-length before the source - and whether a given fragment's step cascade
// happens to land one there or hop it flips the whole overlap-dimming term on and off,
// painting hard sawtooth wedges across the scene. Pinning the source-plane sample makes
// that term smooth and fragment-independent; far-field lights (source clear of
// occluders) get coverage >= 1 from it, leaving their result untouched.
// maxd may be capped short of the source (shadow_length); norm_d is the true
// fragment-to-source distance normalizing the footprint_shadow ramp, and tip_band is
// the tip-closure band width (0 = uncapped; see lit_tip_weight). Capped callers pass
// src_plane false: occluders at the source sit beyond the cap and cast nothing.
float lit_shadow_cone(vec2 frag_sdf, vec2 dir, float maxd, float norm_d, float tip_band, float w,
		int max_steps, float frag_d,
		bool src_plane, bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas,
		float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	float t_tip = maxd;                      // tip anchor: the cap, before coverage clamps it
	// An off-coverage source plane has no SDF information to sample.
	float t_cov = lit_sdf_cov_exit(frag_sdf, dir);
	src_plane = src_plane && maxd <= t_cov;
	maxd = min(maxd, t_cov);
	float t = shadow_min_step;
	float res = 1.0;
	bool grace = frag_d < 0.0;
	int s = 0;
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
	float t_self_end = 0.0;
	float t_ex_end = 0.0;                                  // reach of the exclusion-aware phases
#ifdef LIT_OCC_MASKS
	float t_mk_end = 0.0;

	// Mask pre-pass: exempt casters can only matter within this march's crossing of the
	// exempt bounds, so the exclusion tests live in this loop alone and the untouched
	// phases below run at full speed. Keep the body aligned with the slow phase below;
	// the alignment contract is gated behaviorally by Test/march_matrix.md.
	if (mk_on) {
		vec2 dir_canvas = sdf_to_canvas * dir;
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
		vec2 dir_px = sdf_to_px * dir;
#endif
		float pad = (max(w * maxd, shadow_min_step) + LIT_SELF_PAD_SDF) * self_scale;
		t_mk_end = lit_rect_segment_exit(self_canvas, dir_canvas * maxd, mk_rect, pad) * maxd;
		t_ex_end = t_mk_end;
		bool receding = false;
		float prev_d = frag_d;
		for (; s < max_steps && t < maxd && t <= t_mk_end; s++) {
			float d = lit_sdf_sample(frag_sdf + dir * t);
			float ad = abs(d);
			if (grace) {
				if (d < 0.0) {
					t += max(-d, shadow_min_step);
					continue;
				}
				grace = false;
				receding = true;
				prev_d = d;
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) > own_r * own_r
						&& !lit_mk_exempt(mk_row, self_canvas + dir_canvas * t, own_r)
						&& !LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					float yw = 1.0;
#ifdef LIT_YSORT
					yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
							frag_px + dir_px * t, own_r) : 1.0;
#endif
					res = 1.0 - clamp(footprint_shadow * t / norm_d, 0.0, 1.0) * yw
						* lit_tip_weight(t, t_tip, tip_band);
					if (res <= 0.0) {
						return 0.0;
					}
				}
				t += max(ad, shadow_min_step);
				continue;
			}
			if (receding) {
				if (d >= prev_d) {
					prev_d = d;
					t += max(ad, shadow_min_step);
					continue;
				}
				receding = false;
			}
			float cand = 0.5 + d / (2.0 * w * t);
			if (cand < res) {
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) <= own_r * own_r
						|| lit_mk_exempt(mk_row, self_canvas + dir_canvas * t, own_r)
						|| LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					t += max(ad, shadow_min_step);
					continue;
				}
				float yw = 1.0;
#ifdef LIT_YSORT
				yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
						frag_px + dir_px * t, own_r) : 1.0;
#endif
				float faded = mix(1.0, max(cand, 0.0), yw * lit_tip_weight(t, t_tip, tip_band));
				if (faded < res) {
					res = faded;
					if (res <= 0.0) {
						return 0.0;
					}
				}
			}
			t += max(ad, shadow_min_step);
		}
	}
#endif

	// Own outlines only matter within the cone's widest reach; past the segment exit
	// the fast phases finish the march. Y-sort and rx cover the whole march instead.
	if (self_ex || LIT_YS_ON) {
		vec2 dir_canvas = sdf_to_canvas * dir;
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
		vec2 dir_px = sdf_to_px * dir;
#endif
		float pad = (max(w * maxd, shadow_min_step) + LIT_SELF_PAD_SDF) * self_scale;
		if (self_ex) {
			t_self_end = lit_self_segment_exit(self_canvas, dir_canvas * maxd, pad) * maxd;
		}
		float t_slow_end = LIT_YS_ON ? maxd : t_self_end;
#ifdef LIT_OCC_RX
		for (int bi = 0; bi < rx_bound_count; bi++) {
			t_slow_end = max(t_slow_end,
					lit_rect_segment_exit(self_canvas, dir_canvas * maxd, rx_bounds[bi], pad) * maxd);
		}
#endif
		t_ex_end = max(t_ex_end, t_slow_end);
		bool receding = false;
		float prev_d = frag_d;
		// Dynamic loop bounds on purpose: a constant bound invites unrolling this
		// body, which taxes the whole shader even on fragments that never take it.
		for (; s < max_steps && t < maxd && t <= t_slow_end; s++) {
			float d = lit_sdf_sample(frag_sdf + dir * t);
			float ad = abs(d);
			if (grace) {
				// March out of the containing shape; apply its footprint shadow once,
				// at the exit sample, unless the shape is an owned occluder.
				if (d < 0.0) {
					t += max(-d, shadow_min_step);
					continue;
				}
				grace = false;
				receding = true;
				prev_d = d;
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) > own_r * own_r
						&& !LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					float yw = 1.0;
#ifdef LIT_YSORT
					yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
							frag_px + dir_px * t, own_r) : 1.0;
#endif
					res = 1.0 - clamp(footprint_shadow * t / norm_d, 0.0, 1.0) * yw
						* lit_tip_weight(t, t_tip, tip_band);
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
			// Half-plane coverage of the cone's cross-section (half-width w*t at
			// distance t): an edge at signed distance d from the cone's center leaves
			// the fraction 0.5 + d/(2*w*t) unblocked, hitting 0 only when the edge is
			// a full half-width past center - which is what lets the umbra close
			// behind small occluders.
			float cand = 0.5 + d / (2.0 * w * t);
			if (cand < res) {
				float own_r = (ad + LIT_SELF_PAD_SDF) * self_scale;
				if (lit_self_dist2(self_canvas + dir_canvas * t) <= own_r * own_r
						|| LIT_RX_EXEMPT(self_canvas + dir_canvas * t, frag_px + dir_px * t, own_r)) {
					t += max(ad, shadow_min_step);   // owned occluder: contributes nothing
					continue;
				}
				float yw = 1.0;
#ifdef LIT_YSORT
				yw = ys_on ? lit_ysort_weight(self_canvas + dir_canvas * t,
						frag_px + dir_px * t, own_r) : 1.0;
#endif
				float faded = mix(1.0, max(cand, 0.0), yw * lit_tip_weight(t, t_tip, tip_band));
				if (faded < res) {
					res = faded;
					if (res <= 0.0) {
						return 0.0;                  // cone fully blocked; can't recover
					}
				}
			}
			t += max(ad, shadow_min_step);
		}
	}

	// Fast phases: the same split as lit_shadow - grace, receding and steady each run
	// at most once, in order, so run each as its own minimal loop sharing the step
	// budget. Identical samples and coverage updates, none of the per-step phase
	// bookkeeping. Also the self-excluding tail: no self tests needed here.
	{
		if (grace) {
			// Grace: march out of the containing shape without coverage updates;
			// apply its footprint shadow once, at the exit sample.
			bool receding = false;
			float prev_d = 0.0;
			for (; s < max_steps && t < maxd; s++) {
				float d = lit_sdf_sample(frag_sdf + dir * t);
				if (d < 0.0) {
					t += max(-d, shadow_min_step);
					continue;
				}
				res = 1.0 - clamp(footprint_shadow * t / norm_d, 0.0, 1.0)
						* lit_tip_weight(t, t_tip, tip_band);
				if (res <= 0.0) {
					return 0.0;
				}
				prev_d = d;
				t += max(d, shadow_min_step);
				s++;                                   // this sample consumed a step
				receding = true;
				break;
			}
			// Receding: mute coverage while still receding from the exited edge, or
			// the receiver's own surface would count as half-blocking the cone. The
			// breaking sample follows the steady-state rule.
			if (receding) {
				for (; s < max_steps && t < maxd; s++) {
					float d = lit_sdf_sample(frag_sdf + dir * t);
					if (d >= prev_d) {
						prev_d = d;
						t += max(abs(d), shadow_min_step);
						continue;
					}
					float cand = 0.5 + d / (2.0 * w * t);
					if (cand < res) {
						float wc = mix(1.0, max(cand, 0.0), lit_tip_weight(t, t_tip, tip_band));
						if (wc < res) {
							res = wc;
							if (res <= 0.0) {
								return 0.0;
							}
						}
					}
					t += max(abs(d), shadow_min_step);
					s++;                               // this sample consumed a step
					break;
				}
			}
		}
		// Steady state: bare signed-coverage march.
		for (; s < max_steps && t < maxd; s++) {
			float d = lit_sdf_sample(frag_sdf + dir * t);
			float cand = 0.5 + d / (2.0 * w * t);
			if (cand < res) {
				float wc = mix(1.0, max(cand, 0.0), lit_tip_weight(t, t_tip, tip_band));
				if (wc < res) {
					res = wc;
					if (res <= 0.0) {
						return 0.0;                  // cone fully blocked; can't recover
					}
				}
			}
			t += max(abs(d), shadow_min_step);
		}
		// Sphere tracing has no step bound on a near-tangent ray: it crawls one clearance
		// per step alongside an edge and can spend the whole budget short of the source,
		// leaving a caster beyond it unseen and the fragment reported lit. Finish such a
		// march with a bounded sweep whose floor forces the rest of the ray into the steps
		// that remain. It runs the plain tests, so it starts past the exclusion phases'
		// reach, where an exempt caster can no longer be mistaken for a real one.
		t = max(t, t_ex_end);
		if (t < maxd) {
			int tail = max(max_steps >> 2, 4);
			for (int e = 0; e < tail && t < maxd; e++) {
				float d = lit_sdf_sample(frag_sdf + dir * t);
				float cand = 0.5 + d / (2.0 * w * t);
				if (cand < res) {
					float wc = mix(1.0, max(cand, 0.0), lit_tip_weight(t, t_tip, tip_band));
					if (wc < res) {
						res = wc;
						if (res <= 0.0) {
							return 0.0;
						}
					}
				}
				t += max(abs(d), (maxd - t) / float(tail - e));
			}
		}
		if (src_plane && maxd > shadow_min_step) {
			// Source-plane sample; see the header comment. Owned occluders stay exempt.
			float d = lit_sdf_sample(frag_sdf + dir * maxd);
			float cand = 0.5 + d / (2.0 * w * maxd);
			float own_r = (abs(d) + LIT_SELF_PAD_SDF) * self_scale;
			bool own_exempt = self_ex && maxd <= t_self_end
					&& lit_self_dist2(self_canvas + sdf_to_canvas * (dir * maxd)) <= own_r * own_r;
			own_exempt = own_exempt || LIT_RX_EXEMPT(self_canvas + sdf_to_canvas * (dir * maxd), frag_px + sdf_to_px * (dir * maxd), own_r);
			if (cand < res && !own_exempt) {
				float yw = 1.0;
#ifdef LIT_OCC_MASKS
				if (mk_on && maxd <= t_mk_end
						&& lit_mk_exempt(mk_row, self_canvas + sdf_to_canvas * (dir * maxd), own_r)) {
					yw = 0.0;
				}
#endif
#ifdef LIT_YSORT
				if (yw > 0.0) {
					yw = ys_on ? lit_ysort_weight(self_canvas + sdf_to_canvas * (dir * maxd),
							frag_px + sdf_to_px * (dir * maxd), own_r) : 1.0;
				}
#endif
				res = min(res, mix(1.0, max(cand, 0.0), yw));
			}
		}
		return clamp(res, 0.0, 1.0);
	}
}
#endif

