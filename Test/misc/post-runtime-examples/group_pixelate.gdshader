shader_type canvas_item;

// CanvasGroup material: resamples the lit child sprite in screen-space blocks.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float block_size = 12.0;

void fragment() {
	vec2 block = SCREEN_PIXEL_SIZE * block_size;
	vec2 uv = (floor(SCREEN_UV / block) + 0.5) * block;
	vec4 c = textureLod(screen_texture, uv, 0.0);
	if (c.a > 0.0001) {
		c.rgb /= c.a;
	}
	COLOR *= c;
}
