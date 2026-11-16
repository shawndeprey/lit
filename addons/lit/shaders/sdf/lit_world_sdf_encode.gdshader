shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Copies this viewport's occluder SDF into its color target as signed distance in
// world pixels, so receiver shaders in other viewports can sample it.
uniform float screen_to_world = 1.0;

void fragment() {
	float d = texture_sdf(screen_uv_to_sdf(SCREEN_UV));
	float sdf_w = length(screen_uv_to_sdf(vec2(1.0, 0.0)) - screen_uv_to_sdf(vec2(0.0)));
	float d_screen_px = d / sdf_w * (1.0 / SCREEN_PIXEL_SIZE.x);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	// An empty GLES3 SDF packs its far value 1.0 as 0, which decodes to -SDF_MAX_LENGTH.
	d_screen_px = d_screen_px < -16000.0 ? -d_screen_px : d_screen_px;
#endif
	COLOR = vec4(d_screen_px * screen_to_world, 0.0, 0.0, 1.0);
}
