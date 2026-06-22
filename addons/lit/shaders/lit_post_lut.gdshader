shader_type canvas_item;

// LUT color-grade post pass (post-v1, see to_do_post_processing.md).
//
// Remaps the screen through a standard NEUTRAL LUT STRIP: a 256×16 texture laid out
// as 16 horizontal tiles of 16×16, where tile = blue slice, x = red, y = green.
// Grade a neutral LUT in any image editor / DaVinci and feed the result here for an
// instant "filter". `amount` blends between the original and the LUT-graded color.
//
// Import the LUT texture as: Filter ON (linear), Mipmaps OFF, Repeat OFF (clamp),
// lossless (no VRAM compression) — compression/mips smear the cells and corrupt the
// grade.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform sampler2D lut : filter_linear, repeat_disable;
uniform float amount : hint_range(0.0, 1.0) = 1.0;

const float CELLS = 16.0;            // size per axis (16-slice LUT)
const float TEX_W = CELLS * CELLS;   // 256

vec3 sample_lut(vec3 col) {
	col = clamp(col, 0.0, 1.0);

	// Blue selects which tile; interpolate between the two nearest blue slices.
	float b = col.b * (CELLS - 1.0);
	float b0 = floor(b);
	float b1 = min(b0 + 1.0, CELLS - 1.0);
	float fb = b - b0;

	// Red/green position inside one 16×16 tile (texel-centered to avoid bleeding).
	float u_red = (col.r * (CELLS - 1.0) + 0.5) / TEX_W;
	float v_grn = (col.g * (CELLS - 1.0) + 0.5) / CELLS;

	vec3 s0 = texture(lut, vec2(u_red + b0 / CELLS, v_grn)).rgb;
	vec3 s1 = texture(lut, vec2(u_red + b1 / CELLS, v_grn)).rgb;
	return mix(s0, s1, fb);
}

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	vec3 graded = sample_lut(col);
	COLOR = vec4(mix(col, graded, amount), 1.0);
}
