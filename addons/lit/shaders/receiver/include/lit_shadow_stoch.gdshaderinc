// Unit: stochastic area shadow (LIT_SHADOW_STOCH): lit_shadow_stoch().

#ifdef LIT_SHADOW_STOCH
// Compile-time ceiling on area-light samples; the packed count is clamped to this on
// the CPU as well (lit/quality/shadow_samples_max).
const int LIT_MAX_SHADOW_SAMPLES = 32;

// Stochastic area-light visibility: split the source into n strata and cone-march a
// narrow sub-cone covering each, averaging the fractional stratum coverages - true
// umbra (every stratum blocked), penumbra (some partially blocked) and antumbra (a
// source wider than the occluder is never fully blocked). Fractional sub-cones instead
// of binary hard marches matter: a binary sample quantizes to 0/1, and with a large or
// close source the penumbra spans many strata, concentrating +-1/n binary noise into
// visible streak bands that jitter cannot smooth (the noise IS the jitter, organized
// along the noise pattern's level lines). A sub-cone returns its stratum's coverage
// continuously, so the estimate is smooth at any n, and n = 1 degenerates exactly to
// the Cone Traced algorithm. Multi-occluder accumulation across strata is preserved
// (the single-blocker minimum applies only within one narrow sub-wedge, where it is
// nearly exact). Point/spot: strata span the emitting disc's diameter perpendicular to
// the light direction, src is its half-extent in SDF units. Line: strata tile the
// source segment, light_sdf its middle and seg its half-vector (SDF units), each
// sub-cone covering its piece of the tube as seen from the fragment plus the tube's
// radius src_r; src is the whole part's apparent half-width, for the gate. Directional:
// the march direction deflects across the source's angular extent, src is tan(half-angle).
// jitter blends stratum centers toward per-pixel randomized positions inside each
// stratum; with fractional samples it adds only faint residual grain either way.
//
// Penumbra gate: one cone-coverage march classifies the fragment first, so only
// genuine penumbra pays for the n marches (the adaptive-sampling structure of PCSS's
// blocker-search early-out and of tile classification in production ray-traced
// shadows). The gate's endpoints are trustworthy by the cone march's own geometry:
// coverage 0 means some step's empty-space ball spanned the whole source wedge from
// inside a shape - every sample ray crosses it - and coverage 1 means no step came
// within the wedge, which contains all sample rays. Between the endpoints the n-march
// estimate runs unchanged, so multi-occluder accumulation (which the single-blocker
// cone minimum underestimates) is preserved exactly where it matters.
// t_cap caps every march short of the source (shadow_length) when capped is set. The
// tip band spans the FULL source's penumbra width at the cap and is shared by the gate
// and all strata, so the aggregate closes as one shadow.
//
// The gate is its own call ahead of the strata loop (the march inlines twice): kept
// out of the loop body it costs nothing, and the loop stays free of gate-only state,
// which the stochastic variant's register budget cannot absorb. n = 0 returns the
// gate alone, which is the Cone Traced algorithm.
float lit_shadow_stoch(vec2 frag_sdf, vec2 light_sdf, vec2 dir, float maxd, float t_cap, bool capped, float src,
		bool is_dir, int n, float jitter_amt, vec2 noise_px, int max_steps, float frag_d,
		vec2 seg, float src_r,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	float w_gate = max(is_dir ? src : src / max(maxd, 1e-4), 1e-4);
	float band = capped ? w_gate * t_cap : 0.0;
	n = min(n, LIT_MAX_SHADOW_SAMPLES);
	vec2 perp = vec2(-dir.y, dir.x);
	bool line = dot(seg, seg) > 0.0;
	// Interleaved gradient noise gives the per-pixel base; the golden-ratio sequence
	// decorrelates it across samples.
	float ign = fract(52.9829189 * fract(dot(noise_px, vec2(0.06711056, 0.00583715))));
	// Half-extent of one stratum: each sub-cone's angular half-width (directional) or
	// half-width at the source (point/spot), so the n sub-cones tile the source exactly.
	float half_stratum = src / float(max(n, 1));
	// Per-stratum cap as a fraction so point/spot strata (whose lengths differ per
	// stratum) all close on the same tip isoline.
	float cap_frac = capped ? t_cap / max(maxd, 1e-4) : 1.0;
	float c = lit_shadow_cone(frag_sdf, dir, t_cap, band, w_gate,
			max_steps, frag_d,
			!is_dir && !capped, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
	if (n <= 0 || c <= 0.0 || c >= 1.0) {
		return c;
	}
	float sum = 0.0;
	for (int i = 0; i < n; i++) {
		vec2 sdir;
		float smaxd;
		float w_sub;
		float rnd = fract(ign + float(i) * 0.61803398875);
		float u = ((float(i) + 0.5 + jitter_amt * (rnd - 0.5)) / float(n)) * 2.0 - 1.0;
		if (is_dir) {
			sdir = normalize(dir + perp * (u * src));
			smaxd = maxd * cap_frac;
			w_sub = max(half_stratum, 1e-4);
		} else if (line) {
			vec2 delta = (light_sdf + seg * u) - frag_sdf;
			float len = length(delta);
			sdir = delta / max(len, 1e-4);
			smaxd = len * cap_frac;
			w_sub = max((abs(seg.x * sdir.y - seg.y * sdir.x) / float(n) + src_r) / max(len, 1e-4), 1e-4);
		} else {
			vec2 delta = (light_sdf + perp * (u * src)) - frag_sdf;
			float len = length(delta);
			sdir = delta / max(len, 1e-4);
			smaxd = len * cap_frac;
			w_sub = max(half_stratum / max(len, 1e-4), 1e-4);
		}
		sum += lit_shadow_cone(frag_sdf, sdir, smaxd, band, w_sub,
				max_steps, frag_d,
				!is_dir && !capped, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
	}
	return sum / float(n);
}

// Strata of a curved line light: one sub-cone per shadow chord of its path row, each
// covering its chord as seen from the fragment plus the tube's radius src_r, weighted
// as the shading weights the chords (lit_line_chord): the visible share of the light
// the fragment receives. Its own loop, so the straight strata loop above carries no
// chord fetch. Each stratum closes its own tip band at the cap.
// A prepass finds the strata's angular hull and the first eight weights; the clearance
// test and a sphere-trace walk of the hull (clear = lit, spanned = dark) answer alone.
float lit_shadow_path(vec2 frag_sdf, int row, int n, vec3 N, vec3 tube, float cap_frac, bool capped, float src_r,
		float jitter_amt, vec2 noise_px, int max_steps, float frag_d,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	n = clamp(n, 1, LIT_MAX_SHADOW_SAMPLES);
	vec4 c0 = texelFetch(lit_light_path, ivec2(0, row), 0);
	vec2 c_sdf = screen_uv_to_sdf(c0.xy / lit_viewport_size);
	float r_sdf = max(length(screen_uv_to_sdf((c0.xy + vec2(c0.z, 0.0)) / lit_viewport_size) - c_sdf),
			length(screen_uv_to_sdf((c0.xy + vec2(0.0, c0.z)) / lit_viewport_size) - c_sdf));
	vec2 axis = c_sdf - frag_sdf;
	float c_len = length(axis);
	if (frag_d >= (c_len + 2.0 * r_sdf + src_r) * 1.05 + 0.5) {
		return 1.0;
	}
	axis /= max(c_len, 1e-4);
	float ign = fract(52.9829189 * fract(dot(noise_px, vec2(0.06711056, 0.00583715))));
	vec4 w0 = vec4(0.0);
	vec4 w1 = vec4(0.0);
	float wsum0 = 0.0;
	float w_gate = 0.0;
	float t_far = 0.0;
	float t_near = 1e30;
	float t_ball = 0.0;
	bool hull = true;
	for (int i = 0; i < n; i++) {
		vec4 ch = texelFetch(lit_light_path, ivec2(LIT_PATH_SHADOW + i, row), 0);
		vec2 mid = screen_uv_to_sdf(ch.xy / lit_viewport_size);
		vec2 hv = screen_uv_to_sdf((ch.xy + ch.zw) / lit_viewport_size) - mid;
		float rnd = fract(ign + float(i) * 0.61803398875);
		vec2 delta = mid + hv * (2.0 * jitter_amt * (rnd - 0.5)) - frag_sdf;
		float len = length(delta);
		vec2 sdir = delta / max(len, 1e-4);
		float w_sub = max((abs(hv.x * sdir.y - hv.y * sdir.x) + src_r) / max(len, 1e-4), 1e-4);
		float along = dot(sdir, axis);
		float tan_s = abs(sdir.x * axis.y - sdir.y * axis.x) / max(along, 1e-6);
		hull = hull && along > 0.0 && tan_s * w_sub < 1.0;
		w_gate = max(w_gate, (tan_s + w_sub) / max(1.0 - tan_s * w_sub, 1e-6));
		t_far = max(t_far, len * sqrt(1.0 + w_sub * w_sub));
		t_near = min(t_near, len * along);
		t_ball = max(t_ball, len * (1.0 + w_sub));
		if (i < 8) {
			vec2 free = vec2(i == 0 ? tube.z : 0.0, i == n - 1 ? tube.z : 0.0);
			float w = lit_line_weight(ch, noise_px, N, tube.x, tube.y, free);
			w0 += vec4(i == 0 ? w : 0.0, i == 1 ? w : 0.0, i == 2 ? w : 0.0, i == 3 ? w : 0.0);
			w1 += vec4(i == 4 ? w : 0.0, i == 5 ? w : 0.0, i == 6 ? w : 0.0, i == 7 ? w : 0.0);
			wsum0 += max(w, 0.0);
		}
	}
	if ((n <= 8 && wsum0 <= 0.0) || frag_d >= t_ball * 1.05 + 0.5) {
		return 1.0;
	}
	if (hull && w_gate <= 4.0) {
		float reach = t_far * cap_frac;
		float t_cov = lit_sdf_cov_exit(frag_sdf, axis);
		bool plane = !capped && reach <= t_cov;
		float maxd = min(reach, t_cov);
		int steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
		float t = shadow_min_step;
		float d = 0.0;
		bool clear = true;
		for (int s = 0; s < steps && t < maxd; s++) {
			d = lit_sdf_sample(frag_sdf + axis * t);
			if (d < w_gate * t) {
				clear = false;
				break;
			}
			t += max(d, shadow_min_step);
		}
		if (clear && t < maxd) {
			int tail = max(steps >> 2, 4);
			for (int e = 0; e < tail && t < maxd; e++) {
				d = lit_sdf_sample(frag_sdf + axis * t);
				if (d < w_gate * t) {
					clear = false;
					break;
				}
				t += max(d, (maxd - t) / float(tail - e));
			}
		}
		if (clear && plane && maxd > shadow_min_step) {
			clear = lit_sdf_sample(frag_sdf + axis * maxd) >= w_gate * maxd;
		}
		if (clear) {
			return 1.0;
		}
		if (!capped && !self_ex && !LIT_YS_ON && !LIT_RAMP_ON && !LIT_MK_ON && !LIT_RX_ON) {
			for (int e = 0; e < 16 && t <= t_near; e++) {
				if (d <= -w_gate * t) {
					return 0.0;
				}
				if (d >= 0.0 && e >= 2) {
					break;
				}
				t += max(abs(d), shadow_min_step);
				d = lit_sdf_sample(frag_sdf + axis * t);
			}
		}
	}
	float sum = 0.0;
	float wsum = 0.0;
	for (int b = 0; b < n; b += 8) {
		if (b > 0) {
			w0 = vec4(0.0);
			w1 = vec4(0.0);
			for (int i = b; i < min(b + 8, n); i++) {
				vec4 ch = texelFetch(lit_light_path, ivec2(LIT_PATH_SHADOW + i, row), 0);
				vec2 free = vec2(i == 0 ? tube.z : 0.0, i == n - 1 ? tube.z : 0.0);
				float w = lit_line_weight(ch, noise_px, N, tube.x, tube.y, free);
				int j = i - b;
				w0 += vec4(j == 0 ? w : 0.0, j == 1 ? w : 0.0, j == 2 ? w : 0.0, j == 3 ? w : 0.0);
				w1 += vec4(j == 4 ? w : 0.0, j == 5 ? w : 0.0, j == 6 ? w : 0.0, j == 7 ? w : 0.0);
			}
		}
		for (int i = b; i < min(b + 8, n); i++) {
			int j = i - b;
			float w = j < 4 ? (j < 2 ? (j == 0 ? w0.x : w0.y) : (j == 2 ? w0.z : w0.w))
					: (j < 6 ? (j == 4 ? w1.x : w1.y) : (j == 6 ? w1.z : w1.w));
			if (w <= 0.0) {
				continue;
			}
			vec4 ch = texelFetch(lit_light_path, ivec2(LIT_PATH_SHADOW + i, row), 0);
			vec2 mid = screen_uv_to_sdf(ch.xy / lit_viewport_size);
			vec2 hv = screen_uv_to_sdf((ch.xy + ch.zw) / lit_viewport_size) - mid;
			float rnd = fract(ign + float(i) * 0.61803398875);
			vec2 delta = mid + hv * (2.0 * jitter_amt * (rnd - 0.5)) - frag_sdf;
			float len = length(delta);
			vec2 sdir = delta / max(len, 1e-4);
			float w_sub = max((abs(hv.x * sdir.y - hv.y * sdir.x) + src_r) / max(len, 1e-4), 1e-4);
			sum += w * lit_shadow_cone(frag_sdf, sdir, len * cap_frac, capped ? w_sub * len * cap_frac : 0.0, w_sub,
					max_steps, frag_d,
					!capped, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
			wsum += w;
		}
	}
	return wsum > 0.0 ? clamp(sum / wsum, 0.0, 1.0) : 1.0;
}
#endif

