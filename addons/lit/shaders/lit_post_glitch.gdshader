shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float intensity = 0.5;     
uniform float block_size = 12.0;   
uniform float rgb_shift = 4.0;     
uniform float speed = 8.0;         

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	float gt = floor(TIME * speed);                 

	float block = floor(SCREEN_UV.y / (max(block_size, 1.0) * px.y));
	float rnd = hash21(vec2(block, gt));
	float active = step(1.0 - intensity, rnd);

	float shift = (hash21(vec2(block, gt + 7.0)) - 0.5) * 2.0;
	vec2 uv = SCREEN_UV;
	uv.x += active * shift * intensity * 0.1;

	float ymosh = hash21(vec2(block, gt + 13.0)) - 0.5;
	uv.y += active * step(0.7, hash21(vec2(block, gt + 3.0))) * ymosh * 0.05;

	float chroma = rgb_shift * px.x * (0.3 + active);
	vec3 col;
	col.r = texture(screen_texture, uv + vec2(chroma, 0.0)).r;
	col.g = texture(screen_texture, uv).g;
	col.b = texture(screen_texture, uv - vec2(chroma, 0.0)).b;

	float flick = step(0.95, hash21(vec2(block, gt + 21.0))) * active;
	col += flick * 0.2;

	COLOR = vec4(col, 1.0);
}
