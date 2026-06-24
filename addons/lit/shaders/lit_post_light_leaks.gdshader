shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float intensity = 0.6;
uniform float speed = 1.0;
uniform vec4 color1 : source_color = vec4(1.0, 0.5, 0.2, 1.0);   
uniform vec4 color2 : source_color = vec4(1.0, 0.2, 0.3, 1.0);   

uniform bool has_texture = false;
uniform sampler2D leak_texture : source_color, hint_default_black;

float blob(vec2 uv, vec2 center, float radius) {
	return smoothstep(radius, 0.0, distance(uv, center));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float t = TIME * speed;

	vec3 leak;
	if (has_texture) {
		leak = texture(leak_texture, uv + vec2(t * 0.05, t * 0.02)).rgb;
	} else {

		float l1 = blob(uv, vec2(1.05, 0.3 + 0.2 * sin(t)), 0.7) * (0.6 + 0.4 * sin(t * 1.3));
		float l2 = blob(uv, vec2(-0.05, 0.7 + 0.15 * cos(t * 0.7)), 0.6) * (0.6 + 0.4 * sin(t * 0.9 + 1.0));
		float l3 = blob(uv, vec2(0.5 + 0.3 * sin(t * 0.5), -0.05), 0.5) * (0.6 + 0.4 * sin(t * 1.7 + 2.0));
		leak = color1.rgb * (l1 + 0.5 * l3) + color2.rgb * l2;
	}
	leak = clamp(leak * intensity, 0.0, 1.0);

	vec3 base = texture(screen_texture, SCREEN_UV).rgb;

	vec3 outc = 1.0 - (1.0 - base) * (1.0 - leak);
	COLOR = vec4(outc, 1.0);
}
