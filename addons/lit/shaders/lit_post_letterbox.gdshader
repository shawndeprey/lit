shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float bar_size = 0.0;     
uniform float softness = 0.0;     
uniform vec4 bar_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	float edge_dist = min(SCREEN_UV.y, 1.0 - SCREEN_UV.y);

	float bar = 1.0 - smoothstep(bar_size, bar_size + max(softness, 0.0001), edge_dist);

	col = mix(col, bar_color.rgb, bar * bar_color.a);
	COLOR = vec4(col, 1.0);
}
