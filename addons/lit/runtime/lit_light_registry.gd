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
## Two CPU-side optimizations live here:
##  - Cached light list (Item 6): the `lit_lights` group is rescanned only when the tree
##    gains or loses a node (node_added / node_removed flip a dirty flag), not every
##    frame. A moving-but-stable light set reuses the cached typed list.
##  - Single-upload packing (Item 5): every light's record is written into one reused
##    PackedFloat32Array and uploaded in one Image.set_data call, instead of 4-5
##    Image.set_pixel calls per light per frame.
##
## Packs a per-light record. The cheap cull keys live in texel 0 so a masked-out or
## wrong-type light bails after a single texelFetch (Phase 2, Item 2.1). Texel 0.r is
## the type:
##  0 point:       texel 1 is a screen-UV position.
##  1 directional: texel 1 is a screen-space direction toward the light.
##  2 spot:        texel 1 is a position (as a point); texel 4 adds the cone
##                 (aim direction plus the cosines of the inner and outer angles).
##
## Texel map (must stay in sync with the unpack in lit_receiver.gdshader):
##  Texel 0: type | flags | light_mask | falloff   (cull keys, fetched first)
##  Texel 1: uv.x/dir.x | uv.y/dir.y | range | energy
##  Texel 2: color.r | color.g | color.b | height
##  Texel 3: shadow_color.rgb | shadow_hardness
##  Texel 4: aim.x | aim.y | cos_outer | cos_inner  (spot only)

const TEXELS_PER_LIGHT := 5

# Tiled light culling (Phase 3, Item 3a). The screen is divided into TILE_SIZE-px
# tiles; each tile stores the list of lights whose screen-space AABB overlaps it, so a
# fragment only iterates the lights near it instead of every visible light. This changes
# the order of evaluation, not the math — lossless.
const TILE_SIZE := 64
# Flat index texture width. Light indices for all tiles are written row-major into a
# 2D RGBAF texture of this fixed width so we never approach the max-texture-width limit;
# the shader reconstructs (x, y) from a flat offset with the same width.
const INDEX_TEX_WIDTH := 2048

var _texture: ImageTexture
var _dummy: ImageTexture

# Reused tile textures (header = (offset,count) per tile; indices = flat light list).
var _tile_header_tex: ImageTexture
var _tile_index_tex: ImageTexture

# --- Fast packing buffer (Item 5) --------------------------------------------
# The pack used to call Image.set_pixel 4-5x per light per frame: ~600 engine
# round-trips at 128 lights. Instead we write the whole RGBAF image into one reused
# PackedFloat32Array (20 floats per light row: 5 texels x 4 channels) and hand its
# bytes straight to the texture. No per-texel Color allocations, no per-pixel calls.
# The buffer grows as needed and is reused frame-to-frame; the matching Image is also
# reused and only reallocated when the light count changes.
var _pack_buf: PackedFloat32Array = PackedFloat32Array()
var _pack_img: Image
var _pack_img_count: int = -1

# --- Cached light list (Item 6) ----------------------------------------------
# get_nodes_in_group() plus the per-node `as` cast ran every frame even when the set
# of lights hadn't changed. We cache the typed light list and only rescan the group
# when the scene tree gains or loses a node (node_added / node_removed), tracked by a
# dirty flag. Per-frame movement/property changes don't dirty the cache — those are
# read live during the pack — so a moving-but-stable light set never rescans.
# The cache is keyed to one tree; switching trees (editor viewport vs running game)
# forces a rescan.
var _light_cache: Array = []
var _cache_dirty: bool = true
var _cache_tree: SceneTree = null


