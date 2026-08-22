shader_type canvas_item;

// Albedo pre-pass: rendered into a SubViewport whose texture feeds the receiver's diffuse slot.
uniform float hue_shift : hint_range(0.0, 6.2832) = 2.6;

vec3 hue_rotate(vec3 c, float angle) {
	const vec3 k = vec3(0.57735027);
	float cs = cos(angle);
	return c * cs + cross(k, c) * sin(angle) + k * dot(k, c) * (1.0 - cs);
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	COLOR = vec4(hue_rotate(c.rgb, hue_shift), c.a);
}
