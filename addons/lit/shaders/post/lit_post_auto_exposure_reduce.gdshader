shader_type canvas_item;

// Downsamples the previous presented frame to log2-luminance texels for the adapt
// pass's histogram; 4x4 spread taps per texel.
uniform sampler2D source_tex : hint_default_black, filter_linear;

const float EV_MIN = -12.0;
const float EV_MAX = 0.0;

void fragment() {
	float lum = 0.0;
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			vec2 off = ((vec2(float(i), float(j)) + 0.5) / 4.0 - 0.5) * SCREEN_PIXEL_SIZE;
			vec3 c = texture(source_tex, SCREEN_UV + off).rgb;
			lum += dot(pow(max(c, vec3(0.0)), vec3(2.2)), vec3(0.2126, 0.7152, 0.0722));
		}
	}
	float ev = log2(max(lum / 16.0, exp2(EV_MIN)));
	COLOR = vec4(clamp((ev - EV_MIN) / (EV_MAX - EV_MIN), 0.0, 1.0), 0.0, 0.0, 1.0);
}
