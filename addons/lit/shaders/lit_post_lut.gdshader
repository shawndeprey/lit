shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform sampler2D lut : filter_linear, repeat_disable;
uniform float amount : hint_range(0.0, 1.0) = 1.0;

const float CELLS = 16.0;            
const float TEX_W = CELLS * CELLS;   

vec3 sample_lut(vec3 col) {
	col = clamp(col, 0.0, 1.0);

	float b = col.b * (CELLS - 1.0);
	float b0 = floor(b);
	float b1 = min(b0 + 1.0, CELLS - 1.0);
	float fb = b - b0;

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
