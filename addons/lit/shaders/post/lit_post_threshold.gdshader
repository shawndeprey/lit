shader_type canvas_item;

// Luminance gate: pixels below cutoff fade to black through a short soft knee,
// brighter pixels pass through. High-contrast "only the lit parts show" look.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float cutoff = 0.5;       // luma below this is crushed toward black
const float KNEE = 0.05;          // soft-edge half-width around the cutoff

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));   // Rec. 709 luma
	float gate = smoothstep(cutoff - KNEE, cutoff + KNEE, luma);
	COLOR = vec4(col * gate, 1.0);
}
