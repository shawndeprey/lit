shader_type canvas_item;

// Child drawn over the receiver: reads the lit pixel back and re-tints it in sprite UV space.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform vec4 frost_color : source_color = vec4(0.55, 0.8, 1.0, 1.0);
uniform float amount : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	float a = texture(TEXTURE, UV).a;
	vec3 lit = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	float line = 1.0 - amount;
	float mask = smoothstep(line, line + 0.15, UV.y);
	vec3 frosted = lit * frost_color.rgb + frost_color.rgb * 0.15;
	COLOR = vec4(mix(lit, frosted, mask), a);
}
