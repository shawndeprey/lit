shader_type canvas_item;

uniform float intensity = 0.4;
uniform vec4  fog_color : source_color = vec4(0.62, 0.67, 0.78, 1.0);
uniform float pixel_size = 3.0;
uniform float drift_speed = 1.0;   // multiplier on movement

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float noise(vec2 p){
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 cells = res / pixel_size;
	vec2 uv = floor(SCREEN_UV * cells) / cells;

	float t = TIME * drift_speed;
	// Two layers scrolling at different speeds = parallax mist
	float n = noise(uv * 4.0 + vec2(t * 0.18, t * 0.06));
	n = n * 0.5 + noise(uv * 8.0 - vec2(t * 0.11, t * 0.04)) * 0.5;

	COLOR.rgb = fog_color.rgb;
	COLOR.a = smoothstep(0.35, 0.85, n) * intensity * 0.55;
}
