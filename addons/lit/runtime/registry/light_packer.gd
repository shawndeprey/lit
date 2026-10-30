extends RefCounted

## Packs a per-light record into one row of an RGBAF texture. Flags bits 20-21 are the type:
##  0 point:       texel 1 is a screen-UV position.
##  1 directional: texel 1 is a screen-space direction toward the light.
##  2 spot:        texel 1 is a position (as a point); texel 4 adds the cone
##                 (aim direction plus the cosines of the inner and outer angles).
##  3 line:        texel 1 is the node's position (as a point: the cookie's center);
##                 texel 4 adds the segment's half-vector from the node to one end in
##                 screen px, the glow and the tube's half width (see _pack_line). A
##                 curved line (flags bit 23) packs its arc chain and shadow chords into
##                 a row of the path texture instead, and texel 4.xy holds that row and
##                 the arc count (see _pack_path).
## Layout per row: t0 = z code | flags | mask + z code high bits | falloff, t1 = uv/dir | range (directional:
## shadow_reach, world px) | energy, t2 = color.rgb | height,
## t3 = shadow_color.rgb | shadow_hardness, t4 = spot cone / line segment,
## t5 = cookie atlas UV rect, t6 = cookie screen-px-to-UV matrix (texels 5-6 valid only
## when flags bit 2 is set), t7 = shadow source size | samples | jitter | shadow_mask
## (mask packed only while rx receivers exist), t8.xy = cookie UV center (0.5 shifted by
## texture_offset; read only when flags bit 18 is set), t9 = z_min | z_max |
## layer_min | layer_max (written and read only when flags bit 22 is set: a layer range
## narrower than +-4096), t10.x = exempt rect count, t11 = exempt union bounds, t12-15 = the
## light's exempt-occluder canvas rects (t10-t15 read only when flags bit 5 is set).
## flags/mask sit in texel 0 so the shader can mask-reject after a single fetch, and the
## z range rides there too (see range_pack: z_min + 4096 and the low 10 bits of z_max +
## 4096 in t0.x, its high 4 bits in t0.z above the 20-bit mask) so a z-ranged light
## rejects without a second fetch.
## flags: bit 0 shadow_enabled, bit 1 subtractive, bit 2 textured, bits 3-4 shadow
## algorithm (ShadowAlgorithm order on the light nodes), bit 5 shadow exclusions, bits
## 6-17 shadow_length fraction quantized to 12 bits (point/spot: 0 = full march,
## uncapped; directional: plain fraction of shadow_reach, 4095 = full reach), bit 18
## cookie offset, bit 19 z range narrower than +-4096 (texel 0 code), bits 20-21 type,
## bit 22 layer range set (texel 9 written and read), bit 23 curved line (path row).
##
## Path texture (lit_light_path), one PATH_W-wide row per curved line light on screen:
## t0 = a circle enclosing every arc, center.xy (screen px) | radius | shading chord
## count, t1..t33 = arc points (xy screen px, z = the bulge tan(sweep / 4) of the arc
## leaving the point), t33.z = 1 when the chain is closed, t33.w = the chain's length in
## screen px, t34..t65 = the 32 shading chords, t66..t97 = the shadow chords, one per
## packed shadow sample, t98..t113 = the coarse shading chords (the shading chords
## merged in pairs, see _pack_coarse); chords are mid.xy | half.xy in screen px, of equal
## arc length.
##
## Node scale: range, source_radius, width and the FIT_RANGE cookie footprint pack multiplied
## by the node's global scale (larger basis axis, snapped to 1 for unscaled nodes);
## height does not, matching Godot's Light2D.

const LitCookieAtlasScript := preload("res://addons/lit/runtime/lit_cookie_atlas.gd")
const FrameContext := preload("res://addons/lit/runtime/registry/frame_context.gd")
const LinePathScript := preload("res://addons/lit/runtime/registry/line_path.gd")

var _texture: ImageTexture
var _dummy: ImageTexture

# Atlas for the lights' cookie textures. _cookies_active is false when no visible light
# has a texture this frame, letting _pack_cookie bail before any property access;
# _published_cookie_tex gates the global publish to actual atlas changes.
var _cookie_atlas: LitCookieAtlas = LitCookieAtlasScript.new()
var _cookies_active := false
var _published_cookie_tex: Texture2D = null
# Same gate for the light-data texture: re-setting a texture global dirties every
# material declaring it (a per-material main-thread walk in the RenderingServer), so
# publish only when the texture OBJECT changes; contents flow through update().
var _published_light_tex: Texture2D = null

