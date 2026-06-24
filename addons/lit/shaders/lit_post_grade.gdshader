shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float exposure = 1.0;     
uniform float contrast = 1.0;     
uniform float saturation = 1.0;   
uniform vec4 tint : source_color = vec4(1.0);

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	col *= exposure;
	col = (col - 0.5) * contrast + 0.5;
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));   
	col = mix(vec3(luma), col, saturation);
	col *= tint.rgb;

	COLOR = vec4(col, 1.0);
}
