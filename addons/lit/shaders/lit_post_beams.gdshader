shader_type canvas_item;

// Volumetric colour beams (Tier 2): visible shafts of light that take on the colour of the
// translucent objects they pass through. This is the "see the coloured beam crossing the
// room" half of the stained-glass feature; the surface/shadow tint half lives in the
// receiver shader. Both read the same lit_tint_buffer, so a beam and the floor it lands on
// agree on colour for free.
//
// Method: for each screen pixel, march from the pixel toward each light. At every step,
// sample the tint buffer and (a) accumulate how much tinted matter the ray has crossed so
// the beam GLOWS where light filters through glass, and (b) multiply a running tint so the
// shaft downstream of a red pane is red, and downstream of red THEN blue is purple. Add the
// resulting glow over the already-rendered frame.
//
// This is a screen-space approximation, not physically calibrated — there is no real fog
// volume, the "glow" is the tint buffer's density acting as stand-in participating media.
// It reads because the colour follows the authored glass exactly and lines up with the
// surface tint the receiver computes along the same logic.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

// The shared screen-space tint buffer, PREMULTIPLIED ADDITIVE: rgb = tint*density and a =
// density, summed over every translucent pane on a texel (published as a global by
// LitTintBuffer). Same buffer the receiver samples — declared the same way (source_color,
// linear filter). A reader recovers the tint as rgb/a and reads density from a.
global uniform sampler2D lit_tint_buffer : source_color, filter_linear, hint_default_black;

// Pre-blurred copy of the tint buffer, same premultiplied-additive convention, published by
// LitTintBuffer's blur passes. The beam march samples THIS instead of the sharp buffer: a
// sparse march steps over a small gem in the sharp buffer and echoes its outline at intervals
// ("stamped gems with gaps"), whereas the Gaussian-dilated copy is continuous under the same
// sampling, so the shaft reads as smooth haze. The receiver still uses the SHARP lit_tint_buffer
// for surface tint, keeping floor/shadow colour pinned to the gem's exact shape — softness
// belongs only to the volumetric shafts. Falls back to the sharp buffer when blur is disabled.
global uniform sampler2D lit_tint_buffer_blurred : source_color, filter_linear, hint_default_black;

// Compact light set pushed by LitTintBeams each frame. Post shaders don't get the packed
// light-data texture, so we pass just what a beam needs: screen-UV position (or direction
// for a directional), colour*energy, and a type flag. Capped small; beams are a hero
// effect, not something you run on 128 lights.
const int LIT_MAX_BEAM_LIGHTS = 8;
uniform int beam_light_count = 0;
uniform vec2 beam_light_uv[LIT_MAX_BEAM_LIGHTS];     // point/spot: screen-UV pos; directional: unit dir
uniform vec3 beam_light_color[LIT_MAX_BEAM_LIGHTS];  // colour premultiplied by energy
uniform int  beam_light_type[LIT_MAX_BEAM_LIGHTS];   // 0 = point/spot, 1 = directional

// How many steps to march from each pixel toward each light. More = smoother shafts, more
// cost. 24–48 reads well for a few lights.
uniform int beam_steps : hint_range(4, 96) = 32;

// Overall brightness of the shafts added onto the frame. The effect is additive, so keep
// modest; crank for heavy "dust in a cathedral" looks.
uniform float beam_intensity : hint_range(0.0, 4.0) = 0.6;

// How far a directional beam reaches across the screen, in UV (1 = one screen). Point/spot
// beams march to the light's actual position so they ignore this.
uniform float beam_directional_reach : hint_range(0.1, 2.0) = 1.0;

// Density floor: tint-buffer density below this contributes no glow, so faint stamping and
// buffer noise don't haze the whole screen.
uniform float beam_density_threshold : hint_range(0.0, 0.5) = 0.02;

// How saturated the shaft colour is. 1 = full glass hue (vivid, gel-like). Lower values mix
// the shaft toward its own brightness, so it reads as pale scattered light rather than a
// coloured filter — which is how real shafts look, since the glow is light in the air, not
// the glass surface. ~0.5–0.7 gives a tinted-but-airy beam.
uniform float beam_saturation : hint_range(0.0, 1.0) = 0.6;