# Reused scratch for packing: write floats straight into _pack_buf and upload once,
# instead of per-texel Image.set_pixel calls. _pack_img is kept across frames and only
# reallocated when the light count or row width changes.
var _pack_buf: PackedFloat32Array = PackedFloat32Array()
var _pack_img: Image
var _pack_img_count: int = -1
# Curved line lights: PATH_W texels per row (circle, 33 arc points, 32 shading chords,
# 32 shadow chords, 16 coarse shading chords), rows appended as the pack meets them,
# each light's row rebuilt only when its inputs changed (the light keeps its last row).
# The texture keeps its high-water height and is uploaded only when a row or the row
# order changed.
const PATH_W := 114
const PATH_INFO := 33
const PATH_CHORDS := 34
const PATH_SHADE := 32
const PATH_SHADOW := 66
const PATH_COARSE := 98
const PATH_SHRINK_FRAMES := 120
var _path_buf: PackedFloat32Array = PackedFloat32Array()
var _path_rows := 0
var _path_zero_row: PackedFloat32Array = PackedFloat32Array()
var _path_ids := PackedInt64Array()
var _path_ids_last := PackedInt64Array()
var _path_changed := false
var _path_alloc := 0
var _path_slack := 0
var _path_img: Image
var _path_tex: ImageTexture
var _published_path_tex: Texture2D = null
# Per-frame mirrors of facade-owned frame state, assigned at pack_and_publish entry.
var _tpl := 9
var _excl_active := false
var _read_ranges := false
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
	_read_ranges = ctx.read_ranges
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
	_path_begin()
	var kinds: PackedByteArray = ctx.kinds
	for i in count:
		var kind := kinds[i]
		if kind == 0:
			_pack_point(i, visible[i] as LitPointLight2D, canvas_xform, vp_size)
		elif kind == 1:
			_pack_directional(i, visible[i] as LitDirectionalLight2D, canvas_xform)
		elif kind == 2:
			_pack_spot(i, visible[i] as LitSpotLight2D, canvas_xform, vp_size)
		else:
			_pack_line(i, visible[i] as LitLineLight2D, canvas_xform, vp_size)
	_upload_pack_buffer(count)
	_upload_path_buffer()

	# Publish globals.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_directional_count", dir_count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	if _texture != _published_light_tex:
		_published_light_tex = _texture
		RenderingServer.global_shader_parameter_set("lit_light_data", _texture)


## Zero-light publish: count 0 plus a 1x1 dummy (never a 4x0 image), no cookies.
func publish_empty(vp_size: Vector2) -> void:
	RenderingServer.global_shader_parameter_set("lit_light_count", 0)
	RenderingServer.global_shader_parameter_set("lit_directional_count", 0)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	var dummy := _get_dummy()
	if dummy != _published_light_tex:
		_published_light_tex = dummy
		RenderingServer.global_shader_parameter_set("lit_light_data", dummy)
	_cookie_atlas.refresh([])
	_cookies_active = false
	_publish_cookie_atlas()
	_path_begin()
	_upload_path_buffer()


## The texel 0 part of a light's ranges, kept by the light's setters in `range_pack`:
## (t0.x z code, t0.z high bits, flags bits), zero when every range is pass-all. With
## both z bounds offset by 4096 (0..8192), t0.x = z_min | low 10 bits of z_max << 14 and
## t0.z bits 20-23 (above the 20-bit mask) = high 4 bits of z_max; the flags carry bit
## 19 when the z range is narrower than +-4096 and bit 22 when the layer range is,
## each read by the shader on its own.
static func range_pack(z_min: int, z_max: int, l_min: int, l_max: int) -> Vector3:
	var z_set := z_min > -4096 or z_max < 4096
	var layered := l_min > -4096 or l_max < 4096
	if not z_set and not layered:
		return Vector3.ZERO
	var a := clampi(z_min, -4096, 4096) + 4096
	var b := clampi(z_max, -4096, 4096) + 4096
	return Vector3(float(a | ((b & 1023) << 14)), float((b >> 10) << 20),
			(524288.0 if z_set else 0.0) + (4194304.0 if layered else 0.0))


