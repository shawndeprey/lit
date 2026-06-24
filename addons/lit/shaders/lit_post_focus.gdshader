shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float amount = -0.5;   
uniform float radius = 2.0;    
uniform float dream = 0.2;     

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;
	vec3 blurred = textureLod(screen_texture, SCREEN_UV, radius).rgb;

	vec3 col;
	if (amount < 0.0) {

		col = mix(original, blurred, -amount);
		col = 1.0 - (1.0 - col) * (1.0 - blurred * dream);
	} else {

		col = original + (original - blurred) * amount;
	}

	COLOR = vec4(col, 1.0);
}
