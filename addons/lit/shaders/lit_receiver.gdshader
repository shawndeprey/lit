shader_type canvas_item;
render_mode unshaded; // D2: disable Godot's built-in canvas light() pass.

// --- D1 transport: global uniforms + per-frame light-data texture ---
// Read via texelFetch (integer coords, no filtering), so the texture's filter
// mode is irrelevant to correctness here.
global uniform sampler2D lit_light_data;
global uniform int       lit_light_count;
global uniform vec2      lit_viewport_size;             // §9.0, pixels
global uniform vec4      lit_ambient_color : source_color; // D7
global uniform float     lit_ambient_energy;

// --- per-instance (D6 emissive) ---
uniform float emissive_strength = 0.0;
uniform sampler2D emissive_mask : hint_default_white;   // white default -> strength alone works

// --- per-instance specular tuning (§9.2; K is a by-eye dial, plan §7/§14) ---
uniform float specular_strength = 0.5;
uniform float specular_k = 32.0;

// --- advanced shadow tuning (D4 / §9.3; developer-tunable) ---
uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

// Scope through Phase 2: ambient + point diffuse + specular + emissive + soft
// shadows. No directional branch (Phase 3), no mask/subtract (Phase 4).

// IQ soft-shadow march of the native screen-space SDF (D4, §9.3). Operates in
// SDF space; marches from the fragment toward the light, tracking the running
// minimum of k * d / t for the penumbra. Returns 1 = fully lit, 0 = occluded.
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
	float k = mix(8.0, 256.0, hardness);     // low hardness = soft, high = crisp
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
	vec3 N = normalize(NORMAL);                  // D3: auto from CanvasTexture normal map; faces out when absent
	vec3 spec_shin = SPECULAR_SHININESS.rgb;     // D3
	float shininess = SPECULAR_SHININESS.a;

	// D7 ambient base: albedo lit by the (dark) ambient term.
	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy;

	vec2 frag_uv = SCREEN_UV;                     // §9.0 canonical space
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  // §9.3 shadow march space

	for (int i = 0; i < lit_light_count; i++) {
		// Unpack the per-light record (§9.4).
		vec4 t0 = texelFetch(lit_light_data, ivec2(0, i), 0); // uv.xy | range | energy
		vec4 t1 = texelFetch(lit_light_data, ivec2(1, i), 0); // color.rgb | height
		vec4 t3 = texelFetch(lit_light_data, ivec2(3, i), 0); // type | flags | mask | falloff

		vec2 light_uv = t0.xy;
		float range = t0.z;
		float energy = t0.w;
		vec3 light_color = t1.rgb;
		float height = t1.w;
		float falloff = t3.w;

		// flags: bit 0 = shadow_enabled, bit 1 = subtractive (Phase 4). §9.4.
		int flags = int(round(t3.y));
		bool shadow_enabled = (flags & 1) != 0;

		// §9.0/§9.2: work in pixels. UV delta -> pixel delta.
		vec2 to_light_px = (light_uv - frag_uv) * lit_viewport_size;
		float dist = length(to_light_px);
		if (dist > range) {
			continue;                            // early-out beyond range
		}

		vec3 Lvec = vec3(to_light_px, height);
		vec3 Ldir = normalize(Lvec);
		float ndotl = max(dot(N, Ldir), 0.0);
		float atten = pow(clamp(1.0 - dist / range, 0.0, 1.0), falloff);

		// Diffuse (§9.2).
		vec3 diffuse = albedo * light_color * energy * ndotl * atten;

		// Specular (§9.2). Sharpened N·L lobe — tight, only where the surface
		// tilts toward the light. Tinted by light_color so the highlight takes
		// the light's hue instead of blowing out to white (SPECULAR_SHININESS.rgb
		// defaults to white when no specular map is set). pow(ndotl, …) is already
		// 0 when the surface faces away, so no extra gate is needed.
		vec3 specular = light_color * spec_shin * energy * atten * pow(ndotl, 1.0 + shininess * specular_k) * specular_strength;

		vec3 contribution = diffuse + specular;

		// Shadows (D4, §9.3): marched only for shadow-casting lights, so a light
		// with shadows off pays nothing here — not even the texel-2 fetch. In
		// shadow the contribution is tinted by shadow_color (black default ->
		// the light is fully blocked). Shadow factor 1 = lit, 0 = occluded.
		if (shadow_enabled) {
			vec4 t2 = texelFetch(lit_light_data, ivec2(2, i), 0); // shadow_color.rgb | shadow_hardness
			float s = lit_shadow(frag_sdf, screen_uv_to_sdf(light_uv), t2.w);
			contribution *= mix(t2.rgb, vec3(1.0), s);
		}

		// Phase 1: additive only (Subtract blend is Phase 4).
		lit += contribution;
	}

	// D6 emissive: ignores the dark; composes with ambient + lights by construction.
	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	COLOR = vec4(lit + emissive, tex.a * COLOR.a);
}