## Pack texel 9 (the four ranges) for a light whose `range_pack` carries a layer range
## (flags bit 22); the texel 0 part is written inline by the per-type packers.
func _pack_layer_range(o: int, light: Node2D) -> void:
	_pack_buf[o + 36] = float(light.range_z_min)
	_pack_buf[o + 37] = float(light.range_z_max)
	_pack_buf[o + 38] = float(light.range_layer_min)
	_pack_buf[o + 39] = float(light.range_layer_max)

## Pack texels 10-15 (exempt rect count, union bounds, up to 4 exempt rects) for a
## light with exclusions; returns the flags bit. Lights without exclusions pay one
## has() here.
func _pack_excl(o: int, light: Node2D) -> float:
	if not _excl_info.has(light):
		return 0.0
	var entry = _excl_lists.get("%d_%d" % [light.shadow_mask, _excl_info[light]])
	if entry == null:
		return 0.0
	_pack_buf[o + 40] = float(entry[0])
	var union: Rect2 = entry[1]
	_pack_buf[o + 44] = union.position.x
	_pack_buf[o + 45] = union.position.y
	_pack_buf[o + 46] = union.end.x
	_pack_buf[o + 47] = union.end.y
	var rects: PackedVector4Array = entry[2]
	for j in 4:
		var v := rects[j]
		var b := o + 48 + j * 4
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
	var xf := light.global_transform
	var screen_px: Vector2 = canvas_xform * xf.origin
	var uv := screen_px / vp_size
	var s := maxf(xf.x.length(), xf.y.length())
	if absf(s - 1.0) < 1e-5:
		s = 1.0

	# Four floats per texel; o is the float offset of this light's first texel.
	var o := row * _tpl * 4

	# Integer fields stored as plain floats, decoded with int(round(...)) in the shader.
	var subtractive := 1.0 if light.blend_mode == LitPointLight2D.BlendMode.SUBTRACT else 0.0
	# Texel 0: z code | flags + type | light_mask + z code high bits | falloff
	var rp: Vector3 = light.range_pack
	_pack_buf[o + 0] = rp.x
	_pack_buf[o + 2] = float(light.light_mask & 1048575) + rp.y
	if rp.z >= 4194304.0 and _read_ranges:
		_pack_layer_range(o, light)
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + rp.z \
			+ _pack_cookie(o, light, canvas_xform, xf, s) \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ _pack_shadow_length(light.shadow_length)
	const TYPE_POINT := 0.0
	_pack_buf[o + 1] = flags + TYPE_POINT
	_pack_buf[o + 3] = light.falloff

	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range * s
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
	_pack_buf[o + 28] = light.source_radius * s
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
	# Texel 0: z code | flags + type | light_mask + z code high bits | (falloff unused)
	var rp: Vector3 = light.range_pack
	_pack_buf[o + 0] = rp.x
	_pack_buf[o + 2] = float(light.light_mask & 1048575) + rp.y
	if rp.z >= 4194304.0 and _read_ranges:
		_pack_layer_range(o, light)
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + rp.z \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ 64.0 * roundf(clampf(light.shadow_length, 0.0, 1.0) * 4095.0)
	const TYPE_DIRECTIONAL := 1048576.0
	_pack_buf[o + 1] = flags + TYPE_DIRECTIONAL
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
	var xf := light.global_transform
	var screen_px: Vector2 = canvas_xform * xf.origin
	var uv := screen_px / vp_size
	var s := maxf(xf.x.length(), xf.y.length())
	if absf(s - 1.0) < 1e-5:
		s = 1.0

	# Aim direction in screen space (camera rotation and zoom carry through).
	var aim_px := canvas_xform.basis_xform(Vector2.from_angle(xf.get_rotation()))
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
	# Texel 0: z code | flags + type | light_mask + z code high bits | falloff
	var rp: Vector3 = light.range_pack
	_pack_buf[o + 0] = rp.x
	_pack_buf[o + 2] = float(light.light_mask & 1048575) + rp.y
	if rp.z >= 4194304.0 and _read_ranges:
		_pack_layer_range(o, light)
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + rp.z \
			+ _pack_cookie(o, light, canvas_xform, xf, s) \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ _pack_shadow_length(light.shadow_length)
	const TYPE_SPOT := 2097152.0
	_pack_buf[o + 1] = flags + TYPE_SPOT
	_pack_buf[o + 3] = light.falloff

	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range * s
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
	_pack_buf[o + 28] = light.source_radius * s
	_pack_buf[o + 29] = float(mini(light.shadow_samples, shadow_samples_max))
	_pack_buf[o + 30] = light.shadow_jitter
	if _rx_union_frame != 0:
		_pack_buf[o + 31] = float(light.shadow_mask)

