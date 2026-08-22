shader_type canvas_item;

// Custom LitPostEffect pass: screen-wide sepia over the lit frame.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform float strength : hint_range(0.0, 1.0) = 0.7;

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;
	vec3 sepia = vec3(
			dot(col, vec3(0.393, 0.769, 0.189)),
			dot(col, vec3(0.349, 0.686, 0.168)),
			dot(col, vec3(0.272, 0.534, 0.131)));
	COLOR = vec4(mix(col, sepia, strength), 1.0);
}
