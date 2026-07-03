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
## t2 = color.rgb | height, t3 = shadow_color.rgb | shadow_hardness, t4 = spot cone.
## type/flags/mask sit in texel 0 so the shader can mask-reject after a single fetch.

const TEXELS_PER_LIGHT := 5

# Screen tile edge in pixels for the light-culling grid. Must match the shader's tile
# math (it divides SCREEN_UV * viewport by lit_tile_size).
const TILE_SIZE := 64

# When true, bin a light into a tile only if the light's CIRCULAR range actually
# intersects that tile's rectangle, instead of its bounding square. This removes the
# corner tiles a light's AABB overlaps but its circle can't reach (~22% of binned
# pairs on average), so fragments in dense regions loop over fewer lights. It is exact:
# a tile is dropped only when the light provably cannot illuminate any point in it, so
# there is no visual change -- only fewer per-fragment iterations. Both binning passes
# call the same _circle_hits_tile test, so counts and scatter cannot diverge.
const TILE_CULL_CIRCULAR := true

# Width of the flat tile-index texture; a flat index maps to (i % WIDTH, i / WIDTH).
# Must match LIT_INDEX_TEX_WIDTH in lit_receiver.gdshader.
const INDEX_TEX_WIDTH := 2048

## Diagnostic instrumentation. Set `LitLightRegistry.debug_stats = true` from any
## script (e.g. a stress test's _ready) to print a once-per-second line with: visible
## light count, texture capacities, RID reallocations, total tile indices, and time
## spent in refresh(). Interpreting it:
##   reallocs > 0 while running steady  -> texture RIDs are churning (the flicker
##                                          mechanism this file is supposed to prevent);
##                                          if this stays 0 while lights still pop, the
##                                          binning/upload path is exonerated.
##   refresh_ms << frame_ms             -> the CPU pack was never the bottleneck; the
##                                          frame cost is GPU fragment shading.
static var debug_stats := false
var _stat_reallocs := 0
var _stat_refresh_usec := 0
var _stat_frames := 0
var _stat_last_report := 0.0

var _texture: ImageTexture
var _dummy: ImageTexture

var _tile_header_tex: ImageTexture
var _tile_index_tex: ImageTexture

# Reused scratch for packing: write floats straight into _pack_buf and upload once,
# instead of per-texel Image.set_pixel calls.
#
# CAPACITY, NOT COUNT: every GPU-side buffer below is allocated to a grow-only capacity
# and updated in place. Reallocating an ImageTexture produces a NEW texture RID, and
# rebinding a global sampler to a new RID is not atomic with the scalar globals
# published next to it -- under a changing light count (spawning, culling) that meant a
# new RID every frame, and frames intermittently rendered with a tile header pointing
# into a texture that no longer matched. Out-of-range texelFetch returns zeros on
# D3D12, so the mismatched lights went black for a frame: the classic "lights flicker
# and drop out past a dozen" failure. With capacity-based allocation the RID is stable
# after the first growth, updates go through ImageTexture.update() on the same RID, and
# the sampler globals are re-published only on (re)allocation.
var _pack_buf: PackedFloat32Array = PackedFloat32Array()
var _pack_img: Image
var _light_capacity: int = 0            # allocated rows in the light-data texture

# Tile binning scratch, persistent across frames (counting sort: count, prefix-sum,
# scatter). No per-frame allocations.
var _tile_counts: PackedInt32Array = PackedInt32Array()
var _tile_offsets: PackedInt32Array = PackedInt32Array()
var _tile_cursor: PackedInt32Array = PackedInt32Array()
var _light_tile_span: PackedInt32Array = PackedInt32Array()  # tx0,tx1,ty0,ty1 per light
var _light_geom: PackedFloat32Array = PackedFloat32Array()   # cx,cy,range per light (screen px)
var _header_buf: PackedFloat32Array = PackedFloat32Array()   # RGF: offset | count
var _header_img: Image
var _header_grid: Vector2i = Vector2i.ZERO
var _index_buf: PackedFloat32Array = PackedFloat32Array()    # RF: light row
var _index_img: Image
var _index_capacity_rows: int = 0       # allocated rows in the tile-index texture

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
	var _t0 := Time.get_ticks_usec() if debug_stats else 0
	_refresh_inner(tree, viewport)
	if debug_stats:
		_stat_refresh_usec += Time.get_ticks_usec() - _t0
		_stat_frames += 1
		var now := Time.get_ticks_msec() / 1000.0
		if now - _stat_last_report >= 1.0:
			var avg_ms := (_stat_refresh_usec / maxf(float(_stat_frames), 1.0)) / 1000.0
			print("[lit] lights=%d cap=%d idx_rows=%d reallocs/s=%d refresh_avg=%.3f ms" % [
				_stat_last_count, _light_capacity, _index_capacity_rows, _stat_reallocs, avg_ms])
			_stat_reallocs = 0
			_stat_refresh_usec = 0
			_stat_frames = 0
			_stat_last_report = now

