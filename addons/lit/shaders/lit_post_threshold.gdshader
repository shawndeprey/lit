shader_type canvas_item;

// Threshold post pass (plan §7.5 / D8). A luminance gate: pixels whose brightness
// is below `cutoff` fade to black over a short soft knee; brighter pixels pass
// through. A stylized high-contrast / "only the lit parts show" look that pairs
// with the darkness of the lighting system. LDR; reads the frame so far.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float cutoff = 0.5;       // luma below this is crushed toward black
const float KNEE = 0.05;          // soft-edge half-width around the cutoff

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));   // Rec. 709 luma
	float gate = smoothstep(cutoff - KNEE, cutoff + KNEE, luma);
	COLOR = vec4(col * gate, 1.0);
}
