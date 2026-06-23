shader_type canvas_item;

// The animated cousin of CRT: per-line tape wobble, horizontal chroma shift and
// smear, a rolling tracking-noise band, static grain, and a slow brightness roll,
// all driven by TIME. VHS is the tape signal and CRT is the glass, so the chain runs
// VHS before CRT; enable both for a worn tape on an old tube.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float wobble_strength = 2.0;   // per-line horizontal jitter, in pixels
uniform float wobble_speed = 4.0;      // how fast the jitter reshuffles
uniform float chroma_shift = 2.0;      // R/B horizontal split, in pixels
uniform float bleed = 0.5;             // horizontal chroma smear (0 = crisp)
uniform float grain = 0.12;            // animated static-noise overlay
uniform float tracking_strength = 0.6; // severity of the rolling damaged band
uniform float tracking_speed = 0.2;    // how fast the band rolls up the screen
uniform float roll_strength = 0.1;     // slow vertical brightness roll

const int BLEED_TAPS = 4;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	float t = TIME;

	// A soft horizontal zone scrolling up the screen where the tape loses sync. It
	// amplifies the displacement, chroma and noise below.
	float band_pos = fract(-t * tracking_speed);
	float band = smoothstep(0.12, 0.0, abs(SCREEN_UV.y - band_pos)) * tracking_strength;

	// Per-line wobble: each scanline shifts as a unit. A quantized random per row and
	// time plus a slow sine drift, amplified inside the band.
	float line_id = floor(SCREEN_UV.y / px.y);
	float jitter = hash21(vec2(line_id, floor(t * wobble_speed * 8.0))) - 0.5;
	float drift = sin(SCREEN_UV.y * 6.0 + t * wobble_speed) * 0.3;
	float shift_px = (jitter * 2.0 + drift) * (wobble_strength + band * 24.0);

	vec2 uv = SCREEN_UV;
	uv.x += shift_px * px.x;

	// Chroma shift: split R/B horizontally (wider inside the band).
	float cs = (chroma_shift + band * 6.0) * px.x;
	vec3 col;
	col.r = texture(screen_texture, uv + vec2(cs, 0.0)).r;
	col.g = texture(screen_texture, uv).g;
	col.b = texture(screen_texture, uv - vec2(cs, 0.0)).b;

	// Chroma smear: blur a few taps leftward (NTSC-ish trailing bleed).
	vec3 smear = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < BLEED_TAPS; i++) {
		float w = 1.0 - float(i) / float(BLEED_TAPS);
		smear += texture(screen_texture, uv - vec2(float(i) * 2.0 * px.x, 0.0)).rgb * w;
		wsum += w;
	}
	smear /= max(wsum, 0.0001);
	col = mix(col, smear, bleed);

	// Animated static grain (heavier in the band), per-pixel per-frame.
	float n = hash21(floor(SCREEN_UV / px) + vec2(fract(t) * 113.0, fract(t) * 57.0));
	col += (n - 0.5) * (grain + band * 0.5);

	// Slow brightness roll of an untracked tape, plus a faint wash inside the band.
	float bar = sin((SCREEN_UV.y + t * 0.1) * TAU);
	col *= 1.0 + roll_strength * bar * 0.5;
	col += band * 0.15;

	COLOR = vec4(col, 1.0);
}
