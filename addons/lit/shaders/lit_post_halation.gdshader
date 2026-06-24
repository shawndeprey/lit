shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float threshold = 0.6;            
uniform float intensity = 0.6;            
uniform float halation_radius = 5.0;      
uniform vec4 tint : source_color = vec4(1.0, 0.25, 0.1, 1.0);  

const int LEVELS = 5;
const float KNEE = 0.1;                    

float bright_luma(vec3 c) {
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));   
	return luma * smoothstep(threshold - KNEE, threshold + KNEE, luma);
}

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;

	float halo = 0.0;
	float weight_sum = 0.0;
	for (int i = 0; i < LEVELS; i++) {
		float lod = (float(i) + 1.0) * (halation_radius * 0.2);
		vec3 sample_col = textureLod(screen_texture, SCREEN_UV, lod).rgb;
		float w = 1.0 / (float(i) + 1.0);    
		halo += bright_luma(sample_col) * w;
		weight_sum += w;
	}
	halo /= max(weight_sum, 0.0001);

	vec3 glow = tint.rgb * halo * intensity;
	COLOR = vec4(original + glow, 1.0);
}
