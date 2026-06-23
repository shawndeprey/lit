shader_type canvas_item;

// Snaps sampling to a coarse grid so the frame reads as chunky low-res blocks.
// `pixel_size` is the block edge in screen pixels (1 = off). Runs before the display
// passes so CRT and scanlines fall over the chunky pixels.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float pixel_size = 4.0;   // block edge, in screen pixels (1 = off)

void fragment() {
	// Block size in UV, then sample each block's center so the whole block reads as
	// one flat color.
	vec2 cell = max(pixel_size, 1.0) * SCREEN_PIXEL_SIZE;
	vec2 uv = (floor(SCREEN_UV / cell) + 0.5) * cell;

	COLOR = vec4(texture(screen_texture, uv).rgb, 1.0);
}
