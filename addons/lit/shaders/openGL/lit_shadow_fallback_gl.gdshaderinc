// Unit: OpenGL/Compatibility positional-light shadow fallback: lit_shadow_fallback().
// Only the LIT_GL_COMPAT receivers include this (via lit_shade.gdshaderinc); the
// Forward+ receivers never compile it.

// On Compatibility there is no 2D SDF to march, so occluder-shaped shadows are
// impossible at any cost. This is the performant stand-in for POSITIONAL lights (the
// point/spot radial pool): a few ALU ops per shadow-casting light and no extra
// texture reads beyond the light's own shadow texel (lit_shade() already fetched it).
// It approximates the look of the march - a bright pool of light that the shadow
// color eats into - so positional shadow-casting lights keep their authored
// shadow_color on web/OpenGL builds. The artist tunes it with the same knobs the
// march uses: shadow_color tints the shadowed side, shadow_hardness reshapes the pool
// edge (low = wide soft falloff, high = a crisp edge).

// A directional light is intentionally NOT approximated here: on Compatibility there
// is no occluder data for it, and any per-light ramp anchored to a screen or light
// position either drifts with the camera (screen-anchored) or darkens whole swaths of
// the level (world-anchored, once the level extends past the ramp). Like a clear sky
// its rays reach every receiver, so the level stays fully lit - which is also what the
// native march produces when no occluder covers a fragment. lit_shade() skips the
// fallback for directionals.

// `viewport_size`/`canvas_scale` are passed in rather than reading the lit_header
// globals so this unit compiles on its own (it's a self-contained include).
float lit_shadow_fallback(vec2 light_uv, vec2 frag_uv, float range, float hardness,
		vec2 viewport_size, float canvas_scale) {
	// Radial pool: fully lit at the light, ramping to shadow_color past `mid` of the
	// light's range - a stand-in for the occluders that would sit between the light
	// and the fragment and block its rays. Camera-stable: both uvs shift together
	// with the view, and range is scaled by the same world-to-screen factor.
	float n = length((light_uv - frag_uv) * viewport_size)
			/ max(range * canvas_scale, 1e-4);
	float mid = mix(0.5, 0.85, hardness);
	float soft = mix(0.5, 0.08, hardness);
	return clamp(1.0 - smoothstep(mid - soft, mid + soft, n), 0.0, 1.0);
}
