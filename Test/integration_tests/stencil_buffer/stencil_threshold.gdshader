shader_type canvas_item;

// Full-screen rect drawn over the stencil floor: pixels any light reaches become white, the rest black.
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform float threshold : hint_range(0.0, 1.0) = 0.01;
global uniform vec4 lit_ambient_color : source_color;
global uniform float lit_ambient_energy;

void fragment() {
	vec3 lit = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	vec3 ambient = lit_ambient_color.rgb * lit_ambient_energy;
	float light = max(lit.r, max(lit.g, lit.b)) - max(ambient.r, max(ambient.g, ambient.b));
	COLOR = vec4(vec3(step(threshold, light)), 1.0);
}
