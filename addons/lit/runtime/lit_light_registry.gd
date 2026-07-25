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
## when flags bit 2 is set), t7 = shadow source size | samples | jitter (read only when
## the algorithm bits are nonzero), t8.x = exempt rect count, t9 = exempt union bounds,
## t10-13 = the light's exempt-occluder canvas rects (t8-t13 read only when flags bit 5
## is set). type/flags/mask sit in texel 0 so the shader can mask-reject after a single
## fetch. flags: bit 0 shadow_enabled, bit 1 subtractive, bit 2 textured, bits 3-4
## shadow algorithm (ShadowAlgorithm order on the light nodes), bit 5 shadow exclusions.

const LitCookieAtlasScript := preload("res://addons/lit/runtime/lit_cookie_atlas.gd")

const TEXELS_PER_LIGHT := 14

# Which shadow algorithms the shaders must support this frame, from the last refresh()
# in this process (bit 0 = Cone Traced, bit 1 = Stochastic, among enabled shadow-casting
# lights). LitSprite2D reads it every frame to pick its receiver shader variant, and
# refresh() itself re-points every other Lit receiver material via
# _apply_receiver_variants, so the per-light algorithm dropdown works on all receivers
# (tool-converted nodes, tilemaps, hand-assigned materials) with no manual shader swap.
static var active_algos: int = 0

# Receiver variants by active-algorithm bitmask, fast (no self-exclusion) and full.
# Must stay aligned with the same tables in lit_sprite_2d.gd.
const RECEIVER_FAST_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast.gdshader",
]
const RECEIVER_FULL_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch.gdshader",
]
# Third axis: full + the y-sort shadow depth test, for participating receivers only.
const RECEIVER_YSORT_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_ysort.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_ysort.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_ysort.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_ysort.gdshader",
]
# Gx twins of the three tables, used while globally excluded occluders exist but no
# light carries per-light exclusions.
const RECEIVER_FAST_GX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast_gx.gdshader",
]
const RECEIVER_FULL_GX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_gx.gdshader",
]
const RECEIVER_YSORT_GX_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_ysort_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_ysort_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_ysort_gx.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_ysort_gx.gdshader",
]
# Mask twins of the three tables, used while any light carries per-light exclusions.
const RECEIVER_FAST_MASK_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_fast_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_fast_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_fast_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_fast_mask.gdshader",
]
const RECEIVER_FULL_MASK_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_mask.gdshader",
]
const RECEIVER_YSORT_MASK_VARIANTS: Array[String] = [
	"res://addons/lit/shaders/lit_receiver_ysort_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_ysort_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_stoch_ysort_mask.gdshader",
	"res://addons/lit/shaders/lit_receiver_cone_stoch_ysort_mask.gdshader",
]

static var _receiver_paths := {}

static func _is_lit_receiver_path(path: String) -> bool:
	if _receiver_paths.is_empty():
		for table in [RECEIVER_FAST_VARIANTS, RECEIVER_FULL_VARIANTS, RECEIVER_YSORT_VARIANTS,
				RECEIVER_FAST_GX_VARIANTS, RECEIVER_FULL_GX_VARIANTS, RECEIVER_YSORT_GX_VARIANTS,
				RECEIVER_FAST_MASK_VARIANTS, RECEIVER_FULL_MASK_VARIANTS, RECEIVER_YSORT_MASK_VARIANTS]:
			for p in table:
				_receiver_paths[p] = true
	return _receiver_paths.has(path)

# Algorithm mask last applied to receiver materials, and whether the tree changed since
# the last application. Starting at 0 (the base mask) means a scene that never uses the
# physical algorithms never pays for a receiver walk.
var _published_algos: int = 0
var _receiver_dirty: bool = true

# CPU-side clamp on each light's shadow_samples, from lit/quality/shadow_samples_max;
# set by the owner (LitManager at runtime, the plugin in the editor). The shader
# additionally clamps to its compile-time LIT_MAX_SHADOW_SAMPLES = 32.
var shadow_samples_max: int = 32

# Screen tile edge in pixels for the light-culling grid. Must match the shader's tile
# math (it divides SCREEN_UV * viewport by lit_tile_size).
const TILE_SIZE := 64

# Width of the flat tile-index texture; a flat index maps to (i % WIDTH, i / WIDTH).
# Must match LIT_INDEX_TEX_WIDTH in lit_receiver_common.gdshaderinc.
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

# Reused tile-build scratch, kept across frames so steady state allocates nothing.
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

# --- Occluder identity (y-sort depth + per-light shadow exclusions) ------------------
# Per-occluder canvas rect + depth line + mask|owner, binned into the light tile grid.
static var ysort_enabled: bool = false
# True while any enabled shadow-casting light carries per-light exclusions; drives the
# _mask receiver variants. Tree-wide, not view-culled, so camera motion never thrashes
# shaders. Occluders excluded from EVERY light never set this: they ride the far cheaper
# gx tier below.
static var masks_active: bool = false
# True while globally excluded occluder rects are published; drives the _gx variants.
static var gx_active: bool = false

