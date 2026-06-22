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
## Packs a per-light record (plan §9.4, extended). Texel 3.r is the type:
##  0 point     — texel 0 is a screen-UV position.
##  1 directional — texel 0 is a screen-space direction toward the light.
##  2 spot      — texel 0 is a position (as point); texel 4 adds the cone
##                (aim direction + cos of the inner/outer angles).

const TEXELS_PER_LIGHT := 5

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

	# 1–3. Collect enabled, visible lights. Point and spot lights are AABB-culled
	# against the visible world rect; directional lights are never positionally
	# culled (plan §8.3). Disabled or hidden lights (visibility mirrors `enabled`,
	# and respects hidden ancestors) are culled here on the CPU: never packed,
	# never iterated.
	var visible: Array = []
	for node in tree.get_nodes_in_group("lit_lights"):
		var directional := node as LitDirectionalLight2D
		if directional != null:
			if directional.enabled and directional.is_visible_in_tree():
				visible.append(directional)  # never positionally culled
			continue
		var point := node as LitPointLight2D
		if point != null:
			if point.enabled and point.is_visible_in_tree() and _aabb_visible(point.global_position, point.range, world_rect):
				visible.append(point)
			continue
		var spot := node as LitSpotLight2D
		if spot != null and spot.enabled and spot.is_visible_in_tree():
			if _aabb_visible(spot.global_position, spot.range, world_rect):
				visible.append(spot)

	var count := visible.size()

	# Zero-light case (plan §9.4): count 0 + 1×1 dummy, never a 4×0 image.
	if count == 0:
		RenderingServer.global_shader_parameter_set("lit_light_count", 0)
		RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
		RenderingServer.global_shader_parameter_set("lit_light_data", _get_dummy())
		return

	# 4. Pack each light into the RGBAF image (plan §9.4, extended).
	var img := Image.create(TEXELS_PER_LIGHT, count, false, Image.FORMAT_RGBAF)
	for i in count:
		var directional := visible[i] as LitDirectionalLight2D
		if directional != null:
			_pack_directional(img, i, directional, canvas_xform)
			continue
		var spot := visible[i] as LitSpotLight2D
		if spot != null:
			_pack_spot(img, i, spot, canvas_xform, vp_size)
			continue
		_pack_point(img, i, visible[i] as LitPointLight2D, canvas_xform, vp_size)
	_update_texture(img)

	# 5. Publish globals.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	RenderingServer.global_shader_parameter_set("lit_light_data", _texture)


## Pack one point light into row `row` (plan §9.4 texel table).
func _pack_point(img: Image, row: int, light: LitPointLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
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


## Pack one directional light into row `row` (plan §7.2, §9.0, D5).
## Texel 0 carries a normalized *direction toward the light* in screen-pixel
## space instead of a UV position; range/falloff are unused.
func _pack_directional(img: Image, row: int, light: LitDirectionalLight2D, canvas_xform: Transform2D) -> void:
	# The node's local +X (its rotation) is the direction the light *travels* /
	# aims, so the direction toward the source is the opposite. Convert to screen
	# space via the canvas basis (camera rotation/zoom carries through).
	var aim_world := Vector2.from_angle(light.global_rotation)
	var dir_px := canvas_xform.basis_xform(-aim_world)
	if dir_px.length() > 0.0:
		dir_px = dir_px.normalized()

	var subtractive := 1.0 if light.blend_mode == LitDirectionalLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_DIRECTIONAL := 1.0

	# Texel 0: dir.x | dir.y | (range unused) | energy
	img.set_pixel(0, row, Color(dir_px.x, dir_px.y, 0.0, light.energy))
	# Texel 1: color.r | color.g | color.b | height
	img.set_pixel(1, row, Color(light.color.r, light.color.g, light.color.b, light.height))
	# Texel 2: shadow_color.rgb | shadow_hardness
	img.set_pixel(2, row, Color(light.shadow_color.r, light.shadow_color.g, light.shadow_color.b, light.shadow_hardness))
	# Texel 3: type | flags | light_mask | (falloff unused)
	img.set_pixel(3, row, Color(TYPE_DIRECTIONAL, flags, float(light.light_mask), 1.0))


## Pack one spot light into row `row`: a point light (texels 0–3) plus a cone
## (texel 4). The node's local +X (its rotation) is the direction the cone aims.
func _pack_spot(img: Image, row: int, light: LitSpotLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Aim direction in screen space (camera rotation/zoom carries through).
	var aim_px := canvas_xform.basis_xform(Vector2.from_angle(light.global_rotation))
	if aim_px.length() > 0.0:
		aim_px = aim_px.normalized()

	# Cone as cosines: cos(outer) is the edge, cos(inner) the fully-lit core.
	# spot_softness feathers the core inward; keep inner strictly inside outer so
	# the in-shader smoothstep never divides by zero.
	var cos_outer := cos(deg_to_rad(light.spot_angle))
	var cos_inner := cos(deg_to_rad(light.spot_angle * (1.0 - light.spot_softness)))
	if cos_inner <= cos_outer:
		cos_inner = cos_outer + 0.0001

	var subtractive := 1.0 if light.blend_mode == LitSpotLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_SPOT := 2.0

	# Texel 0: uv.x | uv.y | range | energy
	img.set_pixel(0, row, Color(uv.x, uv.y, light.range, light.energy))
	# Texel 1: color.r | color.g | color.b | height
	img.set_pixel(1, row, Color(light.color.r, light.color.g, light.color.b, light.height))
	# Texel 2: shadow_color.rgb | shadow_hardness
	img.set_pixel(2, row, Color(light.shadow_color.r, light.shadow_color.g, light.shadow_color.b, light.shadow_hardness))
	# Texel 3: type | flags | light_mask | falloff
	img.set_pixel(3, row, Color(TYPE_SPOT, flags, float(light.light_mask), light.falloff))
	# Texel 4: aim.x | aim.y | cos_outer | cos_inner
	img.set_pixel(4, row, Color(aim_px.x, aim_px.y, cos_outer, cos_inner))


## True if a light's `range`-expanded AABB intersects the visible world rect.
func _aabb_visible(pos: Vector2, light_range: float, world_rect: Rect2) -> bool:
	var aabb := Rect2(pos - Vector2(light_range, light_range), Vector2(light_range * 2.0, light_range * 2.0))
	return world_rect.intersects(aabb)


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
