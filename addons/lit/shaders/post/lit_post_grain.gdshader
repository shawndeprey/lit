shader_type canvas_item;

// Animated monochrome (or colored) noise over the frame, optionally fading in the
// shadows and highlights so it sits in the midtones like real film stock. Driven by
// TIME. Runs late in the chain, on the final image.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float intensity = 0.05;          // grain amount
uniform float grain_size = 1.0;          // grain cell size in pixels (bigger = chunkier)
uniform float luminance_response = 0.5;  // 0 = uniform, 1 = fades hard at black/white
uniform bool colored = false;            // false = mono film grain, true = RGB sparkle

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	// Grain cell: quantize pixels into grain_size buckets so grain can be chunkier
	// than one pixel. Re-seeded each frame (fract(TIME)) so the pattern animates.
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

	// Real grain is least visible in deep shadows and blown highlights. 4*l*(1-l)
	// peaks at mid-grey; mix toward uniform as response approaches 0.
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	float lum_mask = mix(1.0, 4.0 * luma * (1.0 - luma), luminance_response);

	col += noise * intensity * lum_mask;

	COLOR = vec4(col, 1.0);
}
