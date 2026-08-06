shader_type canvas_item;

// 2x1 state, ping-ponged through prev_tex: pixel 0 = applied EV (B = validity),
// pixel 1 = slow scene-baseline EV (B = has seen a lit frame). Only deviation from
// the baseline is countered, so a stable scene rests at the authored look.
uniform sampler2D hist_tex : hint_default_black, filter_nearest;
uniform sampler2D prev_tex : hint_default_black, filter_nearest;

uniform float delta_t = 0.016;
uniform float target_level = 1.0;
uniform float exposure_compensation = 0.0;
uniform float min_exposure = -2.5;
uniform float max_exposure = 1.5;
uniform float light_adapt_time = 0.85;
uniform float dark_adapt_time = 3.0;
uniform float acclimate_time = 6.0;
uniform float histogram_low = 0.7;
uniform float histogram_high = 0.97;

const int RW = 64;                 // must match the node's _REDUCE_SIZE
const int RH = 36;
const int BINS = 64;               // must match the hist shader
const int GROUPS = 6;              // must match the hist shader
const float EV_MIN = -12.0;        // must match the reduce shader's encoding range
const float EV_MAX = 0.0;
const float GEV = 6.0;             // applied-exposure range, must match apply shader
const float BEV_MIN = -14.0;       // baseline (scene brightness) encoding range
const float BEV_MAX = 4.0;
const float BLIND_EV = -11.0;      // darker than any lit scene = nothing to see

vec2 encode16(float n) {
	float v = clamp(n, 0.0, 1.0) * 65535.0;
	float hi = floor(v / 256.0);
	return vec2(hi, floor(v - hi * 256.0)) / 255.0;
}

float decode16(vec2 rg) {
	return (rg.x * 255.0 * 256.0 + rg.y * 255.0) / 65535.0;
}

float decode24(vec3 rgb) {
	return (rgb.r * 255.0 * 65536.0 + rgb.g * 255.0 * 256.0 + rgb.b * 255.0) / 16777215.0;
}

void fragment() {
	float hist[BINS];
	float total = 0.0;
	for (int i = 0; i < BINS; i++) {
		float m = 0.0;
		for (int g = 0; g < GROUPS; g++) {
			m += decode24(texelFetch(hist_tex, ivec2(i, g), 0).rgb);
		}
		hist[i] = m * float(RW * RH);
		total += hist[i];
	}

	// average EV of the histogram mass between the two percentiles
	float lo_mass = total * min(histogram_low, 0.98);
	float hi_mass = total * max(histogram_high, min(histogram_low, 0.98) + 0.02);
	float cum = 0.0;
	float kept = 0.0;
	float kept_ev = 0.0;
	for (int i = 0; i < BINS; i++) {
		float m = hist[i];
		float below = clamp(lo_mass - cum, 0.0, m);
		float above = clamp(cum + m - hi_mass, 0.0, m);
		float k = max(m - below - above, 0.0);
		kept += k;
		kept_ev += k * mix(EV_MIN, EV_MAX, (float(i) + 0.5) / float(BINS));
		cum += m;
	}

	vec4 prev0 = texelFetch(prev_tex, ivec2(0, 0), 0);
	vec4 prev1 = texelFetch(prev_tex, ivec2(1, 0), 0);
	bool state_valid = prev0.b > 0.5;
	bool base_valid = state_valid && prev1.b > 0.5;
	float applied_prev = state_valid ? decode16(prev0.rg) * 2.0 * GEV - GEV : 0.0;
	float baseline_prev = mix(BEV_MIN, BEV_MAX, decode16(prev1.rg));

	// subtract our own applied exposure so the loop never chases its output
	float scene_ev = kept > 1e-4 ? kept_ev / kept - applied_prev : BEV_MIN;

	// near-black frames (loads, fades) must not train the baseline
	bool blind = scene_ev < BLIND_EV;

	float baseline = baseline_prev;
	if (!blind) {
		if (base_valid) {
			float brate = 1.0 - exp(-delta_t * 3.0 / max(acclimate_time, 0.001));
			baseline = mix(baseline_prev, scene_ev, brate);
		} else {
			baseline = scene_ev;
			base_valid = true;
		}
	}

	// rest bias sits outside the clamps so target_level's full range is visible
	float rest = log2(clamp(target_level, 0.01, 2.0)) + exposure_compensation;
	float desired = rest;
	if (!blind && base_valid) {
		desired += clamp(baseline - scene_ev, min_exposure, max_exposure);
	}

	// adapt knobs read as seconds to settle (~3 tau)
	float adapt_time = desired < applied_prev ? light_adapt_time : dark_adapt_time;
	float rate = 1.0 - exp(-delta_t * 3.0 / max(adapt_time, 0.001));
	float applied = state_valid ? mix(applied_prev, desired, rate) : 0.0;

	if (SCREEN_UV.x < 0.5) {
		COLOR = vec4(encode16((applied + GEV) / (2.0 * GEV)), 1.0, 1.0);
	} else {
		COLOR = vec4(encode16((baseline - BEV_MIN) / (BEV_MAX - BEV_MIN)),
				base_valid ? 1.0 : 0.0, 1.0);
	}
}
