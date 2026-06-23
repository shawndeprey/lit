shader_type canvas_item;

// Lens distortion post pass (post-v1, to_do_post_processing.md). Radial barrel /
// pincushion warp: positive `amount` bulges (fisheye), negative pinches (the subtle
// correction look). `zoom` scales around center to push the warped edges back off
// screen so you don't see the bezel. Reads the frame so far via hint_screen_texture.
//
// This is the device lens; it's distinct from CRT's own curvature (you can stack
// both, or zero one and use the other).
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float amount = 0.2;     // + = barrel/bulge, - = pincushion/pinch
uniform float zoom = 1.0;       // scale around center (>1 hides the warped edges)
uniform vec4 edge_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec2 c = SCREEN_UV - 0.5;
	float r2 = dot(c, c);

	// Radial distortion, then zoom around center.
	vec2 uv = SCREEN_UV + c * r2 * amount;
	uv = (uv - 0.5) / max(zoom, 0.0001) + 0.5;

	// Sample inside the frame; the warped-away corners read as the bezel color.
	vec3 col = edge_color.rgb;
	if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
		col = texture(screen_texture, uv).rgb;
	}
	COLOR = vec4(col, 1.0);
}
