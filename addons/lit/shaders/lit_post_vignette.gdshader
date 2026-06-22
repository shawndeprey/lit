shader_type canvas_item;

// Vignette post pass (plan §7.5 / D8). Darkens the frame toward its edges/corners
// based on distance from screen center. `strength` sets how dark the edges get,
// `softness` how gradual the falloff. Cheap UV-space vignette (elliptical on
// non-square aspect ratios, the usual 2D look). Reads the frame so far.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float strength = 0.4;     // 0 = none, 1 = corners to black
uniform float softness = 0.5;     // 0 = tight to the corners, 1 = ramp from center

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	// Distance from center, normalized so the corners sit at ~1.0.
	float dist = distance(SCREEN_UV, vec2(0.5)) * 1.41421356;
	// 0 in the safe center, ramps to 1 toward the corners; softness widens the ramp.
	float edge = smoothstep(1.0 - softness, 1.0, dist);
	col *= 1.0 - edge * strength;
	COLOR = vec4(col, 1.0);
}
