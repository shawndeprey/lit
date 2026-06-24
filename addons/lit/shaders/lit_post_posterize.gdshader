shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float levels = 4.0;     
uniform float strength = 1.0;   

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	float n = max(levels, 2.0);
	vec3 quant = round(col * (n - 1.0)) / (n - 1.0);

	col = mix(col, quant, strength);
	COLOR = vec4(col, 1.0);
}
