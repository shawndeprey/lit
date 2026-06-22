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

// Phase 1 scope: ambient + point diffuse + specular + emissive. No shadows
// (Phase 2), no directional branch (Phase 3), no mask/subtract (Phase 4).
// The light-data texture already carries those fields; this shader ignores them.

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 albedo = tex.rgb * COLOR.rgb;
	vec3 N = normalize(NORMAL);                  // D3: auto from CanvasTexture normal map; faces out when absent
	vec3 spec_shin = SPECULAR_SHININESS.rgb;     // D3
	float shininess = SPECULAR_SHININESS.a;

	// D7 ambient base: albedo lit by the (dark) ambient term.
	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy;

	vec2 frag_uv = SCREEN_UV;                     // §9.0 canonical space

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

		// Specular (§9.2; tight by default so it reads as a highlight, not a wash).
		vec3 specular = spec_shin * energy * atten * pow(ndotl, 1.0 + shininess * specular_k) * specular_strength;

		// Phase 1: additive only (Subtract blend is Phase 4).
		lit += diffuse + specular;
	}

	// D6 emissive: ignores the dark; composes with ambient + lights by construction.
	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	COLOR = vec4(lit + emissive, tex.a * COLOR.a);
}