var _stat_last_count := 0

func _refresh_inner(tree: SceneTree, viewport: Viewport) -> void:
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
	_stat_last_count = count

	# Zero-light case: publish count 0 and empty tiles. Keep whatever data texture is
	# already bound (nothing reads it at count 0) so crossing through zero lights never
	# swaps the sampler RID; the dummy is only for the very first frame.
	if count == 0:
		RenderingServer.global_shader_parameter_set("lit_light_count", 0)
		RenderingServer.global_shader_parameter_set("lit_directional_count", 0)
		RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
		if _texture == null:
			RenderingServer.global_shader_parameter_set("lit_light_data", _get_dummy())
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

	# Pack each light into one TEXELS_PER_LIGHT-wide row of the float buffer. The buffer
	# is sized to the grow-only capacity so the byte length always matches the allocated
	# texture; rows beyond `count` are zeroed and never read (the shader bounds every
	# loop by lit_light_count / the tile headers).
	_ensure_light_capacity(count)
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

	# Publish scalar globals every frame (cheap); sampler globals are published inside
	# the upload helpers, and only when their texture object was (re)allocated, so the
	# bound RIDs stay stable frame to frame.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_directional_count", dir_count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)

## Pack one point light into the row starting at `row` in _pack_buf.
func _pack_point(row: int, light: LitPointLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	# Position to normalized screen UV, the one canonical space.
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Integer fields stored as plain floats, decoded with int(round(...)) in the shader.
	var subtractive := 1.0 if light.blend_mode == LitPointLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_POINT := 0.0

	# Four floats per texel; o is the float offset of this light's first texel.
	var o := row * TEXELS_PER_LIGHT * 4

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

	var subtractive := 1.0 if light.blend_mode == LitSpotLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_SPOT := 2.0

	var o := row * TEXELS_PER_LIGHT * 4

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

## Bin each positional light into the tiles its screen-space bounding box touches, then
## upload a per-tile header (offset + count) and a flat index list of light rows. The
## shader reads its own tile's header and shades only those rows. Directionals are skipped
## (they're full-screen and shaded directly).
func _build_tiles(visible: Array, canvas_xform: Transform2D, vp_size: Vector2, scale: float) -> void:
	var tiles_x := int(ceil(vp_size.x / float(TILE_SIZE)))
	var tiles_y := int(ceil(vp_size.y / float(TILE_SIZE)))
	tiles_x = max(tiles_x, 1)
	tiles_y = max(tiles_y, 1)
	var tile_count := tiles_x * tiles_y
	var light_count := visible.size()

	# Counting sort into PERSISTENT flat buffers -- the previous implementation built a
	# fresh PackedInt32Array bucket per tile per frame and wrote the GPU images with
	# per-texel set_pixel calls. At stress-test light counts that was hundreds of
	# allocations and tens of thousands of interpreted set_pixel calls every frame:
	# the actual CPU bottleneck of a many-light scene. This version allocates nothing in
	# the steady state: count entries per tile, prefix-sum into offsets, then scatter
	# light rows straight into the float upload buffer.
	if _tile_counts.size() != tile_count:
		_tile_counts.resize(tile_count)
		_tile_offsets.resize(tile_count)
		_tile_cursor.resize(tile_count)
	_tile_counts.fill(0)
	if _light_tile_span.size() < light_count * 4:
		_light_tile_span.resize(light_count * 4)
	if _light_geom.size() < light_count * 3:
		_light_geom.resize(light_count * 3)

	# `scale` is the world-to-screen pixel factor (the larger canvas-basis axis, so a
	# zoomed or non-uniformly scaled view over-includes rather than clips a light's
	# footprint). It matches the shader's lit_canvas_scale, computed once in refresh().

	# Pass 1: compute each positional light's tile span once (cached for pass 2) and
	# count how many lights land in every tile.
	var total_indices := 0
	for i in light_count:
		var so := i * 4
		# Directionals aren't tiled; the shader sweeps them for every fragment.
		if visible[i] is LitDirectionalLight2D:
			_light_tile_span[so] = -1        # sentinel: skip in pass 2
			continue

		var light := visible[i] as Node2D
		var center: Vector2 = canvas_xform * light.global_position
		var light_range: float = float(light.get("range")) * scale

		# Tile span of the light's screen AABB, clamped to the grid.
		var tx0 := clampi(int(floor((center.x - light_range) / float(TILE_SIZE))), 0, tiles_x - 1)
		var tx1 := clampi(int(floor((center.x + light_range) / float(TILE_SIZE))), 0, tiles_x - 1)
		var ty0 := clampi(int(floor((center.y - light_range) / float(TILE_SIZE))), 0, tiles_y - 1)
		var ty1 := clampi(int(floor((center.y + light_range) / float(TILE_SIZE))), 0, tiles_y - 1)
		_light_tile_span[so] = tx0
		_light_tile_span[so + 1] = tx1
		_light_tile_span[so + 2] = ty0
		_light_tile_span[so + 3] = ty1
		var go := i * 3
		_light_geom[go] = center.x
		_light_geom[go + 1] = center.y
		_light_geom[go + 2] = light_range
		var r2 := light_range * light_range

		for ty in range(ty0, ty1 + 1):
			var row_base := ty * tiles_x
			var tile_miny := float(ty * TILE_SIZE)
			var tile_maxy := tile_miny + float(TILE_SIZE)
			var ny := clampf(center.y, tile_miny, tile_maxy)
			var dy := center.y - ny
			var dy2 := dy * dy
			for tx in range(tx0, tx1 + 1):
				# Inlined circle-vs-tile test (no function call: GDScript call overhead in
				# this hot loop was the cost). Drop corner tiles the circle can't reach.
				if TILE_CULL_CIRCULAR:
					var tile_minx := float(tx * TILE_SIZE)
					var nx := clampf(center.x, tile_minx, tile_minx + float(TILE_SIZE))
					var dx := center.x - nx
					if dx * dx + dy2 > r2:
						continue
				_tile_counts[row_base + tx] += 1
				total_indices += 1

	# Prefix sum: contiguous bucket layout. Cursor starts at each tile's offset and
	# advances as pass 2 scatters.
	var offset := 0
	for t in tile_count:
		_tile_offsets[t] = offset
		_tile_cursor[t] = offset
		offset += _tile_counts[t]

	# Header buffer (RGF: offset | count), rewritten fully every frame.
	_ensure_header_capacity(tiles_x, tiles_y)
	for t in tile_count:
		var ho := t * 2
		_header_buf[ho] = float(_tile_offsets[t])
		_header_buf[ho + 1] = float(_tile_counts[t])

	# Index buffer (RF: light row), grow-only capacity in INDEX_TEX_WIDTH-wide rows.
	_ensure_index_capacity(total_indices)

	# Pass 2: scatter light rows into their tiles' slots.
	for i in light_count:
		var so := i * 4
		var tx0: int = _light_tile_span[so]
		if tx0 < 0:
			continue                          # directional
		var tx1: int = _light_tile_span[so + 1]
		var ty0: int = _light_tile_span[so + 2]
		var ty1: int = _light_tile_span[so + 3]
		var go := i * 3
		var cx := _light_geom[go]
		var cy := _light_geom[go + 1]
		var cr := _light_geom[go + 2]
		var cr2 := cr * cr
		var row_f := float(i)
		for ty in range(ty0, ty1 + 1):
			var row_base := ty * tiles_x
			var tile_miny := float(ty * TILE_SIZE)
			var ny := clampf(cy, tile_miny, tile_miny + float(TILE_SIZE))
			var dy := cy - ny
			var dy2 := dy * dy
			for tx in range(tx0, tx1 + 1):
				if TILE_CULL_CIRCULAR:
					var tile_minx := float(tx * TILE_SIZE)
					var nx := clampf(cx, tile_minx, tile_minx + float(TILE_SIZE))
					var dx := cx - nx
					if dx * dx + dy2 > cr2:
						continue                  # identical test to pass 1
				var t := row_base + tx
				_index_buf[_tile_cursor[t]] = row_f
				_tile_cursor[t] += 1

	_upload_tiles(tiles_x, tiles_y)

	RenderingServer.global_shader_parameter_set("lit_tile_size", TILE_SIZE)
	RenderingServer.global_shader_parameter_set("lit_tile_grid", Vector2i(tiles_x, tiles_y))

## Publish a valid but empty tile grid (all counts zero) for the zero-light case, so the
## shader's tiling path stays valid and simply shades nothing.
func _publish_empty_tiles(vp_size: Vector2) -> void:
	var tiles_x := max(int(ceil(vp_size.x / float(TILE_SIZE))), 1)
	var tiles_y := max(int(ceil(vp_size.y / float(TILE_SIZE))), 1)
	_ensure_header_capacity(tiles_x, tiles_y)
	_header_buf.fill(0.0)
	_ensure_index_capacity(1)
	_upload_tiles(tiles_x, tiles_y)

	RenderingServer.global_shader_parameter_set("lit_tile_size", TILE_SIZE)
	RenderingServer.global_shader_parameter_set("lit_tile_grid", Vector2i(tiles_x, tiles_y))

## Grow-only light-data capacity, in blocks of 32 rows. Growing reallocates the buffer,
## image, and texture ONCE at the new size; steady-state frames update in place with a
## stable RID.
func _ensure_light_capacity(count: int) -> void:
	if count <= _light_capacity and _texture != null:
		return
	_light_capacity = maxi(((count + 31) / 32) * 32, 32)
	_pack_buf.resize(_light_capacity * TEXELS_PER_LIGHT * 4)
	_pack_buf.fill(0.0)
	_pack_img = Image.create_from_data(TEXELS_PER_LIGHT, _light_capacity, false,
		Image.FORMAT_RGBAF, _pack_buf.to_byte_array())
	_texture = ImageTexture.create_from_image(_pack_img)
	_stat_reallocs += 1
	# New RID: this is the only moment the sampler global needs re-publishing.
	RenderingServer.global_shader_parameter_set("lit_light_data", _texture)

## Header buffer/texture sized to the tile grid (changes only with viewport size).
## RGF layout (offset | count); the shader reads header.x / header.y, and a texelFetch
## of an RG texture yields (r, g, 0, 1), so no shader change is needed.
func _ensure_header_capacity(tiles_x: int, tiles_y: int) -> void:
	var grid := Vector2i(tiles_x, tiles_y)
	if grid == _header_grid and _tile_header_tex != null:
		return
	_header_grid = grid
	_header_buf.resize(tiles_x * tiles_y * 2)
	_header_buf.fill(0.0)
	_header_img = Image.create_from_data(tiles_x, tiles_y, false,
		Image.FORMAT_RGF, _header_buf.to_byte_array())
	_tile_header_tex = ImageTexture.create_from_image(_header_img)
	_stat_reallocs += 1
	RenderingServer.global_shader_parameter_set("lit_tile_headers", _tile_header_tex)

## Grow-only tile-index capacity in INDEX_TEX_WIDTH-wide rows. RF layout (light row in
## .x, matching the shader's texelFetch(...).x). Entries past the live range are stale
## but unreachable: every read is bounded by a header's offset + count.
func _ensure_index_capacity(total_indices: int) -> void:
	var rows := int(ceil(float(maxi(total_indices, 1)) / float(INDEX_TEX_WIDTH)))
	if rows <= _index_capacity_rows and _tile_index_tex != null:
		return
	_index_capacity_rows = maxi(rows * 2, 4)   # grow with headroom to avoid re-growth churn
	_index_buf.resize(_index_capacity_rows * INDEX_TEX_WIDTH)
	_index_buf.fill(0.0)
	_index_img = Image.create_from_data(INDEX_TEX_WIDTH, _index_capacity_rows, false,
		Image.FORMAT_RF, _index_buf.to_byte_array())
	_tile_index_tex = ImageTexture.create_from_image(_index_img)
	_stat_reallocs += 1
	RenderingServer.global_shader_parameter_set("lit_tile_indices", _tile_index_tex)

## Push the persistent header/index buffers to their textures in place (same RIDs).
func _upload_tiles(tiles_x: int, tiles_y: int) -> void:
	_header_img.set_data(tiles_x, tiles_y, false, Image.FORMAT_RGF, _header_buf.to_byte_array())
	_tile_header_tex.update(_header_img)
	_index_img.set_data(INDEX_TEX_WIDTH, _index_capacity_rows, false, Image.FORMAT_RF, _index_buf.to_byte_array())
	_tile_index_tex.update(_index_img)

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

## Upload _pack_buf (TEXELS_PER_LIGHT x capacity RGBAF) to the light-data texture in
## place. Capacity growth (the only reallocation) happens in _ensure_light_capacity,
## which also re-publishes the sampler global; here the RID never changes.
func _upload_pack_buffer(_count: int) -> void:
	_pack_img.set_data(TEXELS_PER_LIGHT, _light_capacity, false, Image.FORMAT_RGBAF, _pack_buf.to_byte_array())
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
