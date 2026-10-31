// Unit: stochastic area shadow (LIT_SHADOW_STOCH): lit_shadow_stoch().

#ifdef LIT_SHADOW_STOCH
// Compile-time ceiling on area-light samples; the packed count is clamped to this on
// the CPU as well (lit/quality/shadow_samples_max).
const int LIT_MAX_SHADOW_SAMPLES = 32;

// Two strata's cone marches in lockstep (dir xy | zw), so the SDF reads of each step
// are in flight together: lit_shadow_cone's plain phases (steady, tail, source plane) for
// a fragment outside every shape with no exclusions, sample for sample. Keep it aligned
// with lit_shadow_cone. A march with maxd 0 is idle.
vec2 lit_shadow_cone2(vec2 frag_sdf, vec4 dir, vec2 maxd, vec2 tip_band, vec2 w, int max_steps, bool src_plane) {
	vec2 t_tip = maxd;
	vec2 t_cov = vec2(lit_sdf_cov_exit(frag_sdf, dir.xy), lit_sdf_cov_exit(frag_sdf, dir.zw));
	bvec2 plane = bvec2(src_plane && maxd.x <= t_cov.x, src_plane && maxd.y <= t_cov.y);
	maxd = min(maxd, t_cov);
	vec2 t = vec2(shadow_min_step);
	vec2 res = vec2(1.0);
	max_steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
	for (int s = 0; s < max_steps; s++) {
		bvec2 live = bvec2(t.x < maxd.x && res.x > 0.0, t.y < maxd.y && res.y > 0.0);
		if (!any(live)) {
			break;
		}
		vec2 d = vec2(lit_sdf_sample(frag_sdf + dir.xy * t.x), lit_sdf_sample(frag_sdf + dir.zw * t.y));
		vec2 cand = 0.5 + d / (2.0 * w * t);
		vec2 tw = vec2(lit_tip_weight(t.x, t_tip.x, tip_band.x), lit_tip_weight(t.y, t_tip.y, tip_band.y));
		res = mix(res, min(res, mix(vec2(1.0), max(cand, 0.0), tw)), live);
		t = mix(t, t + max(abs(d), shadow_min_step), live);
	}
	int tail = max(max_steps >> 2, 4);
	for (int e = 0; e < tail; e++) {
		bvec2 live = bvec2(t.x < maxd.x && res.x > 0.0, t.y < maxd.y && res.y > 0.0);
		if (!any(live)) {
			break;
		}
		vec2 d = vec2(lit_sdf_sample(frag_sdf + dir.xy * t.x), lit_sdf_sample(frag_sdf + dir.zw * t.y));
		vec2 cand = 0.5 + d / (2.0 * w * t);
		vec2 tw = vec2(lit_tip_weight(t.x, t_tip.x, tip_band.x), lit_tip_weight(t.y, t_tip.y, tip_band.y));
		res = mix(res, min(res, mix(vec2(1.0), max(cand, 0.0), tw)), live);
		t = mix(t, t + max(abs(d), (maxd - t) / float(tail - e)), live);
	}
	bvec2 at_src = bvec2(plane.x && maxd.x > shadow_min_step && res.x > 0.0, plane.y && maxd.y > shadow_min_step && res.y > 0.0);
	if (any(at_src)) {
		vec2 d = vec2(lit_sdf_sample(frag_sdf + dir.xy * maxd.x), lit_sdf_sample(frag_sdf + dir.zw * maxd.y));
		res = mix(res, min(res, max(0.5 + d / (2.0 * w * maxd), 0.0)), at_src);
	}
	return clamp(res, 0.0, 1.0);
}
#ifdef LIT_LINE

// Stratum i of n of a straight line light's window: march direction (xy), length, cone tangent.
vec4 lit_seg_stratum(vec2 frag_sdf, vec2 light_sdf, vec2 seg, float src_r, int i, int n, float jitter_amt, float ign,
		float cap_frac) {
	float rnd = fract(ign + float(i) * 0.61803398875);
	float u = ((float(i) + 0.5 + jitter_amt * (rnd - 0.5)) / float(n)) * 2.0 - 1.0;
	vec2 delta = (light_sdf + seg * u) - frag_sdf;
	float len = length(delta);
	vec2 sdir = delta / max(len, 1e-4);
	return vec4(sdir, len * cap_frac, max((abs(seg.x * sdir.y - seg.y * sdir.x) / float(n) + src_r) / max(len, 1e-4), 1e-4));
}
#else

