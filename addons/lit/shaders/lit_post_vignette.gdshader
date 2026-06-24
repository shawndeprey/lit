shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float strength = 0.4;     
uniform float softness = 0.5;     

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	float dist = distance(SCREEN_UV, vec2(0.5)) * 1.41421356;

	float edge = smoothstep(1.0 - softness, 1.0, dist);
	col *= 1.0 - edge * strength;
	COLOR = vec4(col, 1.0);
}