## Pack one line light: a point light (texels 0 to 3, 7) at the node plus its segment
## (texel 4). The segment is centered on the node along its local +X and takes the full
## node transform, so a non-uniform scale stretches it; range and source_radius keep
## the larger-axis rule. A curved line packs its chain into the path texture instead.
func _pack_line(row: int, light: LitLineLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	var xf := light.global_transform
	var screen_px: Vector2 = canvas_xform * xf.origin
	var uv := screen_px / vp_size
	var s := maxf(xf.x.length(), xf.y.length())
	if absf(s - 1.0) < 1e-5:
		s = 1.0
	var curved := light.is_curved()
	var half_world := Vector2.ZERO if curved else xf.basis_xform(Vector2(light.length * 0.5, 0.0))
	var fit_extra := Vector2.ZERO
	if _cookies_active and light.texture != null:
		fit_extra = light.path_extent(xf) if curved else Vector2(half_world.length(), 0.0)

	var o := row * _tpl * 4

	var subtractive := 1.0 if light.blend_mode == LitLineLight2D.BlendMode.SUBTRACT else 0.0
	# Texel 0: z code | flags + type | light_mask + z code high bits | falloff
	var rp: Vector3 = light.range_pack
	_pack_buf[o + 0] = rp.x
	_pack_buf[o + 2] = float(light.light_mask & 1048575) + rp.y
	if rp.z >= 4194304.0 and _read_ranges:
		_pack_layer_range(o, light)
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + rp.z \
			+ _pack_cookie(o, light, canvas_xform, xf, s, fit_extra) \
			+ 8.0 * float(light.shadow_algorithm) \
			+ (_pack_excl(o, light) if _excl_active else 0.0) \
			+ _pack_shadow_length(light.shadow_length) \
			+ (8388608.0 if curved else 0.0)
	const TYPE_LINE := 3145728.0
	_pack_buf[o + 1] = flags + TYPE_LINE
	_pack_buf[o + 3] = light.falloff

	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range * s
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

	# Texel 4: the half-vector (screen px; a curved line: its path row and arc count),
	# the glow and the tube's half width (world px, scaled like range and kept inside it).
	var half_w := minf(light.width * 0.5, light.range * 0.9) * s
	if curved:
		_pack_path(o, light, canvas_xform * xf * light.path_fit_inv(),
				mini(light.shadow_samples, shadow_samples_max))
	else:
		var half_px := canvas_xform.basis_xform(half_world)
		_pack_buf[o + 16] = half_px.x
		_pack_buf[o + 17] = half_px.y
	_pack_buf[o + 18] = light.glow
	_pack_buf[o + 19] = half_w

	# Texel 7: source_radius | samples | jitter (read only by cone/stochastic shaders)
	_pack_buf[o + 28] = light.source_radius * s
	_pack_buf[o + 29] = float(mini(light.shadow_samples, shadow_samples_max))
	_pack_buf[o + 30] = light.shadow_jitter
	if _rx_union_frame != 0:
		_pack_buf[o + 31] = float(light.shadow_mask)

## Pack the cookie fields (texels 5-6, plus t8.xy under a nonzero texture_offset) for
## the point/spot/line light whose row starts at float offset `o`. Returns the flags
## contribution: 0 untextured, bit 2 for a packed cookie, plus bit 18 when t8.xy
## carries an offset cookie-UV center. Texel 5 is the atlas UV rect. Texel 6 is the
## 2x2 matrix taking a screen-pixel offset from the light's center to a cookie-UV
## offset around that center. `light` is accessed dynamically: the cookie properties
## live on LitPositionalLight2D. `fit_extra` widens a FIT_RANGE footprint along the
## node's local axes (a line light's world half-length, a curved line's extents), so it
## spans the light's box.
func _pack_cookie(o: int, light: Node2D, canvas_xform: Transform2D, xf: Transform2D, s: float,
		fit_extra := Vector2.ZERO) -> float:
	if not _cookies_active:
		return 0.0
	var tex: Texture2D = light.get("texture")
	if tex == null or not _cookie_atlas.has(tex):
		return 0.0

	# Footprint half-extents in world units plus the basis it rotates with. NATIVE (0):
	# the texture's pixel size under the node's full transform. FIT_RANGE (1): spans
	# 2*range (node-scaled), rotates with the node. Values match TextureSizeMode on the
	# light nodes.
	var half: Vector2
	var basis: Transform2D
	if int(light.get("texture_size_mode")) == 1:
		var r: float = float(light.get("range")) * s
		half = (Vector2(r, r) + fit_extra) * float(light.get("texture_scale"))
		basis = canvas_xform * Transform2D(xf.get_rotation(), Vector2.ZERO)
	else:
		half = Vector2(tex.get_size()) * 0.5 * float(light.get("texture_scale"))
		basis = canvas_xform * xf
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

## Pack a curved line light's chain into the next path row: `pxf` maps its fit space to
## screen px (every point and apex through it, each bulge refitted through its apex, so
## a non-uniform node scale still lands on arcs), a circle enclosing every arc for the
## range reject and the shadow gates and its `n` equal-length chords for the strata.
## Texel 4.xy of the light's own row holds the path row and the arc count. A row whose
## inputs match the light's memo is appended from it instead of rebuilt.
func _pack_path(o: int, light: LitLineLight2D, pxf: Transform2D, n: int) -> void:
	var row := _path_rows
	_path_rows += 1
	_path_ids.append(light.get_instance_id())
	_pack_buf[o + 16] = float(row)
	if light.path_row_same(pxf, n):
		_path_buf.append_array(light.path_row())
		_pack_buf[o + 17] = float(light.path_row_arcs())
		return
	_path_changed = true
	_path_buf.append_array(_path_zero_row)
	var chain = light.path_chain()
	var base := row * PATH_W * 4
	var fit_rect: Rect2 = light.path_fit_rect()
	var center := pxf * fit_rect.get_center()
	var radius := pxf.basis_xform(fit_rect.size * 0.5).length()
	var sx := pxf.x.length_squared()
	var sy := pxf.y.length_squared()
	var smax := maxf(sx, sy)
	if smax <= 0.0 or absf(sx - sy) > 1e-5 * smax or absf(pxf.x.dot(pxf.y)) > 1e-5 * smax:
		var sr: Rect2 = LinePathScript.bounds(LinePathScript.transformed(chain, pxf))
		center = sr.get_center()
		radius = (sr.size * 0.5).length()
	_path_buf[base] = center.x
	_path_buf[base + 1] = center.y
	_path_buf[base + 2] = radius
	var fit_pts: PackedVector2Array = chain.points
	var fit_apexes: PackedVector2Array = chain.apexes
	var pts := pxf * fit_pts
	var apexes := pxf * fit_apexes
	var arcs: int = chain.arc_count()
	var prev := pts[0]
	_path_buf[base + 4] = prev.x
	_path_buf[base + 5] = prev.y
	for k in arcs:
		var p := pts[k + 1]
		var b := base + 4 * (k + 1)
		_path_buf[b + 2] = LinePathScript.bulge_through(prev, p, apexes[k])
		_path_buf[b + 4] = p.x
		_path_buf[b + 5] = p.y
		prev = p
	var shade: PackedVector2Array = light.path_shade_chords(PATH_SHADE)
	_path_buf[base + 3] = float(shade.size() - 1)
	_path_buf[base + 4 * PATH_INFO + 2] = 1.0 if light.closed else 0.0
	_path_buf[base + 4 * PATH_INFO + 3] = _pack_chords(base + 4 * PATH_CHORDS, shade, pxf)
	_pack_coarse(base + 4 * PATH_CHORDS, shade.size() - 1, base + 4 * PATH_COARSE)
	_pack_chords(base + 4 * PATH_SHADOW, light.path_chords(n), pxf)
	_pack_buf[o + 17] = float(arcs)
	light.path_row_store(_path_buf.slice(base, base + PATH_W * 4), pxf, n, arcs)

## Chords mid | half in screen px from `cuts`; returns their total length.
func _pack_chords(at: int, cuts: PackedVector2Array, pxf: Transform2D) -> float:
	var pts := pxf * cuts
	var prev := pts[0]
	var total := 0.0
	for k in pts.size() - 1:
		var p := pts[k + 1]
		var b := at + 4 * k
		_path_buf[b] = (prev.x + p.x) * 0.5
		_path_buf[b + 1] = (prev.y + p.y) * 0.5
		_path_buf[b + 2] = (p.x - prev.x) * 0.5
		_path_buf[b + 3] = (p.y - prev.y) * 0.5
		total += prev.distance_to(p)
		prev = p
	return total

## The coarse shading chords at `at`: the `count` chords at `from` merged in pairs, each
## pair one chord of their summed length through the length-weighted mean of their
## midpoints along the sum of their half-vectors (an odd last chord copied). Read by the
## shader past LIT_PATH_LOD_K bounding radii, only when count exceeds PATH_SHADE / 2.
func _pack_coarse(from: int, count: int, at: int) -> void:
	if count <= PATH_SHADE >> 1:
		return
	for k in count >> 1:
		var a := from + 8 * k
		var ax := _path_buf[a + 2]
		var ay := _path_buf[a + 3]
		var bx := _path_buf[a + 6]
		var by := _path_buf[a + 7]
		var la := 2.0 * sqrt(ax * ax + ay * ay)
		var lb := 2.0 * sqrt(bx * bx + by * by)
		var l := la + lb
		var dx := ax + bx
		var dy := ay + by
		var dl := sqrt(dx * dx + dy * dy)
		if dl < 1e-6:
			dx = ax
			dy = ay
			dl = 0.5 * la
		var s := 0.5 * l / maxf(dl, 1e-6)
		var il := 1.0 / maxf(l, 1e-6)
		var b := at + 4 * k
		_path_buf[b] = (_path_buf[a] * la + _path_buf[a + 4] * lb) * il
		_path_buf[b + 1] = (_path_buf[a + 1] * la + _path_buf[a + 5] * lb) * il
		_path_buf[b + 2] = dx * s
		_path_buf[b + 3] = dy * s
	if count % 2 == 1:
		var a := from + 4 * (count - 1)
		var b := at + 4 * (count >> 1)
		for j in 4:
			_path_buf[b + j] = _path_buf[a + j]

## Start a frame's path rows.
func _path_begin() -> void:
	_path_rows = 0
	_path_changed = false
	_path_ids.clear()
	_path_buf.clear()
	if _path_zero_row.size() != PATH_W * 4:
		_path_zero_row.resize(PATH_W * 4)
		_path_zero_row.fill(0.0)

## Upload the path rows (PATH_W x rows RGBAF) when a row or the row order changed. The
## texture keeps its high-water height and shrinks only after PATH_SHRINK_FRAMES frames
## at half of it or less; the 1x1 dummy stands in while there is none.
func _upload_path_buffer() -> void:
	var rows := _path_alloc
	if _path_rows > rows:
		rows = _path_rows
		_path_slack = 0
	elif _path_rows * 2 <= rows:
		_path_slack += 1
		if _path_slack >= PATH_SHRINK_FRAMES:
			rows = _path_rows
			_path_slack = 0
	else:
		_path_slack = 0
	var same := not _path_changed and rows == _path_alloc and _path_ids == _path_ids_last
	_path_ids_last = _path_ids.duplicate()
	_path_alloc = rows
	if rows == 0:
		_path_img = null
		_path_tex = null
	elif not same and _path_rows > 0:
		_path_buf.resize(rows * PATH_W * 4)
		var bytes := _path_buf.to_byte_array()
		if _path_img == null or _path_img.get_height() != rows:
			_path_img = Image.create_from_data(PATH_W, rows, false, Image.FORMAT_RGBAF, bytes)
		else:
			_path_img.set_data(PATH_W, rows, false, Image.FORMAT_RGBAF, bytes)
		if _path_tex == null or _path_tex.get_size() != Vector2(PATH_W, rows):
			_path_tex = ImageTexture.create_from_image(_path_img)
		else:
			_path_tex.update(_path_img)
	var tex: Texture2D = _path_tex if _path_tex != null else _get_dummy()
	if tex != _published_path_tex:
		_published_path_tex = tex
		RenderingServer.global_shader_parameter_set("lit_light_path", tex)

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
