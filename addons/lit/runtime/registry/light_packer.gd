extends RefCounted

## Packs a per-light record into one row of an RGBAF texture. Texel 0.r is the type:
##  0 point:       texel 1 is a screen-UV position.
##  1 directional: texel 1 is a screen-space direction toward the light.
##  2 spot:        texel 1 is a position (as a point); texel 4 adds the cone
##                 (aim direction plus the cosines of the inner and outer angles).
## Layout per row: t0 = type | flags | mask | falloff, t1 = uv/dir | range (directional:
## shadow_reach, world px) | energy, t2 = color.rgb | height,
## t3 = shadow_color.rgb | shadow_hardness, t4 = spot cone,
## t5 = cookie atlas UV rect, t6 = cookie screen-px-to-UV matrix (texels 5-6 valid only
## when flags bit 2 is set), t7 = shadow source size | samples | jitter | shadow_mask
## (mask packed only while rx receivers exist), t8.xy = cookie UV center (0.5 shifted by
## texture_offset; read only when flags bit 18 is set), t9.x = exempt rect count,
## t10 = exempt union bounds, t11-14 = the light's exempt-occluder canvas rects
## (t9-t14 read only when flags bit 5 is set). type/flags/mask sit in texel 0 so the
## shader can mask-reject after a single fetch. flags: bit 0 shadow_enabled, bit 1
## subtractive, bit 2 textured, bits 3-4 shadow algorithm (ShadowAlgorithm order on the
## light nodes), bit 5 shadow exclusions, bits 6-17 shadow_length fraction quantized to
## 12 bits (point/spot: 0 = full march, uncapped; directional: plain fraction of
## shadow_reach, 4095 = full reach), bit 18 cookie offset.

const LitCookieAtlasScript := preload("res://addons/lit/runtime/lit_cookie_atlas.gd")
const FrameContext := preload("res://addons/lit/runtime/registry/frame_context.gd")

var _texture: ImageTexture
var _dummy: ImageTexture

# Atlas for the lights' cookie textures. _cookies_active is false when no visible light
# has a texture this frame, letting _pack_cookie bail before any property access;
# _published_cookie_tex gates the global publish to actual atlas changes.
var _cookie_atlas: LitCookieAtlas = LitCookieAtlasScript.new()
var _cookies_active := false
var _published_cookie_tex: Texture2D = null

# Reused scratch for packing: write floats straight into _pack_buf and upload once,
# instead of per-texel Image.set_pixel calls. _pack_img is kept across frames and only
# reallocated when the light count or row width changes.
var _pack_buf: PackedFloat32Array = PackedFloat32Array()
var _pack_img: Image
var _pack_img_count: int = -1
# Per-frame mirrors of facade-owned frame state, assigned at pack_and_publish entry.
var _tpl := 9
var _excl_active := false
var _excl_info := {}
var _excl_lists := {}
var _rx_union_frame := 0
var shadow_samples_max := 32


## Pack ctx.visible (ordered directionals-first) into the data texture and publish it.
func pack_and_publish(ctx: FrameContext, excl_info: Dictionary, excl_lists: Dictionary,
		samples_max: int) -> void:
	var visible: Array = ctx.visible
	var positional: Array = ctx.positional
	var dir_count: int = ctx.dir_count
	var canvas_xform: Transform2D = ctx.canvas_xform
	var vp_size: Vector2 = ctx.vp_size
	_tpl = ctx.texels_per_light
	_excl_active = ctx.excl_active
	_excl_info = excl_info
	_excl_lists = excl_lists
	_rx_union_frame = ctx.rx_union
	shadow_samples_max = samples_max
	var count := visible.size()

	# Refresh and publish the cookie atlas before packing, which reads its rects.
	var cookie_textures: Array = []
	for l in positional:
		var cookie: Texture2D = l.texture
		if cookie != null and not cookie_textures.has(cookie):
			cookie_textures.append(cookie)
	_cookie_atlas.refresh(cookie_textures)
	_cookies_active = not cookie_textures.is_empty()
	_publish_cookie_atlas()

	# Pack each light into one _tpl-wide row of the float buffer.
	var floats_needed := count * _tpl * 4
	if _pack_buf.size() != floats_needed:
		_pack_buf.resize(floats_needed)
	_pack_buf.fill(0.0)
	for i in count:
		var directional := visible[i] as LitDirectionalLight2D
		if directional != null:
			_pack_directional(i, directional, canvas_xform)
			continue
		var spot := visible[i] as LitSpotLight2D
		if spot != null:
			_pack_spot(i, spot, canvas_xform, vp_size)
			continue
		_pack_point(i, visible[i] as LitPointLight2D, canvas_xform, vp_size)
	_upload_pack_buffer(count)

	# Publish globals.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_directional_count", dir_count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	RenderingServer.global_shader_parameter_set("lit_light_data", _texture)


