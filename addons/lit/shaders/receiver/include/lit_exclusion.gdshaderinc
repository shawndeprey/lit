// Unit: self/gx/mask/rx exclusion helpers (LIT_SELF_EXCLUSION, LIT_OCC_GX, LIT_OCC_MASKS, LIT_OCC_RX).

// Slack for the self-bounds test, in SDF units: the SDF is generated at reduced
// resolution, so an outline's zero level sits a texel or two outside its polygon.
const float LIT_SELF_PAD_SDF = 2.0;

#ifdef LIT_OCC_GX
float lit_gx_dist2(vec4 rect, vec2 p_canvas) {
	vec2 dv = max(max(rect.xy - p_canvas, vec2(0.0)), p_canvas - rect.zw);
	return dot(dv, dv);
}

// Param in [0,1] where segment a -> a+ab exits the pad-expanded rect; 0 if never inside.
float lit_rect_segment_exit(vec2 a, vec2 ab, vec4 rect, float pad) {
	vec2 inv = 1.0 / ab;
	vec2 t0 = (rect.xy - pad - a) * inv;
	vec2 t1 = (rect.zw + pad - a) * inv;
	vec2 tn = min(t0, t1);
	vec2 tf = max(t0, t1);
	float tmin = max(tn.x, tn.y);
	float tmax = min(tf.x, tf.y);
	if (tmax >= max(tmin, 0.0) && tmin <= 1.0) {
		return clamp(tmax, 0.0, 1.0);
	}
	return 0.0;
}
#endif

// Squared distance to the nearest exempt box (0 inside): the receiver's own occluders
// plus, in the exclusion variants, the globally excluded ones.
float lit_self_dist2(vec2 p_canvas) {
	float best = 1e20;
#ifdef LIT_OCC_GX
	// self_shadow only opts out of the receiver's own rects, never the global ones.
	int sc = self_shadow ? 0 : self_rect_count;
#else
	int sc = self_rect_count;
#endif
	for (int i = 0; i < 4; i++) {
		if (i >= sc) {
			break;
		}
		vec2 dv = max(max(self_rects[i].xy - p_canvas, vec2(0.0)), p_canvas - self_rects[i].zw);
		best = min(best, dot(dv, dv));
	}
#ifdef LIT_OCC_GX
	if (lit_gx_count > 0) {
		best = min(best, lit_gx_dist2(lit_gx_rect0, p_canvas));
		if (lit_gx_count > 1) {
			best = min(best, lit_gx_dist2(lit_gx_rect1, p_canvas));
			if (lit_gx_count > 2) {
				best = min(best, lit_gx_dist2(lit_gx_rect2, p_canvas));
				if (lit_gx_count > 3) {
					best = min(best, lit_gx_dist2(lit_gx_rect3, p_canvas));
				}
			}
		}
	}
#endif
	return best;
}

// Param in [0,1] where segment a -> a+ab exits the pad-expanded exempt boxes; 0 if never inside.
float lit_self_segment_exit(vec2 a, vec2 ab, float pad) {
	vec2 inv = 1.0 / ab;
	float t_end = 0.0;
#ifdef LIT_OCC_GX
	int sc = self_shadow ? 0 : self_rect_count;
#else
	int sc = self_rect_count;
#endif
	for (int i = 0; i < 4; i++) {
		if (i >= sc) {
			break;
		}
		vec2 t0 = (self_rects[i].xy - pad - a) * inv;
		vec2 t1 = (self_rects[i].zw + pad - a) * inv;
		vec2 tn = min(t0, t1);
		vec2 tf = max(t0, t1);
		float tmin = max(tn.x, tn.y);
		float tmax = min(tf.x, tf.y);
		if (tmax >= max(tmin, 0.0) && tmin <= 1.0) {
			t_end = max(t_end, min(tmax, 1.0));
		}
	}
#ifdef LIT_OCC_GX
	if (lit_gx_count > 0) {
		t_end = max(t_end, lit_rect_segment_exit(a, ab, lit_gx_rect0, pad));
		if (lit_gx_count > 1) {
			t_end = max(t_end, lit_rect_segment_exit(a, ab, lit_gx_rect1, pad));
			if (lit_gx_count > 2) {
				t_end = max(t_end, lit_rect_segment_exit(a, ab, lit_gx_rect2, pad));
				if (lit_gx_count > 3) {
					t_end = max(t_end, lit_rect_segment_exit(a, ab, lit_gx_rect3, pad));
				}
			}
		}
	}
#endif
	return t_end;
}

#ifdef LIT_OCC_MASKS
// True when the sample's nearest outline can belong to one of the light's exempt
// occluders (texels 11-14 of its row; texel 9.x is the count).
bool lit_mk_exempt(int row, vec2 p_canvas, float reach) {
	int cnt = int(round(texelFetch(lit_light_data, ivec2(9, row), 0).x));
	float r2 = reach * reach;
	for (int j = 0; j < 4; j++) {
		if (j >= cnt) {
			break;
		}
		vec4 rect = texelFetch(lit_light_data, ivec2(11 + j, row), 0);
		vec2 dv = max(max(rect.xy - p_canvas, vec2(0.0)), p_canvas - rect.zw);
		if (dot(dv, dv) <= r2) {
			return true;
		}
	}
	return false;
}
#endif

#ifdef LIT_OCC_RX
// True when the sample's nearest outline can belong to an occluder this receiver
// ignores. The ignore test runs on the cast's EFFECTIVE layers - the occluder's mask
// ANDed with the current light's shadow mask (smask) - so a multi-layer occluder cast
// via a non-ignored layer keeps its shadow. Candidates come from the sample's
// occluder tile, so cost scales with local density, not scene-wide caster count.
bool lit_rx_exempt(vec2 p_canvas, vec2 p_px, float reach, int smask) {
	ivec2 tile = clamp(ivec2(p_px) / lit_tile_size, ivec2(0), lit_tile_grid - ivec2(1));
	vec4 header = texelFetch(lit_occ_headers, tile, 0);
	// header.w is the OR of the tile's candidate masks: one fetch dismisses tiles
	// where no candidate can pass the per-candidate mask test below.
	if ((int(round(header.w)) & (smask & rx_mask)) == 0) {
		return false;
	}
	int count = int(round(header.y));
	int offset = int(round(header.x));
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
		int m = int(round(texelFetch(lit_occ_data, ivec2(1, oi), 0).x));
		if (((m & smask) & rx_mask) != 0) {
			return true;
		}
	}
	return false;
}
#endif