var _occ_nodes: Array = []       # [LightOccluder2D, owner id]
var _occ_layers: Array = []      # [TileMapLayer, cell rects, xform, world rects, masks, distinct, ts snapshot]
var _occ_dirty := true
var _occ_pack_buf := PackedFloat32Array()
var _occ_rects: Array[Rect2] = []
var _occ_masks := PackedInt32Array()
var _occ_owners := PackedInt32Array()
var _occ_mask_set := {}          # distinct SDF-casting occluder masks, exact at cache rebuild
var _occ_masks_seen := false     # any non-default SDF-casting occluder mask observed (sticky)
var _mask_seed_done := false
var _scope_ids := {}             # scope root Node -> owner id
var _scope_occ_masks := {}       # owner id -> {mask: true} of SDF casters under that scope
var _gx_masks := {}              # occluder masks excluded from every shadow-casting light
var _gx_rects: Array[Rect2] = []
var _gx_packed := PackedVector4Array()
# Runtime only (lit/render/occluder_mask_sdf_culling): globally excluded occluders are
# pulled out of the SDF entirely instead of exempted in-shader - marches get faster, not
# slower. Never set in the editor, where mutating scene nodes would risk saves; the
# editor previews via the _gx shader tier instead.
var sdf_cull := false
var _sdf_culled := {}            # occluders whose sdf_collision this registry disabled
var _ts_culled := {}             # TileSet -> {occlusion layer idx} this registry disabled
var _excl_info := {}             # light -> owner id, for lights with exclusions this frame
var _excl_smasks := {}           # shadow_masks of those lights
var _excl_owners := {}           # owner ids of those lights
var _excl_combos := {}           # "smask_owner" -> [smask, owner id], distinct this frame
var _excl_lists := {}            # combo key -> [count, union Rect2, 4 packed rects]
var _prev_combo_sig := ""
var _prev_excl_masks := PackedInt32Array()
var _prev_excl_owners := PackedInt32Array()
var _occ_spans := PackedInt32Array()
var _occ_tile_counts := PackedInt32Array()
var _occ_tile_min := PackedFloat32Array()
var _occ_header_buf := PackedFloat32Array()
var _occ_index_buf := PackedFloat32Array()
var _occ_prev_pack := PackedFloat32Array()
var _occ_prev_xform := Transform2D()
var _occ_prev_grid := Vector2i.ZERO
var _occ_img: Image
var _occ_header_img: Image
var _occ_index_img: Image
var _occ_tex: ImageTexture
var _occ_header_tex: ImageTexture
var _occ_index_tex: ImageTexture

func set_ysort(enabled: bool) -> void:
	if ysort_enabled == enabled:
		return
	ysort_enabled = enabled
	_bare_dirty = true
	_occ_dirty = true
	_occ_prev_pack = PackedFloat32Array()

## Gather visible lights, pack them into the light-data texture, build the tile grid,
## and publish the global shader uniforms. Call once per frame. receiver_root bounds
## the receiver-material walk for the shadow-algorithm variant swap (the game tree root
## at runtime, the edited scene root in the editor); null skips that swap.
func refresh(tree: SceneTree, viewport: Viewport, receiver_root: Node = null) -> void:
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

	# Publish which non-raymarched shadow algorithms are in play and re-point receiver
	# materials to a variant compiled with exactly those (base scenes stay on the base
	# shader). Computed over every enabled light in the tree, not just the view-culled
	# set, so camera movement past a light's AABB never thrashes receiver shaders. Only
	# shadow-casting lights count: an algorithm on a shadowless light is never marched.
	var algos := 0
	var mask_potential := _occ_masks_seen
	var smask_union := 0
	for entry in lights:
		# Untyped: enabled/shadow_enabled/shadow_algorithm live on each light class,
		# not on a shared base.
		var node = entry[0]
		if not is_instance_valid(node) or not node.enabled or not node.shadow_enabled:
			continue
		if node.shadow_algorithm != 0:
			algos |= 1 << (node.shadow_algorithm - 1)
		smask_union |= node.shadow_mask
		if node.exclude_scene_occluders or node.shadow_mask != 1:
			mask_potential = true
	active_algos = algos
	_classify_exclusions(lights, receiver_root, mask_potential, smask_union)
	_restore_unculled()

	# Occluder identity before the variant walk (gx_active is exact) and before packing
	# (_pack_excl reads the exempt lists this builds).
	if ysort_enabled or masks_active or not _gx_masks.is_empty():
		_build_occluder_tiles(receiver_root, canvas_xform, vp_size, world_rect, canvas_scale)
	elif gx_active:
		gx_active = false
		_publish_gx(PackedVector4Array())

	_apply_receiver_variants(receiver_root)
	_drive_bare_receivers(receiver_root)

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

## Split exclusions into tiers and set masks_active. Occluder masks no shadow-casting
## light matches land in _gx_masks (global tier, no per-light state); only occluders
## that cast for SOME lights make a light carry per-light exclusions. Skipped outright
## (beyond the light loop in refresh) until a light or SDF-casting occluder shows a
## non-default mask or an exclusion toggle, so mask-free scenes pay nothing here.
func _classify_exclusions(lights: Array, root: Node, potential: bool, smask_union: int) -> void:
	_excl_info.clear()
	_excl_smasks.clear()
	_excl_owners.clear()
	_excl_combos.clear()
	_gx_masks.clear()
	masks_active = false
	if not _mask_seed_done:
		# One-time scan so occluder masks customized before load are honored at start.
		_mask_seed_done = true
		_rebuild_occ_cache(root)
	elif Engine.is_editor_hint() and smask_union != 0:
		# Pre-gate: live mask edits must be seen while masks are inactive too, or the
		# first non-default mask can never open the gate below (stuck until reload).
		if not _occ_dirty:
			_refresh_occ_mask_set()
		if _occ_dirty:
			_rebuild_occ_cache(root)
	if smask_union == 0 or not (potential or _occ_masks_seen):
		return
	if _occ_dirty:
		_rebuild_occ_cache(root)
	for m in _occ_mask_set:
		if (int(m) & smask_union) == 0:
			_gx_masks[m] = true
	for entry in lights:
		var node = entry[0]
		if not is_instance_valid(node) or not node.enabled or not node.shadow_enabled:
			continue
		var owner_id := 0
		if node.exclude_scene_occluders:
			var scope: Node = node.owner if node.owner != null else node.get_parent()
			owner_id = _scope_ids.get(scope, 0)
			if owner_id != 0 and not _scope_has_caster(owner_id):
				owner_id = 0
		var has_excl := owner_id != 0
		if not has_excl:
			var smask: int = node.shadow_mask
			for m in _occ_mask_set:
				if (int(m) & smask) == 0 and (int(m) & smask_union) != 0:
					has_excl = true
					break
		if has_excl:
			var smask: int = node.shadow_mask
			_excl_info[node] = owner_id
			_excl_smasks[smask] = true
			if owner_id != 0:
				_excl_owners[owner_id] = true
			_excl_combos["%d_%d" % [smask, owner_id]] = [smask, owner_id]
			masks_active = true

