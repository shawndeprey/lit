shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float amount = 0.2;     
uniform float zoom = 1.0;       
uniform vec4 edge_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec2 c = SCREEN_UV - 0.5;
	float r2 = dot(c, c);

	vec2 uv = SCREEN_UV + c * r2 * amount;
	uv = (uv - 0.5) / max(zoom, 0.0001) + 0.5;

	vec3 col = edge_color.rgb;
	if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
		col = texture(screen_texture, uv).rgb;
	}
	COLOR = vec4(col, 1.0);
}
