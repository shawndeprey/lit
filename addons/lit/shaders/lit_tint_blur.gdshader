shader_type canvas_item;
render_mode unshaded;

// Separable Gaussian blur for the tint buffer. Run TWICE — once horizontally, once
// vertically — to dilate each translucent stamp into a soft patch before the beam pass
// samples it. This is the fix for the "stamped gems with gaps" artifact: a sparse march
// (beam_steps samples across the screen) reliably MISSES a small gem's silhouette, hitting
// it at only a few ray fractions and echoing its shape at intervals. Blurring the buffer
// makes each gem a smooth blob several pixels wide, so the march catches it continuously and
// the shaft reads as a soft volumetric haze instead of cloned outlines.
//
// The buffer is PREMULTIPLIED ADDITIVE (rgb = tint*density, a = density). A Gaussian is a
// weighted average, and because both rgb and a are blurred with the SAME weights the
// premultiplied invariant is preserved: a reader still recovers tint as rgb/a afterward. So
// we can blur the raw channels directly with no un-premultiply/re-premultiply dance.

uniform sampler2D source_tex : hint_default_black, filter_linear;

// Blur direction in TEXEL space, set by the caller: (1,0) for the horizontal pass,
// (0,1) for the vertical pass. Magnitude lets a caller widen the kernel without editing
// the shader, but 1.0 per tap is the normal setting.
uniform vec2 blur_dir = vec2(1.0, 0.0);

// Texel size (1/buffer_size) so the tap offsets are resolution-independent. Pushed by the
// blur node each frame from the buffer's pixel dimensions.
uniform vec2 texel_size = vec2(0.000868055, 0.001543210);

// Kernel reach in taps each side of centre. The effective blur radius in pixels is
// radius * spread. Bigger radius = wider, smoother shafts but more texture fetches.
uniform int radius : hint_range(1, 16) = 6;

// Spacing between taps in texels. >1 widens the blur cheaply (taps skip texels) at the cost
// of some smoothness; linear filtering hides most of the gaps. Effective radius scales with
// this, so it's the main "how far does a gem bleed" knob.
uniform float spread : hint_range(0.5, 8.0) = 2.0;

void fragment() {
	vec2 step = blur_dir * texel_size * spread;

	// Gaussian weights computed inline so radius/spread stay live-tweakable. sigma tied to
	// radius keeps the kernel well-shaped (tails ~0) as radius changes. Centre tap first.
	float sigma = max(float(radius) * 0.5, 0.5);
	float two_sigma_sq = 2.0 * sigma * sigma;

	vec4 sum = texture(source_tex, UV);
	float weight_total = 1.0;

	// Symmetric taps. Loop to a fixed cap (16) and break at the live radius so the loop is
	// statically bounded for the compiler, like the beam march does.
	for (int i = 1; i <= 16; i++) {
		if (i > radius) {
			break;
		}
		float fi = float(i);
		float w = exp(-(fi * fi) / two_sigma_sq);
		sum += texture(source_tex, UV + step * fi) * w;
		sum += texture(source_tex, UV - step * fi) * w;
		weight_total += 2.0 * w;
	}

	COLOR = sum / weight_total;
}