## Re-enable SDF collision on culled occluders/tileset layers a light's mask matches again.
func _restore_unculled() -> void:
	if _sdf_culled.is_empty() and _ts_culled.is_empty():
		return
	var restore: Array = []
	for occ in _sdf_culled:
		if not is_instance_valid(occ):
			restore.append(occ)
		elif not _gx_masks.has(occ.occluder_light_mask):
			occ.sdf_collision = true
			restore.append(occ)
	for occ in restore:
		_sdf_culled.erase(occ)
	var ts_done: Array = []
	for ts in _ts_culled:
		var layers: Dictionary = _ts_culled[ts]
		var back: Array = []
		for l in layers:
			if l >= ts.get_occlusion_layers_count():
				back.append(l)
			elif not _gx_masks.has(ts.get_occlusion_layer_light_mask(l)):
				ts.set_occlusion_layer_sdf_collision(l, true)
				back.append(l)
		for l in back:
			layers.erase(l)
		if layers.is_empty():
			ts_done.append(ts)
	for ts in ts_done:
		_ts_culled.erase(ts)

## True if the scope owns an SDF caster that isn't already globally excluded.
func _scope_has_caster(owner_id: int) -> bool:
	var sm: Dictionary = _scope_occ_masks.get(owner_id, {})
	for m in sm:
		if not _gx_masks.has(m):
			return true
	return false

## Publish the global exempt rects only when they changed.
func _publish_gx(packed: PackedVector4Array) -> void:
	if packed == _gx_packed:
		return
	_gx_packed = packed
	RenderingServer.global_shader_parameter_set("lit_gx_count", packed.size())
	RenderingServer.global_shader_parameter_set("lit_gx_rect0",
			packed[0] if packed.size() > 0 else Vector4())
	RenderingServer.global_shader_parameter_set("lit_gx_rect1",
			packed[1] if packed.size() > 1 else Vector4())
	RenderingServer.global_shader_parameter_set("lit_gx_rect2",
			packed[2] if packed.size() > 2 else Vector4())
	RenderingServer.global_shader_parameter_set("lit_gx_rect3",
			packed[3] if packed.size() > 3 else Vector4())

## Recompute the distinct-mask set from the cached nodes (editor live edits only).
## Tileset masks are cache-derived, so they are compared against a live snapshot here;
## any drift (mask edit, missed changed signal) marks the cache dirty to self-heal.
func _refresh_occ_mask_set() -> void:
	_occ_mask_set.clear()
	_occ_masks_seen = false
	for entry in _occ_nodes:
		if is_instance_valid(entry[0]) \
				and (entry[0].sdf_collision or _sdf_culled.has(entry[0])):
			_occ_mask_set[entry[0].occluder_light_mask] = true
	for entry in _occ_layers:
		if not is_instance_valid(entry[0]) or entry[0].tile_set == null \
				or entry[6] != _ts_layer_masks(entry[0].tile_set):
			_occ_dirty = true
		for m in entry[5]:
			_occ_mask_set[m] = true
	for m in _occ_mask_set:
		if int(m) != 1:
			_occ_masks_seen = true
			break

## Per-occlusion-layer light masks of a tileset (-1 for non-SDF layers): the snapshot
## cached per layer entry and compared live for editor edits.
func _ts_layer_masks(ts: TileSet) -> PackedInt32Array:
	var masks := PackedInt32Array()
	for l in ts.get_occlusion_layers_count():
		if ts.get_occlusion_layer_sdf_collision(l) or _ts_culled.get(ts, {}).has(l):
			masks.append(ts.get_occlusion_layer_light_mask(l))
		else:
			masks.append(-1)
	return masks

## True if some excluding light exempts an occluder with this mask/owner.
func _exempt_for_any(m: int, owner_id: int) -> bool:
	if owner_id != 0 and _excl_owners.has(owner_id):
		return true
	for s in _excl_smasks:
		if (m & int(s)) == 0:
			return true
	return false

## Pack texels 8-13 (exempt rect count, union bounds, up to 4 exempt rects) for a light
## with exclusions; returns the flags bit. Lights without exclusions pay one has() here.
func _pack_excl(o: int, light: Node2D) -> float:
	if not _excl_info.has(light):
		return 0.0
	var entry = _excl_lists.get("%d_%d" % [light.shadow_mask, _excl_info[light]])
	if entry == null:
		return 0.0
	_pack_buf[o + 32] = float(entry[0])
	var union: Rect2 = entry[1]
	_pack_buf[o + 36] = union.position.x
	_pack_buf[o + 37] = union.position.y
	_pack_buf[o + 38] = union.end.x
	_pack_buf[o + 39] = union.end.y
	var rects: PackedVector4Array = entry[2]
	for j in 4:
		var v := rects[j]
		var b := o + 40 + j * 4
		_pack_buf[b] = v.x
		_pack_buf[b + 1] = v.y
		_pack_buf[b + 2] = v.z
		_pack_buf[b + 3] = v.w
	return 32.0

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
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + 4.0 * float(textured) \
			+ 8.0 * float(light.shadow_algorithm) + _pack_excl(o, light)
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
	var o := row * TEXELS_PER_LIGHT * 4
	var flags := float(light.shadow_enabled) + 2.0 * subtractive \
			+ 8.0 * float(light.shadow_algorithm) + _pack_excl(o, light)
	const TYPE_DIRECTIONAL := 1.0

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

	# Texel 7: tan(source half-angle) | samples | jitter. source_angle is the full
	# angular diameter (the cross-engine convention), halved here to the tangent the
	# cone/stochastic shaders use directly (a directional light has no distance to
	# derive it from).
	_pack_buf[o + 28] = tan(deg_to_rad(light.source_angle) * 0.5)
	_pack_buf[o + 29] = float(mini(light.shadow_samples, shadow_samples_max))
	_pack_buf[o + 30] = light.shadow_jitter

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
	var flags := float(light.shadow_enabled) + 2.0 * subtractive + 4.0 * float(textured) \
			+ 8.0 * float(light.shadow_algorithm) + _pack_excl(o, light)
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
## per-tile header (offset | count) and a flat index list of light rows. The shader reads
## its own tile's header and shades only those rows. Directionals are skipped (they're
## full-screen and shaded directly). Culling is conservative: only (tile, light) pairs
## the shader would shade to exactly zero are dropped, so it never changes the image.
func _build_tiles(visible: Array, canvas_xform: Transform2D, vp_size: Vector2, scale: float) -> void:
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

