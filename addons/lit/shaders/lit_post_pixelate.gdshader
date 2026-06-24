shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float pixel_size = 4.0;   

void fragment() {

	vec2 cell = max(pixel_size, 1.0) * SCREEN_PIXEL_SIZE;
	vec2 uv = (floor(SCREEN_UV / cell) + 0.5) * cell;

	COLOR = vec4(texture(screen_texture, uv).rgb, 1.0);
}
