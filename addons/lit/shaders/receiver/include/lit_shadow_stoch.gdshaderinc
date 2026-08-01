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
// the light direction, src is its half-extent in SDF units. Directional: the march
// direction deflects across the source's angular extent, src is tan(half-angle).
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
float lit_shadow_stoch(vec2 frag_sdf, vec2 light_sdf, vec2 dir, float maxd, float src,
		bool is_dir, int n, float jitter_amt, vec2 noise_px, int max_steps, float frag_d,
		bool self_ex, vec2 self_canvas, mat2 sdf_to_canvas, float self_scale LIT_PX_PARAMS LIT_YS_PARAMS LIT_RX_PARAMS LIT_MK_PARAMS) {
	float w_gate = max(is_dir ? src : src / max(maxd, 1e-4), 1e-4);
	float gate = lit_shadow_cone(frag_sdf, dir, maxd, w_gate, max_steps, frag_d,
			!is_dir, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
	if (gate <= 0.0) {
		return 0.0;
	}
	if (gate >= 1.0) {
		return 1.0;
	}
	n = clamp(n, 1, LIT_MAX_SHADOW_SAMPLES);
	vec2 perp = vec2(-dir.y, dir.x);
	// Interleaved gradient noise gives the per-pixel base; the golden-ratio sequence
	// decorrelates it across samples.
	float ign = fract(52.9829189 * fract(dot(noise_px, vec2(0.06711056, 0.00583715))));
	// Half-extent of one stratum: each sub-cone's angular half-width (directional) or
	// half-width at the source (point/spot), so the n sub-cones tile the source exactly.
	float half_stratum = src / float(n);
	float sum = 0.0;
	for (int i = 0; i < n; i++) {
		float rnd = fract(ign + float(i) * 0.61803398875);
		float u = ((float(i) + 0.5 + jitter_amt * (rnd - 0.5)) / float(n)) * 2.0 - 1.0;
		vec2 sdir = dir;
		float smaxd = maxd;
		float w_sub;
		if (is_dir) {
			sdir = normalize(dir + perp * (u * src));
			w_sub = half_stratum;
		} else {
			vec2 delta = (light_sdf + perp * (u * src)) - frag_sdf;
			smaxd = length(delta);
			sdir = delta / max(smaxd, 1e-4);
			w_sub = half_stratum / max(smaxd, 1e-4);
		}
		sum += lit_shadow_cone(frag_sdf, sdir, smaxd, max(w_sub, 1e-4), max_steps, frag_d,
				!is_dir, self_ex, self_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS LIT_RX_ARGS LIT_MK_ARGS);
	}
	return sum / float(n);
}
#endif