## Pack every SDF-casting occluder's canvas rect (max.y doubles as its depth line) and
## bin the rects into the light tile grid; mirrors _build_tiles. Header texel z carries
## the tile's min depth so the shader can dismiss whole tiles with one fetch. Frames
## where nothing moved skip the binning and uploads entirely.
func _build_occluder_tiles(root: Node, canvas_xform: Transform2D, vp_size: Vector2,
		world_rect: Rect2, scale: float) -> void:
	if _occ_dirty:
		_rebuild_occ_cache(root)

	# Generous pad: off-view casters still shadow into the oversized SDF.
	var cull_rect := world_rect.grow(maxf(world_rect.size.x, world_rect.size.y) * 0.25)

	# Y-sort needs every caster's identity; masks alone only need the excludable ones
	# (the weight test is only consulted near exempt rects), so non-excluded occluders
	# and whole non-excluded tilemap layers are skipped without per-cell work.
	var full_set := ysort_enabled

	_occ_rects.clear()
	_occ_masks.clear()
	_occ_owners.clear()
	_gx_rects.clear()

	for entry in _occ_nodes:
		var node = entry[0]
		if not is_instance_valid(node):
			_occ_dirty = true
			continue
		var occ := node as LightOccluder2D
		if not occ.is_inside_tree() or not occ.is_visible_in_tree() \
				or occ.occluder == null or occ.occluder.polygon.is_empty():
			continue
		if sdf_cull and occ.sdf_collision and _gx_masks.has(occ.occluder_light_mask):
			# Out of the SDF entirely; _restore_unculled brings it back when wanted.
			occ.sdf_collision = false
			_sdf_culled[occ] = true
		if not occ.sdf_collision:
			continue
		var m: int = occ.occluder_light_mask
		if not _occ_mask_set.has(m):
			# Live mask edits classify correctly from the next frame on.
			_occ_mask_set[m] = true
			if m != 1:
				_occ_masks_seen = true
		var is_gx: bool = _gx_masks.has(m)
		if not full_set and not is_gx and not _exempt_for_any(m, entry[1]):
			continue
		var xf := occ.global_transform
		var r := Rect2(xf * occ.occluder.polygon[0], Vector2.ZERO)
		for p in occ.occluder.polygon:
			r = r.expand(xf * p)
		if not cull_rect.intersects(r):
			continue
		if is_gx:
			_gx_rects.append(r)
			continue
		_occ_rects.append(r)
		_occ_masks.append(m)
		_occ_owners.append(entry[1])

	for entry in _occ_layers:
		var layer: TileMapLayer = entry[0]
		if not is_instance_valid(layer):
			_occ_dirty = true
			continue
		if not layer.is_inside_tree() or not layer.is_visible_in_tree():
			continue
		var culled := {}
		var ts := layer.tile_set
		if ts != null and not _gx_masks.is_empty():
			if sdf_cull:
				for l in ts.get_occlusion_layers_count():
					if ts.get_occlusion_layer_sdf_collision(l) \
							and _gx_masks.has(ts.get_occlusion_layer_light_mask(l)):
						# Out of the SDF like loose occluders; _restore_unculled reverts.
						ts.set_occlusion_layer_sdf_collision(l, false)
						if not _ts_culled.has(ts):
							_ts_culled[ts] = {}
						_ts_culled[ts][l] = true
			for l in _ts_culled.get(ts, {}):
				culled[ts.get_occlusion_layer_light_mask(l)] = true
		if not culled.is_empty():
			var all_culled := true
			for m in entry[5]:
				if not culled.has(m):
					all_culled = false
					break
			if all_culled:
				continue
		var include := {}
		var any_gx := false
		if not full_set:
			for m in entry[5]:
				if culled.has(m):
					continue
				if _gx_masks.has(m):
					any_gx = true
				elif _exempt_for_any(m, 0):
					include[m] = true
			if include.is_empty() and not any_gx:
				continue
		var xf: Transform2D = layer.global_transform
		if entry[2] != xf:
			entry[2] = xf
			var world: Array[Rect2] = []
			world.resize(entry[1].size())
			for i in entry[1].size():
				world[i] = xf * entry[1][i]
			entry[3] = world
		var layer_masks: PackedInt32Array = entry[4]
		for i in entry[3].size():
			var m := layer_masks[i]
			if culled.has(m):
				continue
			var r: Rect2 = entry[3][i]
			if _gx_masks.has(m):
				if cull_rect.intersects(r):
					_gx_rects.append(r)
				continue
			if not full_set and not include.has(m):
				continue
			if cull_rect.intersects(r):
				_occ_rects.append(r)
				_occ_masks.append(m)
				_occ_owners.append(0)

	# Global tier: 4 slots, extras unioned into the last; published as globals so every
	# receiver type sees them with no material walk.
	while _gx_rects.size() > 4:
		_gx_rects[3] = _gx_rects[3].merge(_gx_rects.pop_back())
	gx_active = not _gx_rects.is_empty()
	var gx_packed := PackedVector4Array()
	gx_packed.resize(_gx_rects.size())
	for i in _gx_rects.size():
		gx_packed[i] = Vector4(_gx_rects[i].position.x, _gx_rects[i].position.y,
				_gx_rects[i].end.x, _gx_rects[i].end.y)
	_publish_gx(gx_packed)

	var count := _occ_rects.size()
	var tiles_x := maxi(int(ceil(vp_size.x / float(TILE_SIZE))), 1)
	var tiles_y := maxi(int(ceil(vp_size.y / float(TILE_SIZE))), 1)
	var tile_count := tiles_x * tiles_y
	var grid := Vector2i(tiles_x, tiles_y)

	var floats_needed := maxi(count, 1) * 4
	if _occ_pack_buf.size() != floats_needed:
		_occ_pack_buf.resize(floats_needed)
	if count == 0:
		_occ_pack_buf.fill(0.0)
	for i in count:
		var o := i * 4
		var r := _occ_rects[i]
		_occ_pack_buf[o + 0] = r.position.x
		_occ_pack_buf[o + 1] = r.position.y
		_occ_pack_buf[o + 2] = r.end.x
		_occ_pack_buf[o + 3] = r.end.y

	var pack_same := _occ_pack_buf == _occ_prev_pack
	if masks_active:
		# The lists depend on per-rect masks/owners too, not just the rect bytes: a mask
		# edit can move a rect between lists while the pack stays identical.
		var combo_sig := str(_excl_combos.keys())
		if not pack_same or combo_sig != _prev_combo_sig \
				or _occ_masks != _prev_excl_masks or _occ_owners != _prev_excl_owners:
			_prev_combo_sig = combo_sig
			_prev_excl_masks = _occ_masks.duplicate()
			_prev_excl_owners = _occ_owners.duplicate()
			_rebuild_excl_lists()
	# Masks alone need no tile binning; the exempt rects travel in the light rows.
	if not ysort_enabled:
		if not pack_same:
			_occ_prev_pack = _occ_pack_buf.duplicate()
		return
	if pack_same and canvas_xform == _occ_prev_xform and grid == _occ_prev_grid:
		return
	if not pack_same:
		_occ_prev_pack = _occ_pack_buf.duplicate()
	_occ_prev_xform = canvas_xform
	_occ_prev_grid = grid

	if _occ_tile_counts.size() != tile_count:
		_occ_tile_counts.resize(tile_count)
		_occ_tile_min.resize(tile_count)
	_occ_tile_counts.fill(0)
	_occ_tile_min.fill(3.4e38)
	if _occ_spans.size() != count * 4:
		_occ_spans.resize(count * 4)

	# Candidacy tests reach past a rect, so bin each one tile edge wider.
	var bin_pad := float(TILE_SIZE)
	var total := 0

	for i in count:
		var r := _occ_rects[i]
		var sr: Rect2 = canvas_xform * r
		var tx0 := clampi(int(floor((sr.position.x - bin_pad) / float(TILE_SIZE))), 0, tiles_x - 1)
		var tx1 := clampi(int(floor((sr.end.x + bin_pad) / float(TILE_SIZE))), 0, tiles_x - 1)
		var ty0 := clampi(int(floor((sr.position.y - bin_pad) / float(TILE_SIZE))), 0, tiles_y - 1)
		var ty1 := clampi(int(floor((sr.end.y + bin_pad) / float(TILE_SIZE))), 0, tiles_y - 1)
		var s4 := i * 4
		_occ_spans[s4 + 0] = tx0
		_occ_spans[s4 + 1] = tx1
		_occ_spans[s4 + 2] = ty0
		_occ_spans[s4 + 3] = ty1
		total += (tx1 - tx0 + 1) * (ty1 - ty0 + 1)
		var depth := r.end.y
		for ty in range(ty0, ty1 + 1):
			var row_base := ty * tiles_x
			for tx in range(tx0, tx1 + 1):
				var t := row_base + tx
				_occ_tile_counts[t] += 1
				if depth < _occ_tile_min[t]:
					_occ_tile_min[t] = depth

	var idx_rows := int(ceil(float(maxi(total, 1)) / float(INDEX_TEX_WIDTH)))
	var header_floats := tile_count * 4
	if _occ_header_buf.size() != header_floats:
		_occ_header_buf.resize(header_floats)
	var index_floats := INDEX_TEX_WIDTH * idx_rows * 4
	if _occ_index_buf.size() != index_floats:
		_occ_index_buf.resize(index_floats)

	var offset := 0
	for t in tile_count:
		var cnt := _occ_tile_counts[t]
		var h := t * 4
		_occ_header_buf[h] = float(offset)
		_occ_header_buf[h + 1] = float(cnt)
		_occ_header_buf[h + 2] = _occ_tile_min[t]
		_occ_tile_counts[t] = offset
		offset += cnt
	for i in count:
		var s4 := i * 4
		for ty in range(_occ_spans[s4 + 2], _occ_spans[s4 + 3] + 1):
			var row_base := ty * tiles_x
			for tx in range(_occ_spans[s4 + 0], _occ_spans[s4 + 1] + 1):
				var slot := _occ_tile_counts[row_base + tx]
				_occ_tile_counts[row_base + tx] = slot + 1
				_occ_index_buf[slot * 4] = float(i)

	if not pack_same or _occ_tex == null:
		var rows := maxi(count, 1)
		var data_bytes := _occ_pack_buf.to_byte_array()
		if _occ_img == null or _occ_img.get_height() != rows:
			_occ_img = Image.create_from_data(1, rows, false, Image.FORMAT_RGBAF, data_bytes)
		else:
			_occ_img.set_data(1, rows, false, Image.FORMAT_RGBAF, data_bytes)
		var prev_data := _occ_tex
		_occ_tex = _make_or_update(_occ_tex, _occ_img)
		if _occ_tex != prev_data:
			RenderingServer.global_shader_parameter_set("lit_occ_data", _occ_tex)

	var header_bytes := _occ_header_buf.to_byte_array()
	if _occ_header_img == null or _occ_header_img.get_width() != tiles_x \
			or _occ_header_img.get_height() != tiles_y:
		_occ_header_img = Image.create_from_data(tiles_x, tiles_y, false, Image.FORMAT_RGBAF, header_bytes)
	else:
		_occ_header_img.set_data(tiles_x, tiles_y, false, Image.FORMAT_RGBAF, header_bytes)
	var prev_header := _occ_header_tex
	_occ_header_tex = _make_or_update(_occ_header_tex, _occ_header_img)
	if _occ_header_tex != prev_header:
		RenderingServer.global_shader_parameter_set("lit_occ_headers", _occ_header_tex)

	var index_bytes := _occ_index_buf.to_byte_array()
	if _occ_index_img == null or _occ_index_img.get_height() != idx_rows:
		_occ_index_img = Image.create_from_data(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF, index_bytes)
	else:
		_occ_index_img.set_data(INDEX_TEX_WIDTH, idx_rows, false, Image.FORMAT_RGBAF, index_bytes)
	var prev_index := _occ_index_tex
	_occ_index_tex = _make_or_update(_occ_index_tex, _occ_index_img)
	if _occ_index_tex != prev_index:
		RenderingServer.global_shader_parameter_set("lit_occ_indices", _occ_index_tex)

