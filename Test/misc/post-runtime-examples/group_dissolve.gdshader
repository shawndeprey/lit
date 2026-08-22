shader_type canvas_item;

// CanvasGroup material: the lit child sprite arrives through screen_texture, already shaded.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform float threshold : hint_range(0.0, 1.0) = 0.4;
uniform float edge_width : hint_range(0.0, 0.2) = 0.06;
uniform vec4 edge_color : source_color = vec4(1.0, 0.55, 0.1, 1.0);
uniform float noise_scale = 10.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
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
	vec4 c = textureLod(screen_texture, SCREEN_UV, 0.0);
	if (c.a > 0.0001) {
		c.rgb /= c.a;
	}
	float n = value_noise(UV * noise_scale);
	float keep = step(threshold, n);
	float edge = keep * step(n, threshold + edge_width);
	c.rgb = mix(c.rgb, edge_color.rgb, edge);
	c.a *= keep;
	COLOR *= c;
}