// Stratum i of n of a point, spot or directional source: march direction (xy), length, cone tangent.
vec4 lit_pt_stratum(vec2 frag_sdf, vec2 light_sdf, vec2 dir, vec2 perp, float maxd, float src, bool is_dir, int i, int n,
		float jitter_amt, float ign, float half_stratum, float cap_frac) {
	float rnd = fract(ign + float(i) * 0.61803398875);
	float u = ((float(i) + 0.5 + jitter_amt * (rnd - 0.5)) / float(n)) * 2.0 - 1.0;
	if (is_dir) {
		return vec4(normalize(dir + perp * (u * src)), maxd * cap_frac, max(half_stratum, 1e-4));
	}
	vec2 delta = (light_sdf + perp * (u * src)) - frag_sdf;
	float len = length(delta);
	return vec4(delta / max(len, 1e-4), len * cap_frac, max(half_stratum / max(len, 1e-4), 1e-4));
}
#endif

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
		bool is_dir, int n, float jitter_amt, vec2 noise_px, int max_steps, float frag_d LIT_SEG_PARAMS,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	float w_gate = max(is_dir ? src : src / max(maxd, 1e-4), 1e-4);
	float band = capped ? w_gate * t_cap : 0.0;
	n = min(n, LIT_MAX_SHADOW_SAMPLES);
	vec2 perp = vec2(-dir.y, dir.x);
#ifdef LIT_LINE
	bool line = dot(seg, seg) > 0.0;
#endif
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
#ifdef LIT_LINE
	// Plain line strata march in pairs.
	if (line && frag_d >= 0.0 && !self_ex && !LIT_YS_ON && !LIT_RAMP_ON && !LIT_MK_ON && !LIT_RX_ON) {
		for (int i = 0; i < n; i += 2) {
			vec4 a = lit_seg_stratum(frag_sdf, light_sdf, seg, src_r, i, n, jitter_amt, ign, cap_frac);
			vec4 b = i + 1 < n ? lit_seg_stratum(frag_sdf, light_sdf, seg, src_r, i + 1, n, jitter_amt, ign, cap_frac)
					: vec4(0.0, 0.0, 0.0, 1.0);
			vec2 c2 = lit_shadow_cone2(frag_sdf, vec4(a.xy, b.xy), vec2(a.z, b.z), vec2(band), vec2(a.w, b.w), max_steps, !capped);
			sum += c2.x;
			sum += i + 1 < n ? c2.y : 0.0;
		}
		return sum / float(n);
	}
#else
	// Plain strata march in pairs.
	if (frag_d >= 0.0 && !self_ex && !LIT_YS_ON && !LIT_RAMP_ON && !LIT_MK_ON && !LIT_RX_ON) {
		for (int i = 0; i < n; i += 2) {
			vec4 a = lit_pt_stratum(frag_sdf, light_sdf, dir, perp, maxd, src, is_dir, i, n, jitter_amt, ign, half_stratum, cap_frac);
			vec4 b = i + 1 < n ? lit_pt_stratum(frag_sdf, light_sdf, dir, perp, maxd, src, is_dir, i + 1, n, jitter_amt, ign,
					half_stratum, cap_frac) : vec4(0.0, 0.0, 0.0, 1.0);
			vec2 c2 = lit_shadow_cone2(frag_sdf, vec4(a.xy, b.xy), vec2(a.z, b.z), vec2(band), vec2(a.w, b.w), max_steps,
					!is_dir && !capped);
			sum += c2.x;
			sum += i + 1 < n ? c2.y : 0.0;
		}
		return sum / float(n);
	}