## Gather visible lights, pack them into the light-data texture, and publish the
## global shader uniforms. Call once per frame.
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

	# Collect enabled, visible lights. Point and spot lights are AABB-culled against the
	# visible world rect; directional lights are never positionally culled. Disabled or
	# hidden lights (is_visible_in_tree respects hidden ancestors) are dropped here on
	# the CPU, so they're never packed or iterated.
	#
	# The typed light list is cached (Item 6): we rescan the `lit_lights` group only when
	# the tree gains or loses a node, not every frame. Movement and property changes are
	# read live below, so a moving-but-stable set never triggers a rescan.
	var lights := _get_cached_lights(tree)
	var visible: Array = []
	for entry in lights:
		var node: Node = entry[0]
		if not is_instance_valid(node):
			# A freed node slipped in before the dirty flag was serviced; force a
			# rescan next frame and skip it now.
			_cache_dirty = true
			continue
		var kind: int = entry[1]  # 0 point, 1 directional, 2 spot
		if kind == 1:
			var directional := node as LitDirectionalLight2D
			if directional.enabled and directional.is_visible_in_tree():
				visible.append(directional)  # never positionally culled
		elif kind == 0:
			var point := node as LitPointLight2D
			if point.enabled and point.is_visible_in_tree() and _aabb_visible(point.global_position, point.range, world_rect):
				visible.append(point)
		else:
			var spot := node as LitSpotLight2D
			if spot.enabled and spot.is_visible_in_tree() and _aabb_visible(spot.global_position, spot.range, world_rect):
				visible.append(spot)

	var count := visible.size()

	# Zero-light case: count 0 plus a 1x1 dummy, never a 4x0 image.
	if count == 0:
		RenderingServer.global_shader_parameter_set("lit_light_count", 0)
		RenderingServer.global_shader_parameter_set("lit_directional_count", 0)
		RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
		RenderingServer.global_shader_parameter_set("lit_light_data", _get_dummy())
		_publish_empty_tiles(vp_size)
		return

	# Pack directional lights first (rows [0, dir_count)) so the shader's always-on
	# directional loop runs just those rows and never scans the point/spot lights. Tile
	# indices reference these same packed rows, so point/spot rows simply follow.
	var directionals: Array = []
	var positional: Array = []
	for l in visible:
		if l is LitDirectionalLight2D:
			directionals.append(l)
		else:
			positional.append(l)
	visible = directionals + positional
	var dir_count := directionals.size()

	# Pack each light into one row (20 floats) of the reused RGBAF buffer, then upload
	# the whole buffer in one shot (Item 5). The buffer is zero-filled first so any
	# texel a packer doesn't touch (e.g. spot-only texel 4 on a point light) reads 0.
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

	# Build the tile grid and publish its textures + metadata (Item 3a). Done after the
	# pack so light row indices match the packed texture rows.
	_build_tiles(visible, canvas_xform, vp_size)

	# Publish globals.
	RenderingServer.global_shader_parameter_set("lit_light_count", count)
	RenderingServer.global_shader_parameter_set("lit_directional_count", dir_count)
	RenderingServer.global_shader_parameter_set("lit_viewport_size", vp_size)
	RenderingServer.global_shader_parameter_set("lit_light_data", _texture)


