shader_type canvas_item;

// Color grade post pass (plan §7.5 / D8). Reads the screen via hint_screen_texture
// and applies exposure -> contrast -> saturation -> tint. LDR; the output clamps
// at display. One fullscreen ColorRect drives this over the whole frame.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float exposure = 1.0;     // linear multiply
uniform float contrast = 1.0;     // 1 = identity, around mid-grey
uniform float saturation = 1.0;   // 0 = greyscale, 1 = identity, >1 = punchier
uniform vec4 tint : source_color = vec4(1.0);

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	col *= exposure;
	col = (col - 0.5) * contrast + 0.5;
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));   // Rec. 709 luma
	col = mix(vec3(luma), col, saturation);
	col *= tint.rgb;

	COLOR = vec4(col, 1.0);
}
