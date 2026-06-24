shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float curvature = 0.2;          
uniform float scanline_strength = 0.3;  
uniform float scanline_count = 240.0;   
uniform float mask_strength = 0.3;      
uniform float aberration = 1.5;         
uniform float vignette = 0.3;           
uniform float brightness = 1.2;         

vec2 barrel(vec2 uv, float amt) {
	vec2 cc = uv - 0.5;
	float r2 = dot(cc, cc);
	return uv + cc * r2 * amt;
}

void fragment() {
	vec2 uv = barrel(SCREEN_UV, curvature);

	vec3 col = vec3(0.0);
	if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {

		vec2 center = uv - 0.5;
		vec2 ab_off = center * aberration * SCREEN_PIXEL_SIZE * 2.0;
		col.r = texture(screen_texture, uv - ab_off).r;
		col.g = texture(screen_texture, uv).g;
		col.b = texture(screen_texture, uv + ab_off).b;

		float line = 0.5 + 0.5 * sin(uv.y * scanline_count * TAU);
		col *= mix(1.0, line, scanline_strength);

		int m = int(mod(FRAGCOORD.x, 3.0));
		vec3 mask = vec3(1.0 - mask_strength);
		if (m == 0) {
			mask.r = 1.0;
		} else if (m == 1) {
			mask.g = 1.0;
		} else {
			mask.b = 1.0;
		}
		col *= mask;

		float d = distance(uv, vec2(0.5)) * 1.41421356;
		col *= 1.0 - vignette * smoothstep(0.5, 1.0, d);
		col *= brightness;
	}

	COLOR = vec4(col, 1.0);
}
