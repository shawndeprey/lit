shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float levels = 4.0;       
uniform float scale = 1.0;        
uniform bool monochrome = false;  
uniform float strength = 1.0;     

const float BAYER[16] = {
	 0.0,  8.0,  2.0, 10.0,
	12.0,  4.0, 14.0,  6.0,
	 3.0, 11.0,  1.0,  9.0,
	15.0,  7.0, 13.0,  5.0
};

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;

	vec3 col = original;
	if (monochrome) {
		col = vec3(dot(col, vec3(0.2126, 0.7152, 0.0722)));
	}

	ivec2 p = ivec2(FRAGCOORD.xy / max(scale, 1.0));
	int idx = (p.y % 4) * 4 + (p.x % 4);
	float threshold = BAYER[idx] / 16.0 - 0.5;

	float n = max(levels, 2.0);
	vec3 dithered = col + threshold / (n - 1.0);
	vec3 quant = round(dithered * (n - 1.0)) / (n - 1.0);

	COLOR = vec4(mix(original, quant, strength), 1.0);
}
