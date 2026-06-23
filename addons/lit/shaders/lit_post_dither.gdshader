shader_type canvas_item;

// Dither post pass (post-v1, to_do_post_processing.md). Ordered 4x4 Bayer dithering
// into a small number of per-channel levels — the PICO-8 / 1-bit / Game-Boy look. The
// Bayer threshold pushes each pixel across a quantization step so flat banding becomes
// a stable cross-hatch instead. `monochrome` collapses to luma first for true 1-bit.
// Reads the frame so far via hint_screen_texture.
//
// Runs late in the stylize cluster (after outline/halftone): dithering adds lots of
// high-frequency detail, so anything edge-detecting must come before it.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float levels = 4.0;       // quantization steps per channel (2 = 1-bit per channel)
uniform float scale = 1.0;        // Bayer cell size in screen pixels (bigger = chunkier)
uniform bool monochrome = false;  // collapse to luma first (true 1-bit when levels = 2)
uniform float strength = 1.0;     // blend between original and dithered

// 4x4 Bayer threshold matrix, values 0..15 (row-major).
const float BAYER[16] = {
	 0.0,  8.0,  2.0, 10.0,
	12.0,  4.0, 14.0,  6.0,
	 3.0, 11.0,  1.0,  9.0,
	15.0,  7.0, 13.0,  5.0
};

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;

	vec3 col = original;
	if (monochrome) {
		col = vec3(dot(col, vec3(0.2126, 0.7152, 0.0722)));
	}

	// Bayer threshold in [-0.5, 0.5), tiled across the screen at `scale` pixels.
	ivec2 p = ivec2(FRAGCOORD.xy / max(scale, 1.0));
	int idx = (p.y % 4) * 4 + (p.x % 4);
	float threshold = BAYER[idx] / 16.0 - 0.5;

	// Offset by one quantization step's worth of threshold, then snap to N levels.
	float n = max(levels, 2.0);
	vec3 dithered = col + threshold / (n - 1.0);
	vec3 quant = round(dithered * (n - 1.0)) / (n - 1.0);

	COLOR = vec4(mix(original, quant, strength), 1.0);
}