## Rescan the subtree for casters; tilemap cell rects cache until the layer changes.
## Also assigns scene owner ids (one per light scope root) and snapshots the distinct
## occluder-mask set.
func _rebuild_occ_cache(root: Node) -> void:
	_occ_nodes.clear()
	_occ_layers.clear()
	_scope_ids.clear()
	_scope_occ_masks.clear()
	_occ_mask_set.clear()
	_occ_masks_seen = false
	_occ_dirty = false
	if root == null:
		return
	for entry in _light_cache:
		var light = entry[0]
		if not is_instance_valid(light) or not light.is_inside_tree():
			continue
		var scope: Node = light.owner if light.owner != null else light.get_parent()
		if scope != null and not _scope_ids.has(scope):
			_scope_ids[scope] = _scope_ids.size() + 1
	for occ in root.find_children("*", "LightOccluder2D", true, false):
		var owner_id := _occ_owner_id(occ)
		_occ_nodes.append([occ, owner_id])
		# Only SDF casters matter to exclusion; others cast no Lit shadows at all.
		# Culled occluders still count so their mask stays classified (no oscillation).
		if not occ.sdf_collision and not _sdf_culled.has(occ):
			continue
		if owner_id != 0:
			if not _scope_occ_masks.has(owner_id):
				_scope_occ_masks[owner_id] = {}
			_scope_occ_masks[owner_id][occ.occluder_light_mask] = true
		_occ_mask_set[occ.occluder_light_mask] = true
	for layer in root.find_children("*", "TileMapLayer", true, false):
		var pair := tile_caster_rects(layer)
		if pair[0].is_empty():
			continue
		if not layer.changed.is_connected(_on_tilemap_changed):
			layer.changed.connect(_on_tilemap_changed)
		var distinct := {}
		for m in pair[1]:
			distinct[m] = true
			_occ_mask_set[m] = true
		_occ_layers.append([layer, pair[0], null, [], pair[1], distinct.keys(),
				_ts_layer_masks(layer.tile_set)])
	for m in _occ_mask_set:
		if int(m) != 1:
			_occ_masks_seen = true
			break

