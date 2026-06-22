shader_type canvas_item;

// Bloom post pass (plan §7.5 / D8): LDR, multi-scale glow, single pass.
//
// Reads the screen WITH mipmaps and sums a soft-thresholded bright-pass across
// several downsampled mip levels, then adds it on top of the original frame. Mips
// are the cheap "downsample -> blur"; the weighted sum across levels is the
// "upsample -> composite". The result is a wide, soft, multi-scale glow around
// bright areas (light cores, emissive) — the fantasy look.
//
// LDR note: the screen is 0..1, so `threshold` near 1.0 catches almost nothing.
// Useful range is ~0.4–0.8; default 0.7 (deviation from plan's 1.0, which assumed
// HDR-ish accumulation). Crank `intensity` for heavier bloom.
//
// Depends on screen-texture mipmaps being generated for `filter_linear_mipmap`.
// If they are NOT, textureLod() collapses to mip 0 → highlights brighten but don't
// spread softly; that's the signal to fall back to an explicit multi-tap blur.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float threshold = 0.7;
uniform float intensity = 0.5;
uniform float bloom_radius = 4.0;   // spreads the sampled mip levels -> glow width

const int LEVELS = 5;
const float KNEE = 0.1;             // soft threshold knee

// Soft-knee bright-pass: keep how much this color exceeds the threshold,
// color-preserving (a near-white light core keeps its hue).
vec3 bright_pass(vec3 c) {
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));   // Rec. 709 luma
	float soft = smoothstep(threshold - KNEE, threshold + KNEE, luma);
	return c * soft;
}

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;

	vec3 bloom = vec3(0.0);
	float weight_sum = 0.0;
	for (int i = 0; i < LEVELS; i++) {
		float lod = (float(i) + 1.0) * (bloom_radius * 0.2);
		vec3 sample_col = textureLod(screen_texture, SCREEN_UV, lod).rgb;
		float w = 1.0 / (float(i) + 1.0);    // nearer mips weigh more (soft falloff)
		bloom += bright_pass(sample_col) * w;
		weight_sum += w;
	}
	bloom /= max(weight_sum, 0.0001);

	COLOR = vec4(original + bloom * intensity, 1.0);
}
