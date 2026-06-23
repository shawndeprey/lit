shader_type canvas_item;

// A 3x3 Sobel operator on screen luminance, inked where the gradient exceeds a
// threshold (the cel/comic look). Edges are detected on luma, so two colors at the
// same brightness won't produce a line, which is the usual tradeoff for game art.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float thickness = 1.0;     // Sobel tap spacing, in pixels (wider = thicker)
uniform float threshold = 0.1;     // edge magnitude needed to start inking
uniform float softness = 0.1;      // anti-alias knee above the threshold
uniform float strength = 1.0;      // outline opacity (multiplies outline_color.a)

float luma_at(vec2 uv) {
	return dot(texture(screen_texture, uv).rgb, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec2 o = thickness * SCREEN_PIXEL_SIZE;

	// 3x3 luma neighborhood.
	float tl = luma_at(SCREEN_UV + vec2(-o.x,  o.y));
	float tc = luma_at(SCREEN_UV + vec2( 0.0,  o.y));
	float tr = luma_at(SCREEN_UV + vec2( o.x,  o.y));
	float ml = luma_at(SCREEN_UV + vec2(-o.x,  0.0));
	float mr = luma_at(SCREEN_UV + vec2( o.x,  0.0));
	float bl = luma_at(SCREEN_UV + vec2(-o.x, -o.y));
	float bc = luma_at(SCREEN_UV + vec2( 0.0, -o.y));
	float br = luma_at(SCREEN_UV + vec2( o.x, -o.y));

	// Sobel gradients (sign is irrelevant, we take the magnitude).
	float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
	float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
	float mag = length(vec2(gx, gy));

	float edge = smoothstep(threshold, threshold + softness, mag);

	vec3 base = texture(screen_texture, SCREEN_UV).rgb;
	vec3 col = mix(base, outline_color.rgb, edge * strength * outline_color.a);

	COLOR = vec4(col, 1.0);
}
