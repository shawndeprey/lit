shader_type canvas_item;

// Chromatic aberration post pass (post-v1, to_do_post_processing.md). Radial RGB
// split that grows toward the screen edges (lens fringing): the red and blue
// channels are sampled pushed apart along the direction from screen center, leaving
// the center sharp. Reads the accumulated frame via hint_screen_texture.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float amount = 3.0;        // max R/B split at the corners, in pixels
uniform float edge_falloff = 2.0;  // edge concentration (higher = sharper center)

void fragment() {
	vec2 center = SCREEN_UV - 0.5;

	// Radial weight: 0 at center -> 1 at the corners, shaped by edge_falloff so the
	// center stays clean and the fringe ramps up toward the edges.
	float r = pow(clamp(length(center) * 1.41421356, 0.0, 1.0), edge_falloff);

	// Unit direction out from center (guarded at the exact center).
	vec2 dir = center;
	float len = length(center);
	if (len > 0.0001) {
		dir = center / len;
	}

	// Split offset along the radial direction, scaled to pixels (componentwise px so
	// the distance is correct on non-square aspect ratios).
	vec2 off = dir * r * amount * SCREEN_PIXEL_SIZE;

	vec3 col;
	col.r = texture(screen_texture, SCREEN_UV + off).r;
	col.g = texture(screen_texture, SCREEN_UV).g;
	col.b = texture(screen_texture, SCREEN_UV - off).b;

	COLOR = vec4(col, 1.0);
}
