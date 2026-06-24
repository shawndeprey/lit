shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float amount = 3.0;        
uniform float edge_falloff = 2.0;  

void fragment() {
	vec2 center = SCREEN_UV - 0.5;

	float r = pow(clamp(length(center) * 1.41421356, 0.0, 1.0), edge_falloff);

	vec2 dir = center;
	float len = length(center);
	if (len > 0.0001) {
		dir = center / len;
	}

	vec2 off = dir * r * amount * SCREEN_PIXEL_SIZE;

	vec3 col;
	col.r = texture(screen_texture, SCREEN_UV + off).r;
	col.g = texture(screen_texture, SCREEN_UV).g;
	col.b = texture(screen_texture, SCREEN_UV - off).b;

	COLOR = vec4(col, 1.0);
}
