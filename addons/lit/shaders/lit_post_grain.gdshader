shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float intensity = 0.05;          
uniform float grain_size = 1.0;          
uniform float luminance_response = 0.5;  
uniform bool colored = false;            

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	vec2 cell = floor(SCREEN_UV / SCREEN_PIXEL_SIZE / max(grain_size, 1.0));
	float frame = fract(TIME) * 311.0;

	vec3 noise;
	if (colored) {
		noise = vec3(
			hash21(cell + vec2(frame, 0.0)),
			hash21(cell + vec2(0.0, frame)),
			hash21(cell + vec2(frame, frame))
		) - 0.5;
	} else {
		noise = vec3(hash21(cell + vec2(frame, frame)) - 0.5);
	}

	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	float lum_mask = mix(1.0, 4.0 * luma * (1.0 - luma), luminance_response);

	col += noise * intensity * lum_mask;

	COLOR = vec4(col, 1.0);
}
