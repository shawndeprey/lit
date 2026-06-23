shader_type canvas_item;

// Single-pass multi-scale glow. Sums a soft-thresholded bright-pass across several
// mip levels and adds it on top of the frame: the mips do the downsample/blur, the
// weighted sum does the upsample/composite.
//
// The screen is LDR (0..1), so a threshold near 1.0 catches almost nothing; the
// useful range is about 0.4 to 0.8. Needs screen-texture mipmaps; without them
// textureLod collapses to mip 0 and the glow stops spreading.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float threshold = 0.7;
uniform float intensity = 0.5;
uniform float bloom_radius = 4.0;   // wider value spreads the sampled mips, widening the glow

const int LEVELS = 5;
const float KNEE = 0.1;             // soft threshold knee

// Keep how much this color exceeds the threshold, preserving hue so a near-white
// light core stays white.
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
