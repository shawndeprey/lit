shader_type canvas_item;

// Halation post pass (post-v1, to_do_post_processing.md). The film companion to
// bloom: a warm, red-leaning halo that blooms around highlights the way red light
// scatters and re-exposes film emulsion. Same single-pass multi-scale mip trick as
// bloom (mips are the cheap downsample/blur; the weighted sum is the composite), but
// the glow is driven by a luma bright-pass and recolored to a warm `tint` instead of
// preserving the source hue — that's what gives the signature reddish bleed.
//
// Depends on screen-texture mipmaps for filter_linear_mipmap (works in Godot 4.7).
// If mips are unavailable, textureLod collapses to mip 0 -> the halo stops spreading.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float threshold = 0.6;            // luma above this halates
uniform float intensity = 0.6;            // halo strength added on top
uniform float halation_radius = 5.0;      // spreads the sampled mips -> halo width
uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.1, 1.0);  // warm red-orange

const int LEVELS = 5;
const float KNEE = 0.1;                    // soft threshold knee

// Soft-knee bright-pass returning a scalar (luma) — the halo is colorized by `tint`,
// so only the brightness of the highlight matters, not its hue.
float bright_luma(vec3 c) {
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));   // Rec. 709 luma
	return luma * smoothstep(threshold - KNEE, threshold + KNEE, luma);
}

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;

	float halo = 0.0;
	float weight_sum = 0.0;
	for (int i = 0; i < LEVELS; i++) {
		float lod = (float(i) + 1.0) * (halation_radius * 0.2);
		vec3 sample_col = textureLod(screen_texture, SCREEN_UV, lod).rgb;
		float w = 1.0 / (float(i) + 1.0);    // nearer mips weigh more (soft falloff)
		halo += bright_luma(sample_col) * w;
		weight_sum += w;
	}
	halo /= max(weight_sum, 0.0001);

	vec3 glow = tint.rgb * halo * intensity;
	COLOR = vec4(original + glow, 1.0);
}