## Zero-light publish: count 0 plus a 1x1 dummy (never a 4x0 image), no cookies.
func publish_empty(vp_size: Vector2) -> void:
	RenderingServer.global_shader_parameter_set("lit_light_count", 0)
	RenderingServer.global_shader_parameter_set("lit_directional_count", 0)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	RenderingServer.global_shader_parameter_set("lit_light_data", _get_dummy())
	_cookie_atlas.refresh([])
	_cookies_active = false
	_publish_cookie_atlas()


## Pack texels 9-14 (exempt rect count, union bounds, up to 4 exempt rects) for a light
## with exclusions; returns the flags bit. Lights without exclusions pay one has() here.
func _pack_excl(o: int, light: Node2D) -> float:
	if not _excl_info.has(light):
		return 0.0
	var entry = _excl_lists.get("%d_%d" % [light.shadow_mask, _excl_info[light]])
	if entry == null:
		return 0.0
	_pack_buf[o + 36] = float(entry[0])
	var union: Rect2 = entry[1]
	_pack_buf[o + 40] = union.position.x
	_pack_buf[o + 41] = union.position.y
	_pack_buf[o + 42] = union.end.x
	_pack_buf[o + 43] = union.end.y
	var rects: PackedVector4Array = entry[2]
	for j in 4:
		var v := rects[j]
		var b := o + 44 + j * 4
		_pack_buf[b] = v.x
		_pack_buf[b + 1] = v.y
		_pack_buf[b + 2] = v.z
		_pack_buf[b + 3] = v.w
	return 32.0

## Point/spot shadow_length fraction, quantized to 12 bits and pre-shifted into flags
## bits 6-17. A full-length fraction packs 0, keeping default rows bit-identical.
func _pack_shadow_length(frac: float) -> float:
	if frac >= 1.0:
		return 0.0
	return 64.0 * roundf(clampf(frac, 0.01, 1.0) * 4095.0)

