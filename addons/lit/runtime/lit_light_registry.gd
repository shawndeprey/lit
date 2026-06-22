extends RefCounted
class_name LitLightRegistry

## Shared gather / cull / pack logic (plan §8, §9.0, §9.4).
##
## Driven by `lit_manager.gd` (autoload) at runtime, and — from Phase 4 —
## by `lit_plugin.gd` for editor-live preview. Both call the same refresh().
##
## Each instance owns its own light-data texture, so the editor and a running
## game (separate processes / RenderingServer global state) never collide.
##
## Phase 1 packs the full 16-float record per light (plan §9.4) even though the
## receiver shader only consumes the diffuse fields. Shadow/type/mask fields are
## written now so Phases 2–4 only touch the shader, never the pack.

var _texture: ImageTexture
var _dummy: ImageTexture


## Gather visible lights, pack them into the light-data texture, and publish the
## global shader uniforms. Call once per frame.
func refresh(tree: SceneTree, viewport: Viewport) -> void:
	if tree == null or viewport == null:
		return

	var vp_size: Vector2 = viewport.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return

	var canvas_xform := viewport.get_canvas_transform()
	var world_rect := _visible_world_rect(canvas_xform, vp_size)

	# 1–3. Collect enabled, on-screen point lights (AABB cull, plan §8.3).
	var visible: Array = []
	for node in tree.get_nodes_in_group("lit_lights"):
		var light := node as LitPointLight2D
		if light == null or not light.enabled:
			continue
		var r: float = light.range
		var light_aabb := Rect2(light.global_position - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
		if world_rect.intersects(light_aabb):
			visible.append(light)

	var count := visible.size()

	# Zero-light case (plan §9.4): count 0 + 1×1 dummy, never a 4×0 image.
	if count == 0:
		RenderingServer.global_shader_parameter_set("lit_light_count", 0)
		RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
		RenderingServer.global_shader_parameter_set("lit_light_data", _get_dummy())
		return

	# 4. Pack each light into a 4×count RGBAF image (plan §9.4).
	var img := Image.create(4, count, false, Image.FORMAT_RGBAF)
	for i in count:
		_pack_light(img, i, visible[i], canvas_xform, vp_size)
	_update_texture(img)

	# 5. Publish globals.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	RenderingServer.global_shader_parameter_set("lit_light_data", _texture)


## Pack one point light into row `row` (plan §9.4 texel table).
func _pack_light(img: Image, row: int, light: LitPointLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	# Position → normalized screen UV (plan §9.0): the one canonical space.
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Integer fields stored as plain floats, decoded with int(round(...)) in-shader.
	var subtractive := 1.0 if light.blend_mode == LitPointLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_POINT := 0.0

	# Texel 0: uv.x | uv.y | range | energy
	img.set_pixel(0, row, Color(uv.x, uv.y, light.range, light.energy))
	# Texel 1: color.r | color.g | color.b | height
	img.set_pixel(1, row, Color(light.color.r, light.color.g, light.color.b, light.height))
	# Texel 2: shadow_color.rgb | shadow_hardness
	img.set_pixel(2, row, Color(light.shadow_color.r, light.shadow_color.g, light.shadow_color.b, light.shadow_hardness))
	# Texel 3: type | flags | light_mask | falloff
	img.set_pixel(3, row, Color(TYPE_POINT, flags, float(light.light_mask), light.falloff))


## Visible screen rect transformed into world space (plan §8.2).
func _visible_world_rect(canvas_xform: Transform2D, vp_size: Vector2) -> Rect2:
	var inv := canvas_xform.affine_inverse()
	var rect := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	rect = rect.expand(inv * Vector2(vp_size.x, 0.0))
	rect = rect.expand(inv * Vector2(0.0, vp_size.y))
	rect = rect.expand(inv * vp_size)
	return rect


## Reuse the ImageTexture when the light count is unchanged; reallocate on resize.
## Note: ImageTexture.get_size() is Vector2 while Image.get_size() is Vector2i,
## so compare in a single type.
func _update_texture(img: Image) -> void:
	if _texture == null or _texture.get_size() != Vector2(img.get_size()):
		_texture = ImageTexture.create_from_image(img)
	else:
		_texture.update(img)


func _get_dummy() -> ImageTexture:
	if _dummy == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
		img.set_pixel(0, 0, Color(0, 0, 0, 0))
		_dummy = ImageTexture.create_from_image(img)
	return _dummy
