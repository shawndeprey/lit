shader_type canvas_item;

// OpenGL/Compatibility twin of lit_post_halation.gdshader (the web export path). The
// Compatibility renderer doesn't generate screen-texture mipmaps, so the Forward+
// version's textureLod level loop collapses to one full-res sample. This twin
// replaces the mip pyramid with a cheap multi-ring blur of the luma bright-pass
// (three rings x four taps) - the same warm halo, no mipmaps. `halation_radius` is
// now in screen pixels.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float threshold = 0.6;            // luma above this halates
uniform float intensity = 0.6;            // halo strength added on top
uniform float halation_radius = 5.0;      // halo reach in screen pixels
uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.1, 1.0);  // warm red-orange

const float KNEE = 0.1;                   // soft threshold knee

// Scalar (luma) bright-pass. The halo takes its color from `tint`, so only the
// highlight's brightness matters, not its hue.
float bright_luma(vec3 c) {
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));   // Rec. 709 luma
	return luma * smoothstep(threshold - KNEE, threshold + KNEE, luma);
}

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;
	vec2 px = SCREEN_PIXEL_SIZE;

	// Multi-ring blur of the bright pass: rings at r, 3r and 8r (r = halation_radius)
	// approximate the mip levels the Forward+ pass samples, weighted so nearer rings
	// dominate (soft falloff, like the mip weights).
	float halo = 0.0;
	float weight_sum = 0.0;
	for (int ring = 0; ring < 3; ring++) {
		float r = halation_radius * (ring == 0 ? 0.5 : ring == 1 ? 1.5 : 4.0) * px.x;
		float acc = 0.0;
		acc += bright_luma(texture(screen_texture, SCREEN_UV + vec2( r, 0.0)).rgb);
		acc += bright_luma(texture(screen_texture, SCREEN_UV - vec2( r, 0.0)).rgb);
		acc += bright_luma(texture(screen_texture, SCREEN_UV + vec2(0.0,  r)).rgb);
		acc += bright_luma(texture(screen_texture, SCREEN_UV - vec2(0.0,  r)).rgb);
		float w = 1.0 / (float(ring) + 1.0);    // nearer rings weigh more
		halo += acc * 0.25 * w;
		weight_sum += w;
	}
	halo /= max(weight_sum, 0.0001);

	vec3 glow = tint.rgb * halo * intensity;
	COLOR = vec4(original + glow, 1.0);
}
