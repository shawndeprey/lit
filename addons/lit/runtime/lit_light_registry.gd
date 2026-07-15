extends RefCounted
class_name LitLightRegistry

## Shared gather / cull / pack logic.
##
## Driven by lit_manager.gd (the autoload) at runtime, and by lit_plugin.gd for
## editor-live preview. Both call the same refresh().
##
## Each instance owns its own light-data texture, so the editor and a running game
## (separate processes and RenderingServer state) never collide.
##
## Packs a per-light record into one row of an RGBAF texture. Texel 0.r is the type:
##  0 point:       texel 1 is a screen-UV position.
##  1 directional: texel 1 is a screen-space direction toward the light.
##  2 spot:        texel 1 is a position (as a point); texel 4 adds the cone
##                 (aim direction plus the cosines of the inner and outer angles).
## Layout per row: t0 = type | flags | mask | falloff, t1 = uv/dir | range | energy,
## t2 = color.rgb | height, t3 = shadow_color.rgb | shadow_hardness, t4 = spot cone,
## t5 = cookie atlas UV rect, t6 = cookie screen-px-to-UV matrix (texels 5-6 valid only
## when flags bit 2 is set). type/flags/mask sit in texel 0 so the shader can
## mask-reject after a single fetch.

const LitCookieAtlasScript := preload("res://addons/lit/runtime/lit_cookie_atlas.gd")

const TEXELS_PER_LIGHT := 7

# Screen tile edge in pixels for the light-culling grid. Must match the shader's tile
# math (it divides SCREEN_UV * viewport by lit_tile_size).
const TILE_SIZE := 64

# Width of the flat tile-index texture; a flat index maps to (i % WIDTH, i / WIDTH).
# Must match LIT_INDEX_TEX_WIDTH in lit_receiver.gdshader.
const INDEX_TEX_WIDTH := 2048

var _texture: ImageTexture
var _dummy: ImageTexture

var _tile_header_tex: ImageTexture
var _tile_index_tex: ImageTexture

# Atlas for the lights' cookie textures. _cookies_active is false when no visible light
# has a texture this frame, letting _pack_cookie bail before any property access;
# _published_cookie_tex gates the global publish to actual atlas changes.
var _cookie_atlas: LitCookieAtlas = LitCookieAtlasScript.new()
var _cookies_active := false
var _published_cookie_tex: Texture2D = null

# Reused scratch for packing: write floats straight into _pack_buf and upload once,
# instead of per-texel Image.set_pixel calls. _pack_img is kept across frames and only
# reallocated when the light count changes.
var _pack_buf: PackedFloat32Array = PackedFloat32Array()
var _pack_img: Image
var _pack_img_count: int = -1

# Reused scratch for the tile build: per-tile counts (then write cursors), the accepted
# (tile, light-row) pairs, and the float pixel buffers behind the header/index textures.
# All kept across frames so the per-frame tile build allocates nothing at steady state.
var _tile_counts: PackedInt32Array = PackedInt32Array()
var _pair_tiles: PackedInt32Array = PackedInt32Array()
var _pair_rows: PackedInt32Array = PackedInt32Array()
var _header_buf: PackedFloat32Array = PackedFloat32Array()
var _index_buf: PackedFloat32Array = PackedFloat32Array()
var _header_img: Image
var _index_img: Image

# Cached list of [node, kind] for the lit_lights group, rebuilt only when the tree
# changes (see _get_cached_lights), so refresh() skips a group scan + type dispatch
# every frame.
var _light_cache: Array = []
var _cache_dirty: bool = true
var _cache_tree: SceneTree = null

