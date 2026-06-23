shader_type canvas_item;

// Re-prints the frame as a rotated grid of ink dots sized by local brightness (dark
// makes fat dots that merge toward solid, bright makes tiny ones): the comic /
// newsprint look. Ink-on-paper with configurable colors and an `amount` blend back
// to the original. Runs after Edge Outline, so dark ink lines map to near-solid dots
// and survive while the flat fills break into dots.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float dot_size = 6.0;      // grid cell / max dot footprint, in screen pixels
uniform float angle = 0.0;         // screen rotation, in degrees
uniform float amount = 1.0;        // blend between original and the dot screen
uniform vec4 ink_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 paper_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
	float a = radians(angle);
	float c = cos(a);
	float s = sin(a);
	mat2 rot = mat2(vec2(c, s), vec2(-s, c));   // rotate a vector by +a
	mat2 inv = mat2(vec2(c, -s), vec2(s, c));    // transpose = inverse rotation

	// Work in screen pixels so dot_size and the AA are in pixel units.
	vec2 p = SCREEN_UV / SCREEN_PIXEL_SIZE;
	vec2 rp = rot * p;

	// Cell center in rotated space, then unrotated back to sample the source there so
	// every fragment in a cell shares one dot driven by that cell's brightness.
	vec2 cell_center_r = (floor(rp / dot_size) + 0.5) * dot_size;
	vec2 sample_uv = (inv * cell_center_r) * SCREEN_PIXEL_SIZE;
	float luma = dot(texture(screen_texture, sample_uv).rgb, vec3(0.2126, 0.7152, 0.0722));

	// Darker means a bigger dot. Max radius reaches the cell corner (0.5 * sqrt(2)).
	float radius = (1.0 - luma) * dot_size * 0.70710678;
	float d = length(rp - cell_center_r);
	float coverage = smoothstep(radius + 1.0, radius - 1.0, d);   // 1px AA

	vec3 screen = mix(paper_color.rgb, ink_color.rgb, coverage);
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;
	COLOR = vec4(mix(original, screen, amount), 1.0);
}
