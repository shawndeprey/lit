// Unit: world-SDF sampling: lit_wsdf_uv(), lit_sdf_sample(), lit_sdf_cov_exit().

// March-space (engine sdf coords) point to world-SDF UV. The sdf<->screen mapping is
// derived from screen_uv_to_sdf probes; every term is uniform, so compilers hoist the
// whole chain out of march loops.
vec2 lit_wsdf_uv(vec2 p_sdf) {
	vec2 s0 = screen_uv_to_sdf(vec2(0.0));
	vec2 sd = screen_uv_to_sdf(vec2(1.0)) - s0;
	vec2 px = (p_sdf - s0) / sd * LIT_VIEWPORT_SIZE;
	return vec2(dot(LIT_WSDF_BASIS.xz, px), dot(LIT_WSDF_BASIS.yw, px)) + LIT_WSDF_ORIGIN;
}

// Signed distance at a march-space point, in march-space units, sampled from the
// world SDF (world px -> screen px via LIT_CANVAS_SCALE -> sdf units).
float lit_sdf_sample(vec2 p_sdf) {
	float d_world = textureLod(lit_world_sdf, lit_wsdf_uv(p_sdf), 0.0).r;
	vec2 s0 = screen_uv_to_sdf(vec2(0.0));
	float sd_x = screen_uv_to_sdf(vec2(1.0, 0.0)).x - s0.x;
	return d_world * LIT_CANVAS_SCALE * sd_x / LIT_VIEWPORT_SIZE.x;
}

// SDF units per world px: the factor lit_sdf_sample applies to the stored distance.
float lit_world_to_sdf() {
	vec2 s0 = screen_uv_to_sdf(vec2(0.0));
	float sd_x = screen_uv_to_sdf(vec2(1.0, 0.0)).x - s0.x;
	return LIT_CANVAS_SCALE * sd_x / LIT_VIEWPORT_SIZE.x;
}

// Distance along a march ray to the world SDF's coverage edge. Beyond it is unknown
// territory, and unknown territory never casts; marches clamp their length to this so
// boundary texels can't smear into phantom occluders.
float lit_sdf_cov_exit(vec2 o, vec2 dir) {
	vec2 s0 = screen_uv_to_sdf(vec2(0.0));
	vec2 sd = screen_uv_to_sdf(vec2(1.0)) - s0;
	vec2 o_uv = lit_wsdf_uv(o);
	vec2 dir_px = dir / sd * LIT_VIEWPORT_SIZE;
	vec2 dir_uv = vec2(dot(LIT_WSDF_BASIS.xz, dir_px), dot(LIT_WSDF_BASIS.yw, dir_px));
	vec2 far = mix(vec2(0.002), vec2(0.998), step(vec2(0.0), dir_uv));
	vec2 tt = (far - o_uv) / dir_uv;
	return max(min(tt.x, tt.y), 0.0);
}