void fragment() {
	vec3 frame = texture(screen_texture, SCREEN_UV).rgb;
	vec3 glow = vec3(0.0);

	for (int li = 0; li < LIT_MAX_BEAM_LIGHTS; li++) {
		if (li >= beam_light_count) {
			break;
		}

		// March endpoint in screen-UV. For a point/spot, that's the light's screen position;
		// for a directional, step a fixed reach along its incoming direction.
		vec2 start = SCREEN_UV;
		vec2 target;
		if (beam_light_type[li] == 1) {
			target = SCREEN_UV + normalize(beam_light_uv[li]) * beam_directional_reach;
		} else {
			target = beam_light_uv[li];
		}

		vec2 ray = target - start;
		float steps_f = float(beam_steps);

		// Running tint the beam has picked up so far (starts clear) and accumulated glow for
		// THIS light. We walk from the pixel toward the light; tint encountered near the pixel
		// colours everything between it and the light, matching how the surface tint works.
		vec3 tint = vec3(1.0);
		float accum = 0.0;

		for (int s = 0; s < 96; s++) {
			if (s >= beam_steps) {
				break;
			}
			// Sample partway along the ray. (s+0.5)/steps centres each sample in its segment.
			float t = (float(s) + 0.5) / steps_f;
			vec2 p = start + ray * t;

			// Outside the screen there's no buffer data; stop this beam.
			if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) {
				break;
			}

			vec4 tb = texture(lit_tint_buffer_blurred, p);
			// Buffer is PREMULTIPLIED ADDITIVE: a = summed density, rgb = summed tint*density.
			// Skip clear/unset texels (a<=0) — also guards the divide below.
			float d = tb.a;
			if (d > beam_density_threshold) {
				// tb.rgb/d is the density-weighted AVERAGE hue of the panes on this texel.
				// Averaging pulls overlap centres toward grey; stained glass should MULTIPLY and
				// deepen. So apply the average hue once PER unit of density via pow: one pane tints
				// once, two stacked panes tint twice (hue multiplies in again, re-saturating toward
				// the product). Matches the receiver so a shaft and the surface it lands on agree.
				vec3 avg_tint = tb.rgb / d;
				float layers = clamp(d, 0.0, 4.0);
				tint *= pow(avg_tint, vec3(layers));
				// The beam GLOWS where it passes through tinted matter: density is the stand-in
				// for light scattering off the medium. Weighted by how much of the ray remains
				// so glow nearer the light reads slightly stronger.
				accum += d * (1.0 - t);
			}
		}

		// Normalise the accumulated density by step count so it reads as an AVERAGE coverage
		// along the ray, not a raw sum. Without this, accum grew with beam_steps and with ray
		// length, so more steps or a farther light made the shaft brighter — backwards. Saturate
		// to [0,1]: this is now "how much of this beam is tinted glass", a bounded coverage
		// factor, not an unbounded energy.
		float coverage = clamp(accum / steps_f, 0.0, 1.0);

		// The shaft colour is the light's colour carried through the accumulated tint, scaled by
		// bounded coverage instead of the raw sum, so a fully-glassed beam reaches the light's
		// colour and no further.
		vec3 shaft = beam_light_color[li] * tint * coverage;

		// Desaturate toward the shaft's own brightness so it reads as pale scattered light, not
		// a coloured gel. Preserves intensity (luma is energy-weighted) while pulling hue out.
		float luma = dot(shaft, vec3(0.2126, 0.7152, 0.0722));
		shaft = mix(vec3(luma), shaft, beam_saturation);

		glow += shaft;
	}

	glow *= beam_intensity / max(float(beam_light_count), 1.0);

	// Screen blend rather than straight add: beams brighten toward white where they pile up but
	// can't push a channel past 1, so overlapping shafts stop turning into opaque blobs. Still
	// only ever lightens the frame. Clamp glow first so a hot light can't invert the screen op.
	glow = clamp(glow, 0.0, 1.0);
	vec3 result = 1.0 - (1.0 - frame) * (1.0 - glow);
	COLOR = vec4(result, 1.0);
}
