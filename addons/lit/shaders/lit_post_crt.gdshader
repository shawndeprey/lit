shader_type canvas_item;

// CRT post pass (post-v1, to_do_post_processing.md). Bundles the classic tube look
// into one fullscreen pass: barrel curvature + scanlines + an RGB aperture/shadow
// mask + edge vignette + a touch of chromatic aberration. Reads the accumulated
// frame via hint_screen_texture. CRT is a STEADY look (no TIME); VHS is the animated
// cousin that adds wobble/noise on top.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float curvature = 0.2;          // barrel warp toward the edges; 0 = flat
uniform float scanline_strength = 0.3;  // 0 = none, 1 = hard black scanlines
uniform float scanline_count = 240.0;   // scanline pairs down the screen (retro = lower)
uniform float mask_strength = 0.3;      // RGB aperture-grille depth; 0 = off
uniform float aberration = 1.5;         // max RGB split at the edges, in pixels
uniform float vignette = 0.3;           // edge darkening; 0 = none
uniform float brightness = 1.2;         // lift to offset mask/scanline darkening

// TAU is a built-in shader constant (2*PI); used for the scanline frequency.

// Barrel distortion: push UVs outward from center by r^2, so the image bulges like
// curved glass. Returns the warped sample UV (may land outside [0,1] at the corners).
vec2 barrel(vec2 uv, float amt) {
	vec2 cc = uv - 0.5;
	float r2 = dot(cc, cc);
	return uv + cc * r2 * amt;
}

void fragment() {
	vec2 uv = barrel(SCREEN_UV, curvature);

	// Past the curved tube edge -> black bezel (the corners the bulge pulls in).
	// `return` is illegal in fragment(), so guard the whole body instead.
	vec3 col = vec3(0.0);
	if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
		// Chromatic aberration: split R/B radially, growing toward the edges. At the
		// mid-edge (|center| ~ 0.5) the split is ~`aberration` pixels.
		vec2 center = uv - 0.5;
		vec2 ab_off = center * aberration * SCREEN_PIXEL_SIZE * 2.0;
		col.r = texture(screen_texture, uv - ab_off).r;
		col.g = texture(screen_texture, uv).g;
		col.b = texture(screen_texture, uv + ab_off).b;

		// Scanlines: darken the troughs of a vertical sine, curving with the tube.
		float line = 0.5 + 0.5 * sin(uv.y * scanline_count * TAU);
		col *= mix(1.0, line, scanline_strength);

		// RGB aperture grille: tint successive screen columns R / G / B so each
		// phosphor stripe favors one channel. Uses FRAGCOORD (physical glass).
		int m = int(mod(FRAGCOORD.x, 3.0));
		vec3 mask = vec3(1.0 - mask_strength);
		if (m == 0) {
			mask.r = 1.0;
		} else if (m == 1) {
			mask.g = 1.0;
		} else {
			mask.b = 1.0;
		}
		col *= mask;

		// Edge vignette (the tube falloff), then a brightness lift to recover the
		// energy the mask and scanlines subtracted.
		float d = distance(uv, vec2(0.5)) * 1.41421356;
		col *= 1.0 - vignette * smoothstep(0.5, 1.0, d);
		col *= brightness;
	}

	COLOR = vec4(col, 1.0);
}
