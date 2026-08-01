// Unit: fragment() main.

void fragment() {
	vec3 albedo = COLOR.rgb;
	vec3 N = normalize(NORMAL);                  // from the CanvasTexture normal map; faces out when absent
	vec3 spec_shin = SPECULAR_SHININESS.rgb;
	float shininess = SPECULAR_SHININESS.a;

	// PBR material inputs, sampled once per fragment and only in PBR mode. In Phong mode
	// they stay at their neutral defaults (never read by lit_shade, and ao = 1 leaves the
	// ambient term unchanged), so Phong pays for none of these fetches.
	float metallic = 0.0;
	float roughness = 1.0;
	float ao = 1.0;
	if (lit_lighting_model == LIT_MODEL_PBR) {
		metallic = clamp(metallic_value * texture(metallic_map, UV).r, 0.0, 1.0);
		roughness = clamp(roughness_value * texture(roughness_map, UV).r, 0.04, 1.0);
		ao = texture(ao_map, UV).r;
	}

	// Ambient base: albedo lit by the (dark) ambient term, attenuated by AO in PBR
	// (ao = 1 in Phong, so this is a no-op there).
	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy * ao;

	vec2 frag_uv = SCREEN_UV;                     // canonical screen-UV space
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  // shadow-march space

	// The fragment's own SDF sample, shared by every light's shadow march.
	float frag_d = lit_sdf_sample(frag_sdf);

	// Screen diagonal in SDF units: the natural scale for a directional shadow's march
	// distance, keeping the step budget well-sampled at any resolution.
	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	// Self-shadow basis: map SDF-space march offsets to canvas space. Both spaces are
	// affine images of the screen, so probing one pixel step in each and composing is
	// exact. The uniform condition keeps the derivative calls in uniform control flow.
#ifdef LIT_SELF_EXCLUSION
	bool self_ex = !self_shadow && self_rect_count > 0;
#else
	// Fast variant: the constant false compiles the exclusion march, the self basis
	// below, and the lit_self_* helpers out of the shader.
	bool self_ex = false;
#endif
#ifdef LIT_OCC_GX
	self_ex = self_ex || lit_gx_count > 0;
#endif
#ifdef LIT_OCC_RX
	self_ex = self_ex || rx_mask != 0;
#endif
#ifdef LIT_YSORT
	bool ys_on = lit_ysort_enabled && ysort_on;
#endif
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
	mat2 sdf_to_px = mat2(vec2(0.0), vec2(0.0));
	vec2 frag_px = SCREEN_UV * lit_viewport_size;
#endif
	mat2 sdf_to_canvas = mat2(vec2(0.0), vec2(0.0));
	float self_scale = 0.0;
#ifdef LIT_OCC_MASKS
	// Any tile light may carry exclusions, so the basis is always needed.
	const bool occ_basis = true;
#else
	bool occ_basis = self_ex || LIT_YS_ON;
#endif
	if (occ_basis) {
		// Columns: per-pixel-step delta of each space, in x and y.
		mat2 px_to_sdf = mat2(
				screen_uv_to_sdf(SCREEN_UV + vec2(SCREEN_PIXEL_SIZE.x, 0.0)) - frag_sdf,
				screen_uv_to_sdf(SCREEN_UV + vec2(0.0, SCREEN_PIXEL_SIZE.y)) - frag_sdf);
		mat2 px_to_canvas = mat2(dFdx(v_canvas), dFdy(v_canvas));
#if defined(LIT_YSORT) || defined(LIT_OCC_RX)
		sdf_to_px = inverse(px_to_sdf);
		sdf_to_canvas = px_to_canvas * sdf_to_px;
#else
		sdf_to_canvas = px_to_canvas * inverse(px_to_sdf);
#endif
		// Canvas length of one SDF unit, for comparing SDF distances against the bounds.
		self_scale = max(length(sdf_to_canvas[0]), length(sdf_to_canvas[1]));
	}

	// Tiling is only used once the manager has published a grid; until then (and in the
	// zero-light case) fall back to looping every light.
	bool tiling_valid = lit_tile_grid.x > 0 && lit_tile_grid.y > 0 && lit_tile_size > 0;

	if (tiling_valid) {
		// Directional lights cover the whole screen, so they're never tiled: shade the
		// leading directional rows for every fragment. Kept separate from the tile loop
		// so the row index stays wave-uniform.
		for (int i = 0; i < lit_directional_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, frag_d, self_ex, v_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS);
		}

		// Positional lights: look up this fragment's tile and shade only the lights
		// binned into it. The header gives the offset/count into the flat index list.
		ivec2 tile = ivec2(SCREEN_UV * lit_viewport_size) / lit_tile_size;
		tile = clamp(tile, ivec2(0), lit_tile_grid - ivec2(1));
		vec4 header = texelFetch(lit_tile_headers, tile, 0); // offset | count
		int offset = int(round(header.x));
		int count = int(round(header.y));
		for (int j = 0; j < count; j++) {
			int flat_idx = offset + j;
			ivec2 icoord = ivec2(flat_idx % LIT_INDEX_TEX_WIDTH, flat_idx / LIT_INDEX_TEX_WIDTH);
			int li = int(round(texelFetch(lit_tile_indices, icoord, 0).x));
			lit += lit_shade(li, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, frag_d, self_ex, v_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS);
		}
	} else {
		// Fallback: no tile grid published, so iterate every light.
		for (int i = 0; i < lit_light_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, metallic, roughness, frag_uv, frag_sdf, sdf_diag, frag_d, self_ex, v_canvas, sdf_to_canvas, self_scale LIT_PX_ARGS LIT_YS_ARGS);
		}
	}

	// Emissive ignores the dark and composes with ambient and lights by construction.
	// Zero strength skips the mask fetch.
	vec3 emissive = vec3(0.0);
	if (emissive_strength != 0.0) {
		emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;
	}

	COLOR = vec4(lit + emissive, COLOR.a);
}
