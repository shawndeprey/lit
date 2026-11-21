extends RefCounted

## The shader globals every Lit receiver declares. The plugin persists them into
## project.godot; the manager declares any still missing at runtime (plugin disabled).

static func defs() -> Array:
	return [
		{"name": "lit_light_data", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_light_path", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_light_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_viewport_size", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC2, "value": Vector2.ZERO},
		{"name": "lit_canvas_scale", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 1.0},
		{"name": "lit_screen_to_sdf", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC2, "value": Vector2.ZERO},
		{"name": "lit_world_sdf", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_wsdf_basis", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_wsdf_origin", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC2, "value": Vector2.ZERO},
		{"name": "lit_ambient_color", "type": RenderingServer.GLOBAL_VAR_TYPE_COLOR, "value": Color(1, 1, 1, 1)},
		{"name": "lit_ambient_energy", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 1.0},
		{"name": "lit_shadow_steps_max", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 64},
		{"name": "lit_shadow_step_scaling", "type": RenderingServer.GLOBAL_VAR_TYPE_BOOL, "value": false},
		{"name": "lit_tile_size", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 64},
		{"name": "lit_tile_grid", "type": RenderingServer.GLOBAL_VAR_TYPE_IVEC2, "value": Vector2i.ZERO},
		{"name": "lit_directional_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_lighting_model", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_tile_headers", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_tile_indices", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_cookie_atlas", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_ysort_enabled", "type": RenderingServer.GLOBAL_VAR_TYPE_BOOL, "value": false},
		{"name": "lit_ysort_band", "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "value": 12.0},
		{"name": "lit_occ_data", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_occ_headers", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_occ_indices", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": placeholder_texture()},
		{"name": "lit_gl_unit_9", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": pad_texture(Color(1, 1, 1, 1))},
		{"name": "lit_gl_unit_10", "type": RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, "value": pad_texture(Color(0.5, 0.5, 1, 1))},
		{"name": "lit_gx_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_gx_rect0", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_gx_rect1", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_gx_rect2", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_gx_rect3", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_ramp_count", "type": RenderingServer.GLOBAL_VAR_TYPE_INT, "value": 0},
		{"name": "lit_ramp_rect0", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_ramp_rect1", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_ramp_rect2", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
		{"name": "lit_ramp_rect3", "type": RenderingServer.GLOBAL_VAR_TYPE_VEC4, "value": Vector4()},
	]

## Declare every global the engine did not register at init; returns how many. The
## RenderingServer lists its globals only in the editor, so a game checks project.godot.
static func add_missing() -> int:
	var editor := Engine.is_editor_hint()
	var existing := {}
	if editor:
		for n in RenderingServer.global_shader_parameter_get_list():
			existing[String(n)] = true
	var added := 0
	for g in defs():
		var known: bool = existing.has(g.name) if editor else ProjectSettings.has_setting("shader_globals/" + g.name)
		if not known:
			RenderingServer.global_shader_parameter_add(g.name, g.type, g.value)
			added += 1
	return added

## A 1x1 float texture used only as a sampler global's default value.
static func placeholder_texture() -> ImageTexture:
	return pad_texture(Color(0, 0, 0, 0))

## The GLES3 unit 9/10 pads stand in for the canvas specular and normal maps.
static func pad_texture(color: Color) -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, color)
	return ImageTexture.create_from_image(img)
