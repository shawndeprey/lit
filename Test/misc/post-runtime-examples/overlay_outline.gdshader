shader_type canvas_item;

// Unlit overlay drawn behind the receiver: an outline from the texture's alpha neighbours.
uniform vec4 outline_color : source_color = vec4(1.0, 0.85, 0.2, 1.0);
uniform float width = 1.0;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * width;
	float a = texture(TEXTURE, UV).a;
	float n = texture(TEXTURE, UV + vec2(px.x, 0.0)).a
			+ texture(TEXTURE, UV - vec2(px.x, 0.0)).a
			+ texture(TEXTURE, UV + vec2(0.0, px.y)).a
			+ texture(TEXTURE, UV - vec2(0.0, px.y)).a;
	float rim = clamp(n, 0.0, 1.0) * (1.0 - a);
	COLOR = vec4(outline_color.rgb, outline_color.a * rim);
}
