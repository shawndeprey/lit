shader_type canvas_item;

// Letterbox post pass (post-v1, to_do_post_processing.md). Draws cinematic bars over
// the top and bottom of the frame. Animate `bar_size` from 0 to ease the bars in/out
// for cutscenes. Runs last in the chain so the bars stay clean (no grain/vignette
// drawn over them). Reads the frame so far via hint_screen_texture.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float bar_size = 0.0;     // fraction of screen height covered by EACH bar (0–0.5)
uniform float softness = 0.0;     // feathered inner edge, in height fraction
uniform vec4 bar_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	// Distance from the nearest horizontal edge: 0 at top/bottom, 0.5 at center.
	float edge_dist = min(SCREEN_UV.y, 1.0 - SCREEN_UV.y);

	// 1 inside a bar, 0 in the open frame, with a soft inner edge over `softness`.
	float bar = 1.0 - smoothstep(bar_size, bar_size + max(softness, 0.0001), edge_dist);

	col = mix(col, bar_color.rgb, bar * bar_color.a);
	COLOR = vec4(col, 1.0);
}