## Pack one point light into row `row` of the reused float buffer.
func _pack_point(row: int, light: LitPointLight2D, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	# Position to normalized screen UV, the one canonical space.
	var screen_px: Vector2 = canvas_xform * light.global_position
	var uv := screen_px / vp_size

	# Integer fields stored as plain floats, decoded with int(round(...)) in the shader.
	var subtractive := 1.0 if light.blend_mode == LitPointLight2D.BlendMode.SUBTRACT else 0.0
	var flags := float(light.shadow_enabled) + 2.0 * subtractive
	const TYPE_POINT := 0.0

	var o := row * TEXELS_PER_LIGHT * 4
	# Texel 0: type | flags | light_mask | falloff   (cull keys, fetched first)
	_pack_buf[o + 0] = TYPE_POINT
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = light.falloff
	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range
	_pack_buf[o + 7] = light.energy
	# Texel 2: color.r | color.g | color.b | height
	_pack_buf[o + 8] = light.color.r
	_pack_buf[o + 9] = light.color.g
	_pack_buf[o + 10] = light.color.b
	_pack_buf[o + 11] = light.height
	# Texel 3: shadow_color.rgb | shadow_hardness
	_pack_buf[o + 12] = light.shadow_color.r
	_pack_buf[o + 13] = light.shadow_color.g
	_pack_buf[o + 14] = light.shadow_color.b
	_pack_buf[o + 15] = light.shadow_hardness
	# Texel 4 unused for points; the per-frame fill(0.0) leaves it zeroed.


## Pack one directional light into row `row`. Texel 0 carries a normalized direction
## toward the light in screen-pixel space instead of a UV position; range and falloff
## are unused.
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
	# Texel 0: type | flags | light_mask | (falloff unused)   (cull keys, fetched first)
	_pack_buf[o + 0] = TYPE_DIRECTIONAL
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = 1.0
	# Texel 1: dir.x | dir.y | (range unused) | energy
	_pack_buf[o + 4] = dir_px.x
	_pack_buf[o + 5] = dir_px.y
	_pack_buf[o + 6] = 0.0
	_pack_buf[o + 7] = light.energy
	# Texel 2: color.r | color.g | color.b | height
	_pack_buf[o + 8] = light.color.r
	_pack_buf[o + 9] = light.color.g
	_pack_buf[o + 10] = light.color.b
	_pack_buf[o + 11] = light.height
	# Texel 3: shadow_color.rgb | shadow_hardness
	_pack_buf[o + 12] = light.shadow_color.r
	_pack_buf[o + 13] = light.shadow_color.g
	_pack_buf[o + 14] = light.shadow_color.b
	_pack_buf[o + 15] = light.shadow_hardness


## Pack one spot light into row `row`: a point light (texels 0 to 3) plus a cone
## (texel 4). The node's local +X (its rotation) is the direction the cone aims.
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
	# Texel 0: type | flags | light_mask | falloff   (cull keys, fetched first)
	_pack_buf[o + 0] = TYPE_SPOT
	_pack_buf[o + 1] = flags
	_pack_buf[o + 2] = float(light.light_mask)
	_pack_buf[o + 3] = light.falloff
	# Texel 1: uv.x | uv.y | range | energy
	_pack_buf[o + 4] = uv.x
	_pack_buf[o + 5] = uv.y
	_pack_buf[o + 6] = light.range
	_pack_buf[o + 7] = light.energy
	# Texel 2: color.r | color.g | color.b | height
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


# --- Tiled light culling (Phase 3, Item 3a) ----------------------------------
#
# Cost scales with screen coverage, not total light count. The build marks, for every
# TILE_SIZE-px screen tile, which packed lights overlap it. A conservative screen AABB
# (square, sized by the max canvas scale) is fine: a tile that includes a barely-
# contributing light is caught by the Phase 1 contribution early-out, and over-coverage
# never changes the result, only costs a few extra iterations. Directional lights have
# no position, so they bypass tiling and run in a small always-on loop in the shader;
# they're not written into any tile list here.

## Build per-tile light-index lists and publish the header + index textures and the grid
## metadata globals. `visible[i]` corresponds to packed light row `i`.
func _build_tiles(visible: Array, canvas_xform: Transform2D, vp_size: Vector2) -> void:
	var tiles_x := int(ceil(vp_size.x / float(TILE_SIZE)))
	var tiles_y := int(ceil(vp_size.y / float(TILE_SIZE)))
	tiles_x = max(tiles_x, 1)
	tiles_y = max(tiles_y, 1)
	var tile_count := tiles_x * tiles_y

	# Per-tile growable index lists.
	var buckets: Array = []
	buckets.resize(tile_count)
	for t in tile_count:
		buckets[t] = PackedInt32Array()

	# Screen-space scale of the world->screen transform (editor zoom / camera zoom);
	# world `range` becomes screen pixels via the larger axis scale, conservatively.
	var sx := canvas_xform.x.length()
	var sy := canvas_xform.y.length()
	var scale := maxf(sx, sy)

	for i in visible.size():
		# Directional lights bypass tiling (handled by the shader's always-on loop).
		if visible[i] is LitDirectionalLight2D:
			continue

		var light := visible[i] as Node2D
		var center: Vector2 = canvas_xform * light.global_position
		var light_range: float = float(light.get("range")) * scale

		# Screen AABB -> inclusive tile range, clamped to the grid.
		var tx0 := int(floor((center.x - light_range) / float(TILE_SIZE)))
		var tx1 := int(floor((center.x + light_range) / float(TILE_SIZE)))
		var ty0 := int(floor((center.y - light_range) / float(TILE_SIZE)))
		var ty1 := int(floor((center.y + light_range) / float(TILE_SIZE)))
		tx0 = clampi(tx0, 0, tiles_x - 1)
		tx1 = clampi(tx1, 0, tiles_x - 1)
		ty0 = clampi(ty0, 0, tiles_y - 1)
		ty1 = clampi(ty1, 0, tiles_y - 1)
		# Fully off-screen after clamping is impossible here (the gather already AABB-
		# culled against the visible rect), but the clamp keeps a straddling light in-grid.

		for ty in range(ty0, ty1 + 1):
			var row_base := ty * tiles_x
			for tx in range(tx0, tx1 + 1):
				buckets[row_base + tx].push_back(i)

	# Flatten buckets into a header texture ((offset,count) per tile) and a flat index
	# texture, both RGBAF read with texelFetch in the shader.
	var header_img := Image.create(tiles_x, tiles_y, false, Image.FORMAT_RGBAF)
	var total_indices := 0
	for t in tile_count:
		total_indices += buckets[t].size()

	# Index texture: row-major into a fixed-width 2D image, at least 1x1.
	var idx_rows := int(ceil(float(maxi(total_indices, 1)) / float(INDEX_TEX_WIDTH)))
	var index_img := Image.create(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF)

	var offset := 0
	for t in tile_count:
		var bucket: PackedInt32Array = buckets[t]
		var cnt := bucket.size()
		var hx := t % tiles_x
		var hy := t / tiles_x
		header_img.set_pixel(hx, hy, Color(float(offset), float(cnt), 0.0, 0.0))
		for j in cnt:
			var flat := offset + j
			index_img.set_pixel(flat % INDEX_TEX_WIDTH, flat / INDEX_TEX_WIDTH, Color(float(bucket[j]), 0.0, 0.0, 0.0))
		offset += cnt

	_tile_header_tex = _make_or_update(_tile_header_tex, header_img)
	_tile_index_tex = _make_or_update(_tile_index_tex, index_img)

	RenderingServer.global_shader_parameter_set("lit_tile_size", TILE_SIZE)
	RenderingServer.global_shader_parameter_set("lit_tile_grid", Vector2i(tiles_x, tiles_y))
	RenderingServer.global_shader_parameter_set("lit_tile_headers", _tile_header_tex)
	RenderingServer.global_shader_parameter_set("lit_tile_indices", _tile_index_tex)


## Publish a valid but empty tile grid for the zero-light case, so the shader's tile path
## reads a defined (count 0 everywhere) structure rather than stale data.
func _publish_empty_tiles(vp_size: Vector2) -> void:
	var tiles_x := max(int(ceil(vp_size.x / float(TILE_SIZE))), 1)
	var tiles_y := max(int(ceil(vp_size.y / float(TILE_SIZE))), 1)
	var header_img := Image.create(tiles_x, tiles_y, false, Image.FORMAT_RGBAF)
	header_img.fill(Color(0.0, 0.0, 0.0, 0.0))  # offset 0, count 0 in every tile
	var index_img := Image.create(INDEX_TEX_WIDTH, 1, false, Image.FORMAT_RGBAF)

	_tile_header_tex = _make_or_update(_tile_header_tex, header_img)
	_tile_index_tex = _make_or_update(_tile_index_tex, index_img)

	RenderingServer.global_shader_parameter_set("lit_tile_size", TILE_SIZE)
	RenderingServer.global_shader_parameter_set("lit_tile_grid", Vector2i(tiles_x, tiles_y))
	RenderingServer.global_shader_parameter_set("lit_tile_headers", _tile_header_tex)
	RenderingServer.global_shader_parameter_set("lit_tile_indices", _tile_index_tex)


## Create-or-update an ImageTexture, reallocating only when the size changes.
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


## Build (or refresh) the RGBAF light texture from the packed float buffer in one upload
## (Item 5). The Image is reused and only reallocated when the light count changes; the
## texture is likewise reused via update() unless its size changed. Image.set_data takes
## the raw little-endian float bytes, which match FORMAT_RGBAF channel-for-channel.
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


# --- Cached light list (Item 6) ----------------------------------------------
#
# Rescans the `lit_lights` group only when the tree's node set changes. The registry is
# RefCounted (no _ready / signal lifecycle of its own), so we connect to the tree's
# node_added / node_removed signals lazily on first use and just flip a dirty flag; the
# next refresh() rebuilds the typed list. Connecting per-tree means switching between the
# editor viewport tree and a running game's tree re-arms the hooks correctly.
#
# Each cache entry is [node, kind] where kind is 0 point, 1 directional, 2 spot — the
# type test is done once at scan time instead of three `as` casts every frame.

## Return the cached typed light list, rescanning the group first if the cache is dirty
## or bound to a different tree.
func _get_cached_lights(tree: SceneTree) -> Array:
	if tree != _cache_tree:
		_bind_cache_tree(tree)
		_cache_dirty = true
	if _cache_dirty:
		_rebuild_light_cache(tree)
	return _light_cache


## (Re)connect the node_added / node_removed hooks to `tree`, disconnecting from any
## previous tree first. Cheap signals that only set a flag; the work happens in refresh().
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


## Marks the cache stale on any node add/remove. We don't filter to lit_lights here:
## the signal only carries the node, group membership is added in the light's
## _enter_tree which may not have run yet, and the rescan is cheap and happens at most
## once per frame anyway.
func _on_tree_changed(_node: Node) -> void:
	_cache_dirty = true


## Rebuild the typed [node, kind] list from the group and clear the dirty flag.
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


func _get_dummy() -> ImageTexture:
	if _dummy == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
		img.set_pixel(0, 0, Color(0, 0, 0, 0))
		_dummy = ImageTexture.create_from_image(img)
	return _dummy