#endif
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
#ifdef LIT_LINE
		} else if (line) {
			vec2 delta = (light_sdf + seg * u) - frag_sdf;
			float len = length(delta);
			sdir = delta / max(len, 1e-4);
			smaxd = len * cap_frac;
			w_sub = max((abs(seg.x * sdir.y - seg.y * sdir.x) / float(n) + src_r) / max(len, 1e-4), 1e-4);
#endif
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

#ifdef LIT_LINE
// Sphere-trace a gate cone (half-width tangent w around axis) out to reach: false at the
// first sample inside the cone, with t and d left there for the umbra walk.
bool lit_path_walk(vec2 frag_sdf, vec2 axis, float w, float reach, bool capped, int max_steps,
		inout float t, inout float d) {
	float t_cov = lit_sdf_cov_exit(frag_sdf, axis);
	bool plane = !capped && reach <= t_cov;
	float maxd = min(reach, t_cov);
	int steps = min(max_steps, LIT_MAX_SHADOW_STEPS);
	t = shadow_min_step;
	d = 0.0;
	for (int s = 0; s < steps && t < maxd; s++) {
		d = lit_sdf_sample(frag_sdf + axis * t);
		if (d < w * t) {
			return false;
		}
		t += max(d, shadow_min_step);
	}
	if (t < maxd) {
		int tail = max(steps >> 2, 4);
		for (int e = 0; e < tail && t < maxd; e++) {
			d = lit_sdf_sample(frag_sdf + axis * t);
			if (d < w * t) {
				return false;
			}
			t += max(d, (maxd - t) / float(tail - e));
		}
	}
	return !plane || maxd <= shadow_min_step || lit_sdf_sample(frag_sdf + axis * maxd) >= w * maxd;
}

// Stratum i of a path row: march direction (xy), length, cone tangent; band its tip band,
// weight its shading share, 0 (and maxd 0, idle) when it casts nothing.
vec4 lit_path_stratum(vec2 frag_sdf, int row, int i, int n, vec3 N, vec3 tube, float cap_frac, bool capped, float src_r,
		float jitter_amt, vec2 noise_px, float ign, out float band, out float weight) {
	band = 0.0;
	weight = 0.0;
	if (i >= n) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	vec4 ch = texelFetch(lit_light_path, ivec2(LIT_PATH_SHADOW + i, row), 0);
	float w = lit_line_weight(ch, noise_px, N, tube.x, tube.y, vec2(i == 0 ? tube.z : 0.0, i == n - 1 ? tube.z : 0.0));
	if (w <= 0.0) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	vec2 mid = screen_uv_to_sdf(ch.xy / lit_viewport_size);
	vec2 hv = screen_uv_to_sdf((ch.xy + ch.zw) / lit_viewport_size) - mid;
	float rnd = fract(ign + float(i) * 0.61803398875);
	vec2 delta = mid + hv * (2.0 * jitter_amt * (rnd - 0.5)) - frag_sdf;
	float len = length(delta);
	vec2 sdir = delta / max(len, 1e-4);
	float w_sub = max((abs(hv.x * sdir.y - hv.y * sdir.x) + src_r) / max(len, 1e-4), 1e-4);
	band = capped ? w_sub * len * cap_frac : 0.0;
	weight = w;
	return vec4(sdir, len * cap_frac, w_sub);
}

// Strata of a curved line light: one sub-cone per shadow chord of its path row, each
// covering its chord as seen from the fragment plus the tube's radius src_r, weighted
// as the shading weights the chords (lit_line_chord): the visible share of the light
// the fragment receives. Its own loop, so the straight strata loop above carries no
// chord fetch. Each stratum closes its own tip band at the cap.
// A walk of the cone over the bounding circle answers first (clear = lit); then a
// prepass finds the strata's tighter angular hull, whose walk answers clear = lit and
// spanned = dark, and each stratum's weight is taken as it is marched.
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
	float t = 0.0;
	float d = 0.0;
	// Every stratum's cone lies in the cone over the bounding circle grown by twice the
	// longest shadow chord's half-length (its aim point and cross section) and src_r.
	float rg = r_sdf * (1.0 + 1.1 * texelFetch(lit_light_path, ivec2(LIT_PATH_INFO, row), 0).w / (float(n) * max(c0.z, 1e-4))) + src_r;
	if (c_len > rg * 1.001) {
		float w_c = rg * inversesqrt(c_len * c_len - rg * rg);
		if (w_c <= 4.0 && lit_path_walk(frag_sdf, axis, w_c, (c_len + rg) * cap_frac, capped, max_steps, t, d)) {
			return 1.0;
		}
	}
	float ign = fract(52.9829189 * fract(dot(noise_px, vec2(0.06711056, 0.00583715))));
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
	}
	if (frag_d >= t_ball * 1.05 + 0.5) {
		return 1.0;
	}
	if (hull && w_gate <= 4.0) {
		if (lit_path_walk(frag_sdf, axis, w_gate, t_far * cap_frac, capped, max_steps, t, d)) {
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
	if (frag_d >= 0.0 && !self_ex && !LIT_YS_ON && !LIT_RAMP_ON && !LIT_MK_ON && !LIT_RX_ON) {
		for (int i = 0; i < n; i += 2) {
			float ba;
			float wa;
			float bb;
			float wb;
			vec4 a = lit_path_stratum(frag_sdf, row, i, n, N, tube, cap_frac, capped, src_r, jitter_amt, noise_px, ign, ba, wa);
			vec4 b = lit_path_stratum(frag_sdf, row, i + 1, n, N, tube, cap_frac, capped, src_r, jitter_amt, noise_px, ign, bb, wb);
			vec2 c = lit_shadow_cone2(frag_sdf, vec4(a.xy, b.xy), vec2(a.z, b.z), vec2(ba, bb), vec2(a.w, b.w), max_steps, !capped);
			sum += wa * c.x;
			wsum += wa;
			sum += wb * c.y;
			wsum += wb;
		}
		return wsum > 0.0 ? clamp(sum / wsum, 0.0, 1.0) : 1.0;
	}
	for (int i = 0; i < n; i++) {
		vec4 ch = texelFetch(lit_light_path, ivec2(LIT_PATH_SHADOW + i, row), 0);
		float w = lit_line_weight(ch, noise_px, N, tube.x, tube.y, vec2(i == 0 ? tube.z : 0.0, i == n - 1 ? tube.z : 0.0));
		if (w <= 0.0) {
			continue;
		}
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
	return wsum > 0.0 ? clamp(sum / wsum, 0.0, 1.0) : 1.0;
}
#endif
#endif

