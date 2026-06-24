shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float cutoff = 0.5;       
const float KNEE = 0.05;          

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));   
	float gate = smoothstep(cutoff - KNEE, cutoff + KNEE, luma);
	COLOR = vec4(col * gate, 1.0);
}
