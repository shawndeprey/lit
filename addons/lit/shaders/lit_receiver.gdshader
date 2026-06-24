shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Transport: global uniforms plus the per-frame light-data texture, packed by the
// manager. Read via texelFetch (integer coords, no filtering), so the texture's
// filter mode doesn't matter here.
global uniform sampler2D lit_light_data;
global uniform int       lit_light_count;
global uniform vec2      lit_viewport_size;             // pixels
global uniform vec4      lit_ambient_color : source_color;
global uniform float     lit_ambient_energy;

uniform float emissive_strength = 0.0;
uniform sampler2D emissive_mask : hint_default_white;   // white default lets strength work alone

// A light affects this receiver only if (light_mask & receiver_mask) != 0. Plain int,
// since shader uniforms have no layers hint; LitSprite2D proxies it with a nicer
// 2D-render-layers control.
uniform int receiver_mask = 1;

uniform float specular_strength = 0.5;
uniform float specular_k = 32.0;

uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

// Horizontal reach of a directional light's shading vector relative to its `height`;
// elevation is atan(height / scale). The default gives about 27 degrees at height 16,
// so the direction reads clearly. Larger is more grazing.
uniform float directional_horizontal_scale = 32.0;
// How far a directional shadow marches across the SDF before it counts as open sky,
// in screen diagonals. Scaling to screen size keeps the fixed step budget
// well-sampled; a fixed huge distance would under-sample the penumbra.
uniform float directional_shadow_reach = 1.0;