## Nearest ancestor that is a light scope root; 0 when none.
func _occ_owner_id(occ: Node) -> int:
	var n: Node = occ
	while n != null:
		if _scope_ids.has(n):
			return _scope_ids[n]
		n = n.get_parent()
	return 0

## Per-combo exempt rect lists (4 slots, extras unioned into the last) over the gathered
## occluder rects; valid until the pack, per-rect masks/owners, or the combo set change.
func _rebuild_excl_lists() -> void:
	_excl_lists.clear()
	for key in _excl_combos:
		var smask: int = _excl_combos[key][0]
		var owner_id: int = _excl_combos[key][1]
		var rects: Array[Rect2] = []
		for i in _occ_rects.size():
			if (_occ_masks[i] & smask) == 0 or (owner_id != 0 and _occ_owners[i] == owner_id):
				rects.append(_occ_rects[i])
		if rects.is_empty():
			continue
		while rects.size() > 4:
			rects[3] = rects[3].merge(rects.pop_back())
		var union := rects[0]
		var packed := PackedVector4Array()
		packed.resize(4)
		for i in rects.size():
			union = union.merge(rects[i])
			packed[i] = Vector4(rects[i].position.x, rects[i].position.y, rects[i].end.x, rects[i].end.y)
		_excl_lists[key] = [rects.size(), union, packed]

## [rects, masks]: one layer-local rect per painted cell and occlusion mask group among
## the SDF-collision layers (culled layers included so their mask stays classified), with
## the group's light mask parallel in the second array.
func tile_caster_rects(layer: TileMapLayer) -> Array:
	var rects: Array[Rect2] = []
	var masks := PackedInt32Array()
	var ts := layer.tile_set
	if ts == null:
		return [rects, masks]
	var sdf_layers: Array[int] = []
	var layer_masks: Array[int] = []
	for l in ts.get_occlusion_layers_count():
		if ts.get_occlusion_layer_sdf_collision(l) or _ts_culled.get(ts, {}).has(l):
			sdf_layers.append(l)
			layer_masks.append(ts.get_occlusion_layer_light_mask(l))
	if sdf_layers.is_empty():
		return [rects, masks]
	var poly_rects := {}
	for cell in layer.get_used_cells():
		var td := layer.get_cell_tile_data(cell)
		if td == null:
			continue
		var by_mask := {}
		for li in sdf_layers.size():
			var l := sdf_layers[li]
			for p in td.get_occluder_polygons_count(l):
				var poly: OccluderPolygon2D = td.get_occluder_polygon(l, p)
				if poly == null or poly.polygon.is_empty():
					continue
				var pr: Rect2
				if poly_rects.has(poly):
					pr = poly_rects[poly]
				else:
					pr = Rect2(poly.polygon[0], Vector2.ZERO)
					for pt in poly.polygon:
						pr = pr.expand(pt)
					poly_rects[poly] = pr
				var m := layer_masks[li]
				by_mask[m] = pr if not by_mask.has(m) else by_mask[m].merge(pr)
		if by_mask.is_empty():
			continue
		var base := layer.map_to_local(cell)
		for m in by_mask:
			var r: Rect2 = by_mask[m]
			r.position += base
			rects.append(r)
			masks.append(m)
	return [rects, masks]

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

