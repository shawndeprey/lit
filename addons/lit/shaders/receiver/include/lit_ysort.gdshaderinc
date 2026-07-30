// Unit: y-sort shadow depth weight (LIT_YSORT): lit_ysort_weight().

#ifdef LIT_YSORT
// 1 keeps the caster's shadow, 0 exempts it; max over tile candidates, 1 when none.
float lit_ysort_weight(vec2 p_canvas, vec2 p_px, float reach) {
	ivec2 tile = clamp(ivec2(p_px) / lit_tile_size, ivec2(0), lit_tile_grid - ivec2(1));
	vec4 header = texelFetch(lit_occ_headers, tile, 0);
	// Every candidate at or below the receiver's band keeps its shadow (smoothstep
	// saturates to 1), so the tile's min depth answers for all of them at once. Empty
	// tiles carry a huge min depth and take this exit too.
	if (header.z - ysort_y >= lit_ysort_band) {
		return 1.0;
	}
	int offset = int(round(header.x));
	int count = int(round(header.y));
	float w = -1.0;
	float r2 = reach * reach;
	for (int j = 0; j < count; j++) {
		int flat_idx = offset + j;
		int oi = int(round(texelFetch(lit_occ_indices,
				ivec2(flat_idx % LIT_INDEX_TEX_WIDTH, flat_idx / LIT_INDEX_TEX_WIDTH), 0).x));
		vec4 rect = texelFetch(lit_occ_data, ivec2(0, oi), 0);
		vec2 dv = max(max(rect.xy - p_canvas, vec2(0.0)), p_canvas - rect.zw);
		if (dot(dv, dv) > r2) {
			continue;
		}
		w = max(w, smoothstep(-lit_ysort_band, lit_ysort_band, rect.w - ysort_y));
		if (w >= 1.0) {
			return 1.0;
		}
	}
	return w < 0.0 ? 1.0 : w;
}
#endif