// Soft-shadow march of Godot's screen-space SDF (the IQ technique). Works in SDF
// space, marching from the fragment toward the light and tracking the running minimum
// of k * d / t for the penumbra. Returns 1 fully lit, 0 occluded.
float lit_shadow(vec2 frag_sdf, vec2 light_sdf, float hardness) {
	// Screen-space SDF has no notion of 2D draw order. A fragment sitting inside
	// an occluder's footprint is treated as on top of it, so a sprite drawn over
	// an occluder stays lit instead of self-shadowing. (Distinct occluders that
	// lie between this fragment and the light still cast normally.)
	if (texture_sdf(frag_sdf) <= 0.0) {
		return 1.0;
	}
	vec2 delta = light_sdf - frag_sdf;
	float maxd = length(delta);
	if (maxd < 0.0001) {
		return 1.0;                          // light is on the fragment
	}
	vec2 dir = delta / maxd;
	float t = shadow_min_step;
	float res = 1.0;
	float k = mix(8.0, 256.0, hardness);     // low hardness is soft, high is crisp
	for (int s = 0; s < shadow_steps; s++) {
		if (t >= maxd) {
			break;
		}
		float d = texture_sdf(frag_sdf + dir * t);
		if (d < 0.001) {
			return 0.0;                      // fully occluded
		}
		res = min(res, k * d / t);           // penumbra accumulation
		t += max(d, shadow_min_step);
	}
	return clamp(res, 0.0, 1.0);
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 albedo = tex.rgb * COLOR.rgb;
	vec3 N = normalize(NORMAL);                  // from the CanvasTexture normal map; faces out when absent
	vec3 spec_shin = SPECULAR_SHININESS.rgb;
	float shininess = SPECULAR_SHININESS.a;

	// Ambient base: albedo lit by the (dark) ambient term.
	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy;

	vec2 frag_uv = SCREEN_UV;                     // canonical screen-UV space
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  // shadow-march space
	// Screen diagonal in SDF units: the natural scale for a directional shadow's march
	// distance, keeping the step budget well-sampled at any resolution.
	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	for (int i = 0; i < lit_light_count; i++) {
		// Texel 0 carries the cheap cull keys (type | flags | mask | falloff), so it's
		// fetched first and a masked-out light bails after a single texelFetch before
		// paying for any further fetch, diffuse, specular or shadow work (Phase 2,
		// Item 2.1). Texel map mirrors lit_light_registry.gd — keep in sync.
		vec4 t0 = texelFetch(lit_light_data, ivec2(0, i), 0); // type | flags | mask | falloff

		// type: 0 = point, 1 = directional, 2 = spot. flags bit 0 = shadow_enabled,
		// bit 1 = subtractive.
		int type = int(round(t0.x));
		bool is_directional = type == 1;
		bool is_spot = type == 2;
		int flags = int(round(t0.y));
		bool shadow_enabled = (flags & 1) != 0;
		bool subtractive = (flags & 2) != 0;
		float falloff = t0.w;

		// Skip lights this receiver's mask doesn't share a bit with, before fetching the
		// rest of the record or paying for any diffuse, specular or shadow work below.
		int light_mask = int(round(t0.z));
		if ((light_mask & receiver_mask) == 0) {
			continue;
		}

		// Passed the cull: fetch the remaining record.
		vec4 t1 = texelFetch(lit_light_data, ivec2(1, i), 0); // uv.xy/dir.xy | range | energy
		vec4 t2 = texelFetch(lit_light_data, ivec2(2, i), 0); // color.rgb | height

		vec2 light_uv = t1.xy;
		float range = t1.z;
		float energy = t1.w;
		vec3 light_color = t2.rgb;
		float height = t2.w;

		vec3 Ldir;
		float atten;
		vec2 shadow_dir_uv = vec2(0.0);          // toward-light dir in screen-UV space (directional only)

		if (is_directional) {
			// t1.xy is a unit screen-space direction toward the light. No position, no
			// attenuation; `height` sets the elevation.
			vec2 dir_px = t1.xy;
			Ldir = normalize(vec3(dir_px * directional_horizontal_scale, height));
			atten = 1.0;
			shadow_dir_uv = dir_px / lit_viewport_size; // pixel dir to UV dir
		} else {
			// Point or spot: work in pixels.
			vec2 to_light_px = (light_uv - frag_uv) * lit_viewport_size;
			float dist = length(to_light_px);
			if (dist > range) {
				continue;                        // beyond range
			}
			Ldir = normalize(vec3(to_light_px, height));
			atten = pow(clamp(1.0 - dist / range, 0.0, 1.0), falloff);

			// A spot is a point light masked to a cone (texel 4): aim.xy is the
			// screen-space direction it points. The fragment is lit if it falls inside
			// the cone, with a soft edge between the inner and outer angle.
			if (is_spot) {
				vec4 t4 = texelFetch(lit_light_data, ivec2(4, i), 0); // aim.xy | cos_outer | cos_inner
				vec2 dir_to_frag = (dist > 0.0001) ? (-to_light_px / dist) : t4.xy;
				float cone = smoothstep(t4.z, t4.w, dot(t4.xy, dir_to_frag));
				atten *= cone;
			}
		}

		// Fully attenuated (out of range, or outside a spot's cone): nothing to add
		// and no shadow to march.
		if (atten <= 0.0) {
			continue;
		}

		float ndotl = max(dot(N, Ldir), 0.0);

		vec3 diffuse = albedo * light_color * energy * ndotl * atten;

		// Sharpened N.L lobe, tight and only where the surface tilts toward the light.
		// Tinted by light_color so the highlight takes the light's hue instead of
		// blowing out to white (SPECULAR_SHININESS.rgb is white when no specular map is
		// set). pow(ndotl, ...) is already 0 when the surface faces away.
		//
		// Lossless gate (Phase 1, Item 1.1): the term is exactly vec3(0.0) when
		// specular_strength is 0.0 (the common case) or when the spec/shininess map is
		// pure black, so skipping it then can't change the pixel — but it avoids a
		// needless pow() per in-range light. The spec-map test is kept conservative
		// (dot == 0.0) so a dim-but-tinted highlight is never dropped.
		vec3 specular = vec3(0.0);
		if (specular_strength > 0.0 && dot(spec_shin, spec_shin) > 0.0) {
			specular = light_color * spec_shin * energy * atten * pow(ndotl, 1.0 + shininess * specular_k) * specular_strength;
		}

		vec3 contribution = diffuse + specular;

		// Lossless early-out (Phase 1, Item 1.2): lit_shadow() only ever *reduces*
		// contribution (it multiplies by a factor in [0,1]). So if the unshadowed
		// contribution already rounds to zero at 8-bit, shadowing cannot move the pixel
		// — skip both the up-to-64-tap SDF march and the accumulation. The epsilon is
		// tied to 8-bit quantization (0.5/255 ~= 0.002) with margin (0.004). Uses the
		// max channel as the magnitude proxy; a subtractive light that rounds to zero
		// likewise can't darken the result. This subsumes the cheaper atten <= 0.0 bail
		// above for the shadow-march case.
		if (max(contribution.r, max(contribution.g, contribution.b)) < 0.004) {
			continue;
		}

		// Marched only for shadow-casting lights, so a light with shadows off pays
		// nothing here, not even the texel-2 fetch. In shadow the contribution is
		// tinted by shadow_color (black blocks the light entirely). Factor 1 is lit,
		// 0 is occluded.
		if (shadow_enabled) {
			vec4 t3 = texelFetch(lit_light_data, ivec2(3, i), 0); // shadow_color.rgb | shadow_hardness
			vec2 light_sdf;
			if (is_directional) {
				// March a fixed direction across the SDF. screen_uv_to_sdf is affine, so
				// the SDF-space direction comes from offsetting the fragment UV along the
				// toward-light dir; the distance scales with the screen.
				vec2 dir_sdf = normalize(screen_uv_to_sdf(SCREEN_UV + shadow_dir_uv) - frag_sdf);
				light_sdf = frag_sdf + dir_sdf * sdf_diag * directional_shadow_reach;
			} else {
				// Point and spot both march toward the light's screen position.
				light_sdf = screen_uv_to_sdf(light_uv);
			}
			float s = lit_shadow(frag_sdf, light_sdf, t3.w);
			contribution *= mix(t3.rgb, vec3(1.0), s);
		}

		// Subtract mode is negative light: it carves darkness below ambient, and the
		// final COLOR clamps at display.
		if (subtractive) {
			lit -= contribution;
		} else {
			lit += contribution;
		}
	}

	// Emissive ignores the dark and composes with ambient and lights by construction.
	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	COLOR = vec4(lit + emissive, tex.a * COLOR.a);
}