## Gather visible lights, pack them into the light-data texture, build the tile grid,
## and publish the global shader uniforms. Call once per frame.
func refresh(tree: SceneTree, viewport: Viewport) -> void:
	if tree == null or viewport == null:
		return

	var vp_size: Vector2 = viewport.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return

	# World-to-screen-pixel transform. A Viewport applies global_canvas_transform *
	# canvas_transform to its canvas items, so we need the product, not just
	# canvas_transform. At runtime the global part is identity and the camera lives in
	# canvas_transform; in the editor the view's pan/zoom lives in global_canvas_transform,
	# so canvas_transform alone mis-places lights and drifts them with zoom. The product
	# is correct in both, and feeds positions, the directional/spot basis, and the cull
	# rect alike.
	var canvas_xform := viewport.get_global_canvas_transform() * viewport.get_canvas_transform()
	var world_rect := _visible_world_rect(canvas_xform, vp_size)

	# World-to-screen pixel scale (camera/editor zoom). The shader does point/spot lighting
	# in screen pixels, so it multiplies each light's world-space range and height by this
	# to keep the math identical at any zoom. maxf of the basis axes matches the tiling
	# scale below, so the shader's effective range never exceeds the tiled footprint (a
	# smaller shader scale would just under-light; a larger one would cull lit tiles).
	# Published before the early returns so the uniform is always fresh.
	var canvas_scale := maxf(canvas_xform.x.length(), canvas_xform.y.length())
	RenderingServer.global_shader_parameter_set("lit_canvas_scale", canvas_scale)

	# Collect enabled, visible lights from the cache. Point and spot lights are
	# AABB-culled against the visible world rect; directional lights are never
	# positionally culled. A freed node marks the cache dirty so it rebuilds next frame.
	var lights := _get_cached_lights(tree)
	var visible: Array = []
	for entry in lights:
		var node: Node = entry[0]
		if not is_instance_valid(node):
			_cache_dirty = true
			continue
		var kind: int = entry[1]
		if kind == 1:
			var directional := node as LitDirectionalLight2D
			if directional.enabled and directional.is_visible_in_tree():
				visible.append(directional)
		elif kind == 0:
			var point := node as LitPointLight2D
			if point.enabled and point.is_visible_in_tree() and _aabb_visible(point.global_position, point.range, world_rect):
				visible.append(point)
		else:
			var spot := node as LitSpotLight2D
			if spot.enabled and spot.is_visible_in_tree() and _aabb_visible(spot.global_position, spot.range, world_rect):
				visible.append(spot)

	var count := visible.size()

	# Zero-light case: count 0 plus a 1x1 dummy (never a 4x0 image) and empty tiles.
	if count == 0:
		RenderingServer.global_shader_parameter_set("lit_light_count", 0)
		RenderingServer.global_shader_parameter_set("lit_directional_count", 0)
		RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
		RenderingServer.global_shader_parameter_set("lit_light_data", _get_dummy())
		_cookie_atlas.refresh([])
		_cookies_active = false
		_publish_cookie_atlas()
		_publish_empty_tiles(vp_size)
		return

	# Pack directionals into the leading rows, then positional lights. The shader shades
	# rows [0, dir_count) for every fragment and finds the rest through the tile grid, so
	# this ordering keeps row indices consistent between the data texture and the buckets.
	var directionals: Array = []
	var positional: Array = []
	for l in visible:
		if l is LitDirectionalLight2D:
			directionals.append(l)
		else:
			positional.append(l)
	visible = directionals + positional
	var dir_count := directionals.size()

	# Refresh and publish the cookie atlas before packing, which reads its rects.
	var cookie_textures: Array = []
	for l in positional:
		var cookie: Texture2D = l.texture
		if cookie != null and not cookie_textures.has(cookie):
			cookie_textures.append(cookie)
	_cookie_atlas.refresh(cookie_textures)
	_cookies_active = not cookie_textures.is_empty()
	_publish_cookie_atlas()

	# Pack each light into one TEXELS_PER_LIGHT-wide row of the float buffer.
	var floats_needed := count * TEXELS_PER_LIGHT * 4
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

	# Bin the positional lights into the screen-tile grid the shader culls against.
	_build_tiles(visible, canvas_xform, vp_size, canvas_scale)

	# Publish globals.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_directional_count", dir_count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	RenderingServer.global_shader_parameter_set("lit_light_data", _texture)

