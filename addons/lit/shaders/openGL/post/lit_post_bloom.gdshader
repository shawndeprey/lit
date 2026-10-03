shader_type canvas_item;

// OpenGL/Compatibility twin of lit_post_bloom.gdshader (the web export path). The
// Compatibility renderer doesn't generate screen-texture mipmaps, so the Forward+
// version's textureLod level loop collapses to one full-res sample and the glow
// stops spreading. This twin replaces the mip pyramid with a cheap multi-ring blur
// of the soft-thresholded bright pass (three rings x four taps) - the same glow, no
// mipmaps. `bloom_radius` is now in screen pixels.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float threshold = 0.7;
uniform float intensity = 0.5;
uniform float bloom_radius = 4.0;   // glow reach in screen pixels

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
	vec2 px = SCREEN_PIXEL_SIZE;

	// Multi-ring blur of the bright pass: rings at r, 3r and 8r (r = bloom_radius)
	// approximate the mip levels the Forward+ pass samples, weighted so nearer rings
	// dominate (soft falloff, like the mip weights).
	vec3 bloom = vec3(0.0);
	float weight_sum = 0.0;
	for (int ring = 0; ring < 3; ring++) {
		float r = bloom_radius * (ring == 0 ? 0.5 : ring == 1 ? 1.5 : 4.0) * px.x;
		vec3 acc = vec3(0.0);
		acc += bright_pass(texture(screen_texture, SCREEN_UV + vec2( r, 0.0)).rgb);
		acc += bright_pass(texture(screen_texture, SCREEN_UV - vec2( r, 0.0)).rgb);
		acc += bright_pass(texture(screen_texture, SCREEN_UV + vec2(0.0,  r)).rgb);
		acc += bright_pass(texture(screen_texture, SCREEN_UV - vec2(0.0,  r)).rgb);
		float w = 1.0 / (float(ring) + 1.0);    // nearer rings weigh more
		bloom += acc * 0.25 * w;
		weight_sum += w;
	}
	bloom /= max(weight_sum, 0.0001);

	COLOR = vec4(original + bloom * intensity, 1.0);
}
