shader_type canvas_item;

// OpenGL/Compatibility twin of lit_post_focus.gdshader (the web export path). The
// Compatibility renderer doesn't generate screen-texture mipmaps, so the Forward+
// version's textureLod reference (a mip blur) collapses to one full-res sample. This
// twin replaces it with a compact multi-tap blur (center + two rings x four taps).
// `radius` keeps its mip-level feel: a value of n blurs about 2^n screen pixels.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float amount = -0.5;   // < 0 = soft/dream blur, > 0 = sharpen, 0 = off
uniform float radius = 2.0;    // blur reach: mip feel, ~2^radius pixels
uniform float dream = 0.2;     // soft side only: hazy highlight glow (screen blend)

// Compact gaussian-ish blur at `r_px` pixels: center plus two rings at r and 2r.
// `px` is the screen pixel size (SCREEN_PIXEL_SIZE is only legal inside fragment()).
vec3 blur_at(vec2 uv, float r_px, vec2 px) {
	float r = max(r_px, 0.5) * px.x;
	vec3 acc = texture(screen_texture, uv).rgb;
	float w = 1.0;
	acc += texture(screen_texture, uv + vec2( r, 0.0)).rgb;
	acc += texture(screen_texture, uv - vec2( r, 0.0)).rgb;
	acc += texture(screen_texture, uv + vec2(0.0,  r)).rgb;
	acc += texture(screen_texture, uv - vec2(0.0,  r)).rgb;
	w += 4.0;
	acc += texture(screen_texture, uv + vec2(2.0 * r, 0.0)).rgb;
	acc += texture(screen_texture, uv - vec2(2.0 * r, 0.0)).rgb;
	acc += texture(screen_texture, uv + vec2(0.0, 2.0 * r)).rgb;
	acc += texture(screen_texture, uv - vec2(0.0, 2.0 * r)).rgb;
	w += 4.0;
	return acc / w;
}

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;
	vec3 blurred = blur_at(SCREEN_UV, exp2(radius), SCREEN_PIXEL_SIZE);

	vec3 col;
	if (amount < 0.0) {
		// Blend toward the blurred image, then screen-blend a little of the blur back in
		// for a dreamy haze.
		col = mix(original, blurred, -amount);
		col = 1.0 - (1.0 - col) * (1.0 - blurred * dream);
	} else {
		// Sharpen (unsharp mask): amplify the difference from the blurred reference.
		col = original + (original - blurred) * amount;
	}

	COLOR = vec4(col, 1.0);
}