func _on_tree_changed(node: Node) -> void:
	_cache_dirty = true
	_receiver_dirty = true
	if node is Sprite2D or node is AnimatedSprite2D or node is TileMapLayer or node is LightOccluder2D:
		_bare_dirty = true
	if node is TileMapLayer or node is LightOccluder2D:
		_occ_dirty = true
		if node is LightOccluder2D:
			if node.sdf_collision and node.occluder_light_mask != 1:
				_occ_masks_seen = true
		elif node.tile_set != null:
			var ts: TileSet = node.tile_set
			for l in ts.get_occlusion_layers_count():
				if ts.get_occlusion_layer_light_mask(l) != 1:
					_occ_masks_seen = true
					break
	elif node is LitPointLight2D or node is LitSpotLight2D or node is LitDirectionalLight2D:
		# Scope roots follow the light set.
		_occ_dirty = true


## Re-point every Lit receiver material under `root` at the variant compiled for the
## currently active shadow algorithms, preserving each material's fast/full axis
## (LitSprite2D owns that axis and converges to the same target). Work happens only
## when the mask changed, or when the tree changed while a non-base mask is active
## (newly added receivers arrive on the base variant and need the swap); a scene that
## never uses the physical algorithms never walks the tree here.
func _apply_receiver_variants(root: Node) -> void:
	var mask := active_algos & 3
	var key := mask | (4 if masks_active else 0) | (8 if gx_active else 0)
	if key == _published_algos and (key == 0 or not _receiver_dirty):
		return
	if root == null:
		return
	var mats := {}
	_collect_receiver_mats(root, mats)
	for mat in mats:
		var path: String = mat.shader.resource_path
		var table := _tier_table(RECEIVER_FAST_VARIANTS, RECEIVER_FAST_GX_VARIANTS,
				RECEIVER_FAST_MASK_VARIANTS)
		if path in RECEIVER_YSORT_VARIANTS or path in RECEIVER_YSORT_GX_VARIANTS \
				or path in RECEIVER_YSORT_MASK_VARIANTS:
			table = _tier_table(RECEIVER_YSORT_VARIANTS, RECEIVER_YSORT_GX_VARIANTS,
					RECEIVER_YSORT_MASK_VARIANTS)
		elif path in RECEIVER_FULL_VARIANTS or path in RECEIVER_FULL_GX_VARIANTS \
				or path in RECEIVER_FULL_MASK_VARIANTS:
			table = _tier_table(RECEIVER_FULL_VARIANTS, RECEIVER_FULL_GX_VARIANTS,
					RECEIVER_FULL_MASK_VARIANTS)
		var wanted: String = table[mask]
		if path != wanted:
			mat.shader = load(wanted)
	_published_algos = key
	_receiver_dirty = false

## Pick the tier's table: per-light exclusions beat gx (the _mask variants carry both).
static func _tier_table(base: Array[String], gx: Array[String], mk: Array[String]) -> Array[String]:
	if masks_active:
		return mk
	if gx_active:
		return gx
	return base


## Collect (deduped, as Dictionary keys) every ShaderMaterial in the subtree whose
## shader is one of the Lit receiver variants. Materials shared across nodes are
## visited once.
func _collect_receiver_mats(node: Node, acc: Dictionary) -> void:
	var ci := node as CanvasItem
	if ci != null:
		var mat := ci.material as ShaderMaterial
		if mat != null and mat.shader != null and _is_lit_receiver_path(mat.shader.resource_path):
			acc[mat] = true
	for child in node.get_children():
		_collect_receiver_mats(child, acc)

var _bare_cache: Array = []      # [node, mat, occluders, last rects, last count, tile rects]
var _bare_driven := {}
var _bare_dirty := true
var _bare_shared_warned := false

func _drive_bare_receivers(root: Node) -> void:
	if root == null:
		return
	if _bare_dirty:
		_rebuild_bare_cache(root)
	for entry in _bare_cache:
		var spr: Node2D = entry[0]
		var mat: ShaderMaterial = entry[1]
		if not is_instance_valid(spr) or not spr.is_inside_tree() \
				or spr.material != mat or mat.shader == null:
			_bare_dirty = true
			continue
		_push_self_rects(entry)

func _rebuild_bare_cache(root: Node) -> void:
	_bare_cache.clear()
	var by_mat := {}
	_collect_bare_receivers(root, by_mat)
	var driven := {}
	for mat in by_mat:
		var nodes: Array = by_mat[mat]
		if nodes.size() > 1:
			if not _bare_shared_warned and _any_owns_occluders(nodes):
				_bare_shared_warned = true
				push_warning("Lit: a receiver material is shared by %d nodes; self-shadow exclusion needs one material per node." % nodes.size())
			continue
		var node = nodes[0]
		var tile_rects: Array[Rect2] = []
		var tml := node as TileMapLayer
		if tml != null:
			tile_rects = tile_occluder_rects(tml)
			if not tml.changed.is_connected(_on_tilemap_changed):
				tml.changed.connect(_on_tilemap_changed)
		var occluders := _owned_occluders(node)
		if occluders.is_empty() and tile_rects.is_empty():
			# Heal stale rects a scene save may have baked into the material.
			var stale = mat.get_shader_parameter("self_rect_count")
			if stale != null and int(stale) != 0:
				mat.set_shader_parameter("self_rect_count", 0)
			continue
		_bare_cache.append([node, mat, occluders, PackedVector4Array(), -1, tile_rects, false, 0.0])
		driven[mat] = true
	for mat in _bare_driven:
		if not driven.has(mat) and is_instance_valid(mat):
			mat.set_shader_parameter("self_rect_count", 0)
	_bare_driven = driven
	_bare_dirty = false

