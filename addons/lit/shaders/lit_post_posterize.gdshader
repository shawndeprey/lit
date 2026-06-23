shader_type canvas_item;

// Quantizes each color channel into a few discrete levels for a hard, flat, comic
// look. Runs before Edge Outline so the outline inks the already-flattened color.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float levels = 4.0;     // discrete steps per channel (2 = harsh, higher = subtler)
uniform float strength = 1.0;   // blend between original and posterized

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	// Round each channel to the nearest of `n` evenly-spaced levels including 0 and 1,
	// so n = 4 gives {0, 1/3, 2/3, 1}.
	float n = max(levels, 2.0);
	vec3 quant = round(col * (n - 1.0)) / (n - 1.0);

	col = mix(col, quant, strength);
	COLOR = vec4(col, 1.0);
}
