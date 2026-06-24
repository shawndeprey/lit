shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float dot_size = 6.0;      
uniform float angle = 0.0;         
uniform float amount = 1.0;        
uniform vec4 ink_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 paper_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	float a = radians(angle);
	float c = cos(a);
	float s = sin(a);
	mat2 rot = mat2(vec2(c, s), vec2(-s, c));   
	mat2 inv = mat2(vec2(c, -s), vec2(s, c));    

	vec2 p = SCREEN_UV / SCREEN_PIXEL_SIZE;
	vec2 rp = rot * p;

	vec2 cell_center_r = (floor(rp / dot_size) + 0.5) * dot_size;
	vec2 sample_uv = (inv * cell_center_r) * SCREEN_PIXEL_SIZE;
	float luma = dot(texture(screen_texture, sample_uv).rgb, vec3(0.2126, 0.7152, 0.0722));

	float radius = (1.0 - luma) * dot_size * 0.70710678;
	float d = length(rp - cell_center_r);
	float coverage = smoothstep(radius + 1.0, radius - 1.0, d);   

	vec3 screen = mix(paper_color.rgb, ink_color.rgb, coverage);
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;
	COLOR = vec4(mix(original, screen, amount), 1.0);
}