## Pack one point light into the row starting at `row` in _pack_buf.
func _pack_point(row: int, light: LitPointLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	# Position to normalized screen UV, the one canonical space.
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Four floats per texel; o is the float offset of this light's first texel.
	var o := row * _tpl * 4

	# Integer fields stored as plain floats, decoded with int(round(...)) in the shader.
	var subtractive := 1.0 if light.blend_mode == LitPointLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive \
			+ _pack_cookie(o, light, canvas_xform) \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ _pack_shadow_length(light.shadow_length)
	const TYPE_POINT := 0.0

	# Texel 0: type | flags | light_mask | falloff
	_pack_buf[o + 0] = TYPE_POINT
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = light.falloff

	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range
	_pack_buf[o + 7] = light.energy

	# Texel 2: color.rgb | height
	_pack_buf[o + 8] = light.color.r
	_pack_buf[o + 9] = light.color.g
	_pack_buf[o + 10] = light.color.b
	_pack_buf[o + 11] = light.height

	# Texel 3: shadow_color.rgb | shadow_hardness
	_pack_buf[o + 12] = light.shadow_color.r
	_pack_buf[o + 13] = light.shadow_color.g
	_pack_buf[o + 14] = light.shadow_color.b
	_pack_buf[o + 15] = light.shadow_hardness

	# Texel 7: source_radius | samples | jitter (read only by cone/stochastic shaders)
	_pack_buf[o + 28] = light.source_radius
	_pack_buf[o + 29] = float(mini(light.shadow_samples, shadow_samples_max))
	_pack_buf[o + 30] = light.shadow_jitter
	if _rx_union_frame != 0:
		_pack_buf[o + 31] = float(light.shadow_mask)

## Pack one directional light. Texel 1 carries a normalized direction toward the light
## in screen-pixel space instead of a UV position; range and falloff are unused.
func _pack_directional(row: int, light: LitDirectionalLight2D, canvas_xform: Transform2D) -> void:
	# The node's local +X (its rotation) is the direction the light travels, so the
	# direction toward the source is the opposite. Convert to screen space via the
	# canvas basis, which carries camera rotation and zoom through.
	var aim_world := Vector2.from_angle(light.global_rotation)
	var dir_px := canvas_xform.basis_xform(-aim_world)
	if dir_px.length() > 0.0:
		dir_px = dir_px.normalized()

	var subtractive := 1.0 if light.blend_mode == LitDirectionalLight2D.BlendMode.SUBTRACT else 0.0
	var o := row * _tpl * 4
	var flags := float(light.shadow_enabled) + 2.0 * subtractive \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ 64.0 * roundf(clampf(light.shadow_length, 0.0, 1.0) * 4095.0)
	const TYPE_DIRECTIONAL := 1.0

	# Texel 0: type | flags | light_mask | (falloff unused)
	_pack_buf[o + 0] = TYPE_DIRECTIONAL
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = 1.0

	# Texel 1: dir.x | dir.y | shadow_reach (world px) | energy
	_pack_buf[o + 4] = dir_px.x
	_pack_buf[o + 5] = dir_px.y
	_pack_buf[o + 6] = maxf(light.shadow_reach, 0.0)
	_pack_buf[o + 7] = light.energy

	# Texel 2: color.rgb | height
	_pack_buf[o + 8] = light.color.r
	_pack_buf[o + 9] = light.color.g
	_pack_buf[o + 10] = light.color.b
	_pack_buf[o + 11] = light.height

	# Texel 3: shadow_color.rgb | shadow_hardness
	_pack_buf[o + 12] = light.shadow_color.r
	_pack_buf[o + 13] = light.shadow_color.g
	_pack_buf[o + 14] = light.shadow_color.b
	_pack_buf[o + 15] = light.shadow_hardness

	# Texel 7: tan(source half-angle) | samples | jitter. source_angle is the full
	# angular diameter (the cross-engine convention), halved here to the tangent the
	# cone/stochastic shaders use directly (a directional light has no distance to
	# derive it from).
	_pack_buf[o + 28] = tan(deg_to_rad(light.source_angle) * 0.5)
	_pack_buf[o + 29] = float(mini(light.shadow_samples, shadow_samples_max))
	_pack_buf[o + 30] = light.shadow_jitter
	if _rx_union_frame != 0:
		_pack_buf[o + 31] = float(light.shadow_mask)

## Pack one spot light: a point light (texels 0 to 3) plus a cone (texel 4). The node's
## local +X (its rotation) is the direction the cone aims.
func _pack_spot(row: int, light: LitSpotLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Aim direction in screen space (camera rotation and zoom carry through).
	var aim_px := canvas_xform.basis_xform(Vector2.from_angle(light.global_rotation))
	if aim_px.length() > 0.0:
		aim_px = aim_px.normalized()

	# Cone as cosines: cos(outer) is the edge, cos(inner) the fully-lit core.
	# spot_softness feathers the core inward; keep inner strictly inside outer so the
	# shader's smoothstep never divides by zero.
	var cos_outer := cos(deg_to_rad(light.spot_angle))
	var cos_inner := cos(deg_to_rad(light.spot_angle * (1.0 - light.spot_softness)))
	if cos_inner <= cos_outer:
		cos_inner = cos_outer + 0.0001

	var o := row * _tpl * 4

	var subtractive := 1.0 if light.blend_mode == LitSpotLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive \
			+ _pack_cookie(o, light, canvas_xform) \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ _pack_shadow_length(light.shadow_length)
	const TYPE_SPOT := 2.0

	# Texel 0: type | flags | light_mask | falloff
	_pack_buf[o + 0] = TYPE_SPOT
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = light.falloff

	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range
	_pack_buf[o + 7] = light.energy

	# Texel 2: color.rgb | height
	_pack_buf[o + 8] = light.color.r
	_pack_buf[o + 9] = light.color.g
	_pack_buf[o + 10] = light.color.b
	_pack_buf[o + 11] = light.height

	# Texel 3: shadow_color.rgb | shadow_hardness
	_pack_buf[o + 12] = light.shadow_color.r
	_pack_buf[o + 13] = light.shadow_color.g
	_pack_buf[o + 14] = light.shadow_color.b
	_pack_buf[o + 15] = light.shadow_hardness

	# Texel 4: aim.x | aim.y | cos_outer | cos_inner
	_pack_buf[o + 16] = aim_px.x
	_pack_buf[o + 17] = aim_px.y
	_pack_buf[o + 18] = cos_outer
	_pack_buf[o + 19] = cos_inner

	# Texel 7: source_radius | samples | jitter (read only by cone/stochastic shaders)
	_pack_buf[o + 28] = light.source_radius
	_pack_buf[o + 29] = float(mini(light.shadow_samples, shadow_samples_max))
	_pack_buf[o + 30] = light.shadow_jitter
	if _rx_union_frame != 0:
		_pack_buf[o + 31] = float(light.shadow_mask)

## Pack the cookie fields (texels 5-6, plus t8.xy under a nonzero texture_offset) for
## the point/spot light whose row starts at float offset `o`. Returns the flags
## contribution: 0 untextured, bit 2 for a packed cookie, plus bit 18 when t8.xy
## carries an offset cookie-UV center. Texel 5 is the atlas UV rect. Texel 6 is the
## 2x2 matrix taking a screen-pixel offset from the light's center to a cookie-UV
## offset around that center. `light` is accessed dynamically: the cookie properties
## live on both LitPointLight2D and LitSpotLight2D.
func _pack_cookie(o: int, light: Node2D, canvas_xform: Transform2D) -> float:
	if not _cookies_active:
		return 0.0
	var tex: Texture2D = light.get("texture")
	if tex == null or not _cookie_atlas.has(tex):
		return 0.0

	# Footprint half-extents in world units plus the basis it rotates with. NATIVE (0):
	# the texture's pixel size under the node's full transform. FIT_RANGE (1): spans
	# 2*range, rotates with the node, ignores node scale. Values match TextureSizeMode
	# on the light nodes.
	var half: Vector2
	var basis: Transform2D
	if int(light.get("texture_size_mode")) == 1:
		var r: float = float(light.get("range"))
		half = Vector2(r, r) * float(light.get("texture_scale"))
		basis = canvas_xform * Transform2D(light.global_rotation, Vector2.ZERO)
	else:
		half = Vector2(tex.get_size()) * 0.5 * float(light.get("texture_scale"))
		basis = canvas_xform * light.get_global_transform()
	basis = Transform2D(basis.x, basis.y, Vector2.ZERO)  # offsets only; drop translation
	if half.x <= 0.0 or half.y <= 0.0 or absf(basis.determinant()) < 1e-8:
		return 0.0  # degenerate footprint

	# cookie_uv_offset = diag(1 / (2 * half)) * basis^-1 * screen_px_offset
	var inv := basis.affine_inverse()
	var sx := 0.5 / half.x
	var sy := 0.5 / half.y

	# Texel 5: atlas UV rect - min.x | min.y | size.x | size.y
	var rect := _cookie_atlas.get_uv_rect(tex)
	_pack_buf[o + 20] = rect.position.x
	_pack_buf[o + 21] = rect.position.y
	_pack_buf[o + 22] = rect.size.x
	_pack_buf[o + 23] = rect.size.y

	# Texel 6: matrix columns - x.x | x.y | y.x | y.y (the diagonal scales rows)
	_pack_buf[o + 24] = inv.x.x * sx
	_pack_buf[o + 25] = inv.x.y * sy
	_pack_buf[o + 26] = inv.y.x * sx
	_pack_buf[o + 27] = inv.y.y * sy

	# Texel 8: texture_offset, in the same local units as `half`, baked into the
	# cookie-UV center the shader would otherwise fix at 0.5.
	var offset: Vector2 = light.get("texture_offset")
	if offset == Vector2.ZERO:
		return 4.0
	_pack_buf[o + 32] = 0.5 - offset.x * sx
	_pack_buf[o + 33] = 0.5 - offset.y * sy
	return 4.0 + 262144.0

## Publish the cookie atlas global only when the atlas texture object changed.
func _publish_cookie_atlas() -> void:
	var tex := _cookie_atlas.get_texture()
	if tex != _published_cookie_tex:
		_published_cookie_tex = tex
		RenderingServer.global_shader_parameter_set("lit_cookie_atlas", tex)

## Upload _pack_buf (_tpl x count RGBAF) to the light-data texture, reusing the Image
## and ImageTexture across frames and only reallocating when count or width changes.
func _upload_pack_buffer(count: int) -> void:
	var bytes := _pack_buf.to_byte_array()
	if _pack_img == null or _pack_img_count != count or _pack_img.get_width() != _tpl:
		_pack_img = Image.create_from_data(_tpl, count, false, Image.FORMAT_RGBAF, bytes)
		_pack_img_count = count
	else:
		_pack_img.set_data(_tpl, count, false, Image.FORMAT_RGBAF, bytes)

	if _texture == null or _texture.get_size() != Vector2(_tpl, count):
		_texture = ImageTexture.create_from_image(_pack_img)
	else:
		_texture.update(_pack_img)

## 1x1 RGBAF texture published as the light data when there are no lights, so the
## sampler global is always valid.
func _get_dummy() -> ImageTexture:
	if _dummy == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
		img.set_pixel(0, 0, Color(0, 0, 0, 0))
		_dummy = ImageTexture.create_from_image(img)
	return _dummy
