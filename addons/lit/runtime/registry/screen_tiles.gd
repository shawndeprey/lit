extends RefCounted

## Screen-tile light culling grid: bins each positional light into the tiles its
## footprint touches and publishes the header/index textures the shader culls with.

# Screen tile edge in pixels for the light-culling grid. Must match the shader's tile
# math (it divides SCREEN_UV * viewport by lit_tile_size).
const TILE_SIZE := 64

const FrameContext := preload("res://addons/lit/runtime/registry/frame_context.gd")

# Width of the flat tile-index texture; a flat index maps to (i % WIDTH, i / WIDTH).
# Must match LIT_INDEX_TEX_WIDTH in lit_receiver_common.gdshaderinc.
const INDEX_TEX_WIDTH := 2048

var _tile_header_tex: ImageTexture
var _tile_index_tex: ImageTexture

# Reused tile-build scratch, kept across frames so steady state allocates nothing.
var _tile_counts: PackedInt32Array = PackedInt32Array()
var _pair_tiles: PackedInt32Array = PackedInt32Array()
var _pair_rows: PackedInt32Array = PackedInt32Array()
var _header_buf: PackedFloat32Array = PackedFloat32Array()
var _index_buf: PackedFloat32Array = PackedFloat32Array()
var _header_img: Image
var _index_img: Image


## Bin each positional light into the tiles its screen footprint touches, then upload a
## per-tile header (offset | count) and a flat index list of light rows. The shader reads
## its own tile's header and shades only those rows. Directionals are skipped (they're
## full-screen and shaded directly). Culling is conservative: only (tile, light) pairs
## the shader would shade to exactly zero are dropped, so it never changes the image.
func build_and_publish(ctx: FrameContext) -> void:
	var visible: Array = ctx.visible
	var canvas_xform: Transform2D = ctx.canvas_xform
	var vp_size: Vector2 = ctx.vp_size
	var scale: float = ctx.canvas_scale
	var tiles_x := int(ceil(vp_size.x / float(TILE_SIZE)))
	var tiles_y := int(ceil(vp_size.y / float(TILE_SIZE)))
	tiles_x = max(tiles_x, 1)
	tiles_y = max(tiles_y, 1)
	var tile_count := tiles_x * tiles_y

	# Gather accepted (tile, light-row) pairs flat, then counting-sort them into the
	# contiguous per-tile layout.
	if _tile_counts.size() != tile_count:
		_tile_counts.resize(tile_count)
	_tile_counts.fill(0)
	_pair_tiles.clear()
	_pair_rows.clear()

	# `scale` is the world-to-screen pixel factor (the larger canvas-basis axis, so a
	# zoomed or non-uniformly scaled view over-includes rather than clips a light's
	# footprint). It matches the shader's lit_canvas_scale, computed once in refresh().

	# Slack in screen px for CPU/GPU float disagreement at a footprint's exact boundary.
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

		# A spot's cone (half-angle under 90 degrees) is the intersection of two
		# half-planes through the light; a tile fully outside either can't intersect it.
		# The angle is padded so the CPU never culls a fragment the GPU would light.
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

		# Per tile row, the circle's horizontal reach (sqrt(r^2 - dy^2), dy = the row
		# band's closest approach) gives the exact tile span; no per-tile distance test.
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
				# Cone vs tile rect: dot() is linear over the rect, so its maximum sits
				# at the corner picked by the normal's signs; a tile containing the
				# light always passes.
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

	# Header: one texel per tile (offset | count); index list: as many rows as needed.
	var total_indices := _pair_tiles.size()
	var idx_rows := int(ceil(float(maxi(total_indices, 1)) / float(INDEX_TEX_WIDTH)))

	var header_floats := tile_count * 4
	if _header_buf.size() != header_floats:
		_header_buf.resize(header_floats)
	_header_buf.fill(0.0)
	var index_floats := INDEX_TEX_WIDTH * idx_rows * 4
	if _index_buf.size() != index_floats:
		_index_buf.resize(index_floats)
	# Entries past total_indices are never read (counts bound the shader's loop), so
	# the index buffer needs no clearing.

	# Prefix-sum counts into start offsets; _tile_counts becomes the scatter cursor.
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

## Upload the header/index buffers, reusing Images/ImageTextures until a size changes.
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
func publish_empty(vp_size: Vector2) -> void:
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
