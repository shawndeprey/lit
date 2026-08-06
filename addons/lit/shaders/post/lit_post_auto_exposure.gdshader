shader_type canvas_item;

// White-pinned exposure curve, 1 - (1 - c)^gain: shadows scale with gain, white
// stays pinned, gain 1 is exact identity. EV comes from pixel 0 of the state texture.
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform sampler2D exposure_tex : hint_default_black, filter_nearest;

uniform float amount : hint_range(0.0, 1.0) = 1.0;
uniform bool show_meter = false;

const float GEV = 6.0;             // must match the adapt shader's encoding range

void fragment() {
	vec4 e = texelFetch(exposure_tex, ivec2(0), 0);
	float ev = e.b > 0.5 ? (e.r * 255.0 * 256.0 + e.g * 255.0) / 65535.0 * 2.0 * GEV - GEV : 0.0;
	float applied_ev = ev * amount;
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	vec3 outc = 1.0 - pow(max(1.0 - col, vec3(0.0)), vec3(exp2(applied_ev)));

	// debug bar: applied EV over [-4, +4], filled from the center tick
	if (show_meter) {
		vec2 t = (SCREEN_UV - vec2(0.035, 0.045)) / vec2(0.30, 0.022);
		if (all(greaterThanEqual(t, vec2(0.0))) && all(lessThanEqual(t, vec2(1.0)))) {
			float ev_t = clamp(applied_ev / 8.0 + 0.5, 0.0, 1.0);
			vec3 bar = vec3(0.07);
			if (abs(t.x - 0.5) <= abs(ev_t - 0.5) && (t.x - 0.5) * (ev_t - 0.5) >= 0.0) {
				bar = applied_ev < 0.0 ? vec3(0.9, 0.45, 0.1) : vec3(0.25, 0.6, 0.95);
			}
			if (abs(t.x - 0.5) < 0.005) {
				bar = vec3(0.5);
			}
			if (abs(t.x - ev_t) < 0.007) {
				bar = vec3(1.0);
			}
			outc = mix(outc, bar, 0.85);
		}
	}
	COLOR = vec4(outc, 1.0);
}
