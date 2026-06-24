shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float threshold = 0.7;
uniform float intensity = 0.5;
uniform float bloom_radius = 4.0;   

const int LEVELS = 5;
const float KNEE = 0.1;             

vec3 bright_pass(vec3 c) {
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));   
	float soft = smoothstep(threshold - KNEE, threshold + KNEE, luma);
	return c * soft;
}

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;

	vec3 bloom = vec3(0.0);
	float weight_sum = 0.0;
	for (int i = 0; i < LEVELS; i++) {
		float lod = (float(i) + 1.0) * (bloom_radius * 0.2);
		vec3 sample_col = textureLod(screen_texture, SCREEN_UV, lod).rgb;
		float w = 1.0 / (float(i) + 1.0);    
		bloom += bright_pass(sample_col) * w;
		weight_sum += w;
	}
	bloom /= max(weight_sum, 0.0001);

	COLOR = vec4(original + bloom * intensity, 1.0);
}