func _on_tilemap_changed() -> void:
	_bare_dirty = true
	_occ_dirty = true

func _collect_bare_receivers(node: Node, acc: Dictionary) -> void:
	if (node is Sprite2D or node is AnimatedSprite2D or node is TileMapLayer) \
			and not node.has_method("_update_self_rect"):
		var mat := (node as CanvasItem).material as ShaderMaterial
		if mat != null and mat.shader != null and _is_lit_receiver_path(mat.shader.resource_path):
			if not acc.has(mat):
				acc[mat] = []
			acc[mat].append(node)
	for child in node.get_children():
		_collect_bare_receivers(child, acc)

func _owned_occluders(spr: Node) -> Array:
	var occluders: Array = []
	for child in spr.find_children("*", "LightOccluder2D", true, false):
		occluders.append(child)
	# A tilemap's siblings are unrelated level content, not its own occluders.
	if spr is TileMapLayer:
		return occluders
	var parent := spr.get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling is LightOccluder2D:
				occluders.append(sibling)
	return occluders

func _any_owns_occluders(nodes: Array) -> bool:
	for n in nodes:
		if not _owned_occluders(n).is_empty():
			return true
		if n is TileMapLayer and not tile_occluder_rects(n).is_empty():
			return true
	return false

## Local-space bounds of the tileset occlusion polygons on this layer's painted cells:
## one tight rect per occluder cell up to the shader's 4 slots, a single union beyond.
static func tile_occluder_rects(layer: TileMapLayer) -> Array[Rect2]:
	var ts := layer.tile_set
	if ts == null:
		return []
	var occ_layers := ts.get_occlusion_layers_count()
	if occ_layers == 0:
		return []
	var poly_rects := {}
	var rects: Array[Rect2] = []
	var union := Rect2()
	var count := 0
	for cell in layer.get_used_cells():
		var td := layer.get_cell_tile_data(cell)
		if td == null:
			continue
		var cell_rect := Rect2()
		var has_cell := false
		for l in occ_layers:
			for p in td.get_occluder_polygons_count(l):
				var poly: OccluderPolygon2D = td.get_occluder_polygon(l, p)
				if poly == null or poly.polygon.is_empty():
					continue
				var pr: Rect2
				if poly_rects.has(poly):
					pr = poly_rects[poly]
				else:
					pr = Rect2(poly.polygon[0], Vector2.ZERO)
					for pt in poly.polygon:
						pr = pr.expand(pt)
					poly_rects[poly] = pr
				cell_rect = pr if not has_cell else cell_rect.merge(pr)
				has_cell = true
		if not has_cell:
			continue
		cell_rect.position += layer.map_to_local(cell)
		union = cell_rect if count == 0 else union.merge(cell_rect)
		count += 1
		if count <= 4:
			rects.append(cell_rect)
	if count > 4:
		var single: Array[Rect2] = [union]
		return single
	return rects

# Keep aligned with LitSprite2D._update_self_rect.
func _push_self_rects(entry: Array) -> void:
	var spr: Node2D = entry[0]
	var mat: ShaderMaterial = entry[1]
	var rects: Array[Rect2] = []
	for tile_rect in entry[5]:
		rects.append(spr.global_transform * tile_rect)
	for node in entry[2]:
		if not is_instance_valid(node):
			_bare_dirty = true
			continue
		var occ := node as LightOccluder2D
		if occ == null or not occ.is_inside_tree() \
				or occ.occluder == null or occ.occluder.polygon.is_empty():
			continue
		var xf := occ.global_transform
		var r := Rect2(xf * occ.occluder.polygon[0], Vector2.ZERO)
		for p in occ.occluder.polygon:
			r = r.expand(xf * p)
		rects.append(r)
	while rects.size() > 4:
		rects[3] = rects[3].merge(rects.pop_back())
	var packed := PackedVector4Array()
	packed.resize(4)
	for i in rects.size():
		packed[i] = Vector4(rects[i].position.x, rects[i].position.y, rects[i].end.x, rects[i].end.y)
	if packed != entry[3] or rects.size() != entry[4]:
		entry[3] = packed
		entry[4] = rects.size()
		mat.set_shader_parameter("self_rects", packed)
		mat.set_shader_parameter("self_rect_count", rects.size())

	# Y-sort participation: occluder-owning sprites only, depth = footprint bottom.
	var ys_on := false
	var ys_y := 0.0
	if ysort_enabled and not (spr is TileMapLayer) and not rects.is_empty():
		ys_on = true
		ys_y = rects[0].end.y
		for r in rects:
			ys_y = maxf(ys_y, r.end.y)

	var wants_full: bool = rects.size() > 0 and mat.get_shader_parameter("self_shadow") != true
	var path: String = mat.shader.resource_path
	if _is_lit_receiver_path(path):
		var table := _tier_table(RECEIVER_FAST_VARIANTS, RECEIVER_FAST_GX_VARIANTS,
				RECEIVER_FAST_MASK_VARIANTS)
		if ys_on:
			table = _tier_table(RECEIVER_YSORT_VARIANTS, RECEIVER_YSORT_GX_VARIANTS,
					RECEIVER_YSORT_MASK_VARIANTS)
		elif wants_full:
			table = _tier_table(RECEIVER_FULL_VARIANTS, RECEIVER_FULL_GX_VARIANTS,
					RECEIVER_FULL_MASK_VARIANTS)
		var wanted: String = table[active_algos & 3]
		if path != wanted:
			mat.shader = load(wanted)

	# After the swap, so the params land on a shader declaring them.
	if entry[6] != ys_on or entry[7] != ys_y:
		entry[6] = ys_on
		entry[7] = ys_y
		mat.set_shader_parameter("ysort_on", ys_on)
		mat.set_shader_parameter("ysort_y", ys_y)

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