## Pack one point light into the row starting at `row` in _pack_buf.
func _pack_point(row: int, light: LitPointLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	# Position to normalized screen UV, the one canonical space.
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Four floats per texel; o is the float offset of this light's first texel.
	var o := row * TEXELS_PER_LIGHT * 4

	# Integer fields stored as plain floats, decoded with int(round(...)) in the shader.
	var subtractive := 1.0 if light.blend_mode == LitPointLight2D.BlendMode.SUBTRACT else 0.0
	var textured := _pack_cookie(o, light, canvas_xform)
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + 4.0 * float(textured)
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
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_DIRECTIONAL := 1.0

	var o := row * TEXELS_PER_LIGHT * 4

	# Texel 0: type | flags | light_mask | (falloff unused)
	_pack_buf[o + 0] = TYPE_DIRECTIONAL
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = 1.0

	# Texel 1: dir.x | dir.y | (range unused) | energy
	_pack_buf[o + 4] = dir_px.x
	_pack_buf[o + 5] = dir_px.y
	_pack_buf[o + 6] = 0.0
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

	var o := row * TEXELS_PER_LIGHT * 4

	var subtractive := 1.0 if light.blend_mode == LitSpotLight2D.BlendMode.SUBTRACT else 0.0
	var textured := _pack_cookie(o, light, canvas_xform)
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + 4.0 * float(textured)
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

## Pack the cookie fields (texels 5-6) for the point/spot light whose row starts at
## float offset `o`. Returns true when the light has a packed cookie; the caller sets
## flags bit 2. Texel 5 is the atlas UV rect. Texel 6 is the 2x2 matrix taking a
## screen-pixel offset from the light's center to a cookie-UV offset around 0.5.
## `light` is accessed dynamically: the cookie properties live on both LitPointLight2D
## and LitSpotLight2D.
func _pack_cookie(o: int, light: Node2D, canvas_xform: Transform2D) -> bool:
	if not _cookies_active:
		return false
	var tex: Texture2D = light.get("texture")
	if tex == null or not _cookie_atlas.has(tex):
		return false

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
		return false  # degenerate footprint

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
	return true

## Publish the cookie atlas global only when the atlas texture object changed.
func _publish_cookie_atlas() -> void:
	var tex := _cookie_atlas.get_texture()
	if tex != _published_cookie_tex:
		_published_cookie_tex = tex
		RenderingServer.global_shader_parameter_set("lit_cookie_atlas", tex)

## Bin each positional light into the tiles its screen footprint touches, then upload a
## per-tile header (offset + count) and a flat index list of light rows. The shader reads
## its own tile's header and shades only those rows. Directionals are skipped (they're
## full-screen and shaded directly).
##
## Culling per tile is exact-but-conservative: a tile is included only if the light's
## range circle overlaps it (not just its square AABB), and a spot's cone must also
## overlap. Excluded (tile, light) pairs are ones the shader would resolve to exactly
## zero anyway (beyond `range`, or where the cone smoothstep is 0), so tightening the
## lists never changes the image - it only removes per-fragment work.
func _build_tiles(visible: Array, canvas_xform: Transform2D, vp_size: Vector2, scale: float) -> void:
	var tiles_x := int(ceil(vp_size.x / float(TILE_SIZE)))
	var tiles_y := int(ceil(vp_size.y / float(TILE_SIZE)))
	tiles_x = max(tiles_x, 1)
	tiles_y = max(tiles_y, 1)
	var tile_count := tiles_x * tiles_y

	# Accepted (tile, light-row) pairs plus per-tile counts, gathered flat and then
	# counting-sorted into the contiguous per-tile layout. No per-tile arrays and no
	# per-pair Image.set_pixel: everything lands in reused packed buffers.
	if _tile_counts.size() != tile_count:
		_tile_counts.resize(tile_count)
	_tile_counts.fill(0)
	_pair_tiles.clear()
	_pair_rows.clear()

	# `scale` is the world-to-screen pixel factor (the larger canvas-basis axis, so a
	# zoomed or non-uniformly scaled view over-includes rather than clips a light's
	# footprint). It matches the shader's lit_canvas_scale, computed once in refresh().

	# Conservative slack, in screen pixels, absorbing any CPU/GPU float disagreement at
	# a footprint's exact boundary (where the shader's contribution is 0 regardless).
	const CULL_PAD := 2.0

	for i in visible.size():
		# Directionals aren't tiled; the shader sweeps them for every fragment.
		if visible[i] is LitDirectionalLight2D:
			continue

		# range lives on each positional light type; fetch it dynamically.
		var light := visible[i] as Node2D
		var center: Vector2 = canvas_xform * light.global_position
		var light_range: float = float(light.get("range")) * scale + CULL_PAD
		var range_sq := light_range * light_range

		# A spot only reaches the wedge around its aim (the same aim/cos_outer the
		# shader tests); for a half-angle safely under 90 degrees the wedge is the
		# intersection of two half-planes through the light. A tile fully outside
		# either half-plane can't intersect the cone. The angle is padded so the CPU
		# never culls a fragment the GPU would light.
		var spot := visible[i] as LitSpotLight2D
		var cone_valid := false
		var n_plus := Vector2.ZERO
		var n_minus := Vector2.ZERO
		if spot != null:
			var half_angle := deg_to_rad(spot.spot_angle) + 0.002
			if half_angle < PI * 0.5 - 0.001:
				var aim_px := canvas_xform.basis_xform(Vector2.from_angle(spot.global_rotation))
				if aim_px.length_squared() > 0.0:
					var phi := aim_px.angle()
					n_plus = Vector2.from_angle(phi + half_angle - PI * 0.5)
					n_minus = Vector2.from_angle(phi - half_angle + PI * 0.5)
					cone_valid = true

		# Vertical tile span of the light's screen AABB, clamped to the grid. Within a
		# row, the circle's horizontal reach at that row (half = sqrt(r^2 - dy^2), with
		# dy the row band's closest approach to the center) gives the exact tile span
		# the range circle touches, so no per-tile distance test is needed.
		var ty0 := clampi(int(floor((center.y - light_range) / float(TILE_SIZE))), 0, tiles_y - 1)
		var ty1 := clampi(int(floor((center.y + light_range) / float(TILE_SIZE))), 0, tiles_y - 1)

		for ty in range(ty0, ty1 + 1):
			var y0 := float(ty * TILE_SIZE)
			var y1 := y0 + float(TILE_SIZE)
			var dy := center.y - clampf(center.y, y0, y1)
			var rem := range_sq - dy * dy
			if rem < 0.0:
				continue
			var half := sqrt(rem)
			var tx0 := clampi(int(floor((center.x - half) / float(TILE_SIZE))), 0, tiles_x - 1)
			var tx1 := clampi(int(floor((center.x + half) / float(TILE_SIZE))), 0, tiles_x - 1)
			var row_base := ty * tiles_x
			for tx in range(tx0, tx1 + 1):
				# Cone vs tile rect: fully outside either wedge half-plane means no
				# overlap. dot() is linear over the rect, so its maximum sits at the
				# corner picked by the normal's signs; a tile containing the light
				# itself always passes (the corners straddle any line through it).
				if cone_valid:
					var x0 := float(tx * TILE_SIZE)
					var x1 := x0 + float(TILE_SIZE)
					var px := (x1 if n_plus.x > 0.0 else x0) - center.x
					var py := (y1 if n_plus.y > 0.0 else y0) - center.y
					if px * n_plus.x + py * n_plus.y < 0.0:
						continue
					var mx := (x1 if n_minus.x > 0.0 else x0) - center.x
					var my := (y1 if n_minus.y > 0.0 else y0) - center.y
					if mx * n_minus.x + my * n_minus.y < 0.0:
						continue

				_pair_tiles.push_back(row_base + tx)
				_pair_rows.push_back(i)
				_tile_counts[row_base + tx] += 1

	# Header is one texel per tile (offset | count); the index list is INDEX_TEX_WIDTH
	# wide and as many rows as it takes to hold every accepted pair.
	var total_indices := _pair_tiles.size()
	var idx_rows := int(ceil(float(maxi(total_indices, 1)) / float(INDEX_TEX_WIDTH)))

	var header_floats := tile_count * 4
	if _header_buf.size() != header_floats:
		_header_buf.resize(header_floats)
	_header_buf.fill(0.0)
	var index_floats := INDEX_TEX_WIDTH * idx_rows * 4
	if _index_buf.size() != index_floats:
		_index_buf.resize(index_floats)
	# Stale entries past total_indices are never read (each tile's count bounds the
	# shader's loop), so the index buffer doesn't need clearing.

	# Prefix-sum the counts into per-tile start offsets, writing the header as we go;
	# _tile_counts then serves as each tile's write cursor for the scatter pass.
	var offset := 0
	for t in tile_count:
		var cnt := _tile_counts[t]
		_header_buf[t * 4] = float(offset)
		_header_buf[t * 4 + 1] = float(cnt)
		_tile_counts[t] = offset
		offset += cnt

	# Scatter each pair's light row into its tile's slice of the flat index list.
	for p in total_indices:
		var slot := _tile_counts[_pair_tiles[p]]
		_tile_counts[_pair_tiles[p]] = slot + 1
		_index_buf[slot * 4] = float(_pair_rows[p])

	_upload_tile_textures(tiles_x, tiles_y, idx_rows)

	RenderingServer.global_shader_parameter_set("lit_tile_size", TILE_SIZE)
	RenderingServer.global_shader_parameter_set("lit_tile_grid", Vector2i(tiles_x, tiles_y))
	RenderingServer.global_shader_parameter_set("lit_tile_headers", _tile_header_tex)
	RenderingServer.global_shader_parameter_set("lit_tile_indices", _tile_index_tex)

## Upload the header/index float buffers, reusing the Images and ImageTextures across
## frames and reallocating only when a dimension changes (same pattern as the light
## data upload).
func _upload_tile_textures(tiles_x: int, tiles_y: int, idx_rows: int) -> void:
	var header_bytes := _header_buf.to_byte_array()
	if _header_img == null or _header_img.get_width() != tiles_x or _header_img.get_height() != tiles_y:
		_header_img = Image.create_from_data(tiles_x, tiles_y, false, Image.FORMAT_RGBAF, header_bytes)
	else:
		_header_img.set_data(tiles_x, tiles_y, false, Image.FORMAT_RGBAF, header_bytes)
	if _tile_header_tex == null or _tile_header_tex.get_size() != Vector2(_header_img.get_size()):
		_tile_header_tex = ImageTexture.create_from_image(_header_img)
	else:
		_tile_header_tex.update(_header_img)

	var index_bytes := _index_buf.to_byte_array()
	if _index_img == null or _index_img.get_height() != idx_rows:
		_index_img = Image.create_from_data(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF, index_bytes)
	else:
		_index_img.set_data(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF, index_bytes)
	if _tile_index_tex == null or _tile_index_tex.get_size() != Vector2(_index_img.get_size()):
		_tile_index_tex = ImageTexture.create_from_image(_index_img)
	else:
		_tile_index_tex.update(_index_img)

## Publish a valid but empty tile grid (all counts zero) for the zero-light case, so the
## shader's tiling path stays valid and simply shades nothing.
func _publish_empty_tiles(vp_size: Vector2) -> void:
	var tiles_x := max(int(ceil(vp_size.x / float(TILE_SIZE))), 1)
	var tiles_y := max(int(ceil(vp_size.y / float(TILE_SIZE))), 1)
	var header_img := Image.create(tiles_x, tiles_y, false, Image.FORMAT_RGBAF)
	header_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var index_img := Image.create(INDEX_TEX_WIDTH, 1, false, Image.FORMAT_RGBAF)

	_tile_header_tex = _make_or_update(_tile_header_tex, header_img)
	_tile_index_tex = _make_or_update(_tile_index_tex, index_img)

	RenderingServer.global_shader_parameter_set("lit_tile_size", TILE_SIZE)
	RenderingServer.global_shader_parameter_set("lit_tile_grid", Vector2i(tiles_x, tiles_y))
	RenderingServer.global_shader_parameter_set("lit_tile_headers", _tile_header_tex)
	RenderingServer.global_shader_parameter_set("lit_tile_indices", _tile_index_tex)

## Reuse an ImageTexture when the image size is unchanged; reallocate on resize.
## ImageTexture.get_size() is Vector2 while Image.get_size() is Vector2i, so compare
## in a single type.
func _make_or_update(tex: ImageTexture, img: Image) -> ImageTexture:
	if tex == null or tex.get_size() != Vector2(img.get_size()):
		return ImageTexture.create_from_image(img)
	tex.update(img)
	return tex

## True if a light's `range`-expanded AABB intersects the visible world rect.
func _aabb_visible(pos: Vector2, light_range: float, world_rect: Rect2) -> bool:
	var aabb := Rect2(pos - Vector2(light_range, light_range), Vector2(light_range * 2.0, light_range * 2.0))
	return world_rect.intersects(aabb)

## Visible screen rect transformed into world space.
func _visible_world_rect(canvas_xform: Transform2D, vp_size: Vector2) -> Rect2:
	var inv := canvas_xform.affine_inverse()
	var rect := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	rect = rect.expand(inv * Vector2(vp_size.x, 0.0))
	rect = rect.expand(inv * Vector2(0.0, vp_size.y))
	rect = rect.expand(inv * vp_size)
	return rect

## Upload _pack_buf (TEXELS_PER_LIGHT x count RGBAF) to the light-data texture, reusing
## the Image and ImageTexture across frames and only reallocating when count changes.
func _upload_pack_buffer(count: int) -> void:
	var bytes := _pack_buf.to_byte_array()
	if _pack_img == null or _pack_img_count != count:
		_pack_img = Image.create_from_data(TEXELS_PER_LIGHT, count, false, Image.FORMAT_RGBAF, bytes)
		_pack_img_count = count
	else:
		_pack_img.set_data(TEXELS_PER_LIGHT, count, false, Image.FORMAT_RGBAF, bytes)

	if _texture == null or _texture.get_size() != Vector2(TEXELS_PER_LIGHT, count):
		_texture = ImageTexture.create_from_image(_pack_img)
	else:
		_texture.update(_pack_img)

## Return the cached [node, kind] light list, rebinding tree-change signals and
## rebuilding the cache only when the tree changed or a node entered/left it.
func _get_cached_lights(tree: SceneTree) -> Array:
	if tree != _cache_tree:
		_bind_cache_tree(tree)
		_cache_dirty = true
	if _cache_dirty:
		_rebuild_light_cache(tree)
	return _light_cache

## Move the node_added/node_removed subscriptions to `tree`, so any node entering or
## leaving (lights included) marks the cache dirty for the next refresh.
func _bind_cache_tree(tree: SceneTree) -> void:
	if _cache_tree != null and is_instance_valid(_cache_tree):
		if _cache_tree.node_added.is_connected(_on_tree_changed):
			_cache_tree.node_added.disconnect(_on_tree_changed)
		if _cache_tree.node_removed.is_connected(_on_tree_changed):
			_cache_tree.node_removed.disconnect(_on_tree_changed)
	_cache_tree = tree
	if tree != null:
		if not tree.node_added.is_connected(_on_tree_changed):
			tree.node_added.connect(_on_tree_changed)
		if not tree.node_removed.is_connected(_on_tree_changed):
			tree.node_removed.connect(_on_tree_changed)

func _on_tree_changed(_node: Node) -> void:
	_cache_dirty = true

## Rescan the lit_lights group and store [node, kind] (kind: 0 point, 1 directional,
## 2 spot) so refresh() avoids the group scan and per-node type dispatch each frame.
func _rebuild_light_cache(tree: SceneTree) -> void:
	_light_cache.clear()
	for node in tree.get_nodes_in_group("lit_lights"):
		var kind := -1
		if node is LitDirectionalLight2D:
			kind = 1
		elif node is LitPointLight2D:
			kind = 0
		elif node is LitSpotLight2D:
			kind = 2
		if kind >= 0:
			_light_cache.append([node, kind])
	_cache_dirty = false

## 1x1 RGBAF texture published as the light data when there are no lights, so the
## sampler global is always valid.
func _get_dummy() -> ImageTexture:
	if _dummy == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
		img.set_pixel(0, 0, Color(0, 0, 0, 0))
		_dummy = ImageTexture.create_from_image(img)
	return _dummy
