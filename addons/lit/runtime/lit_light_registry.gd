extends RefCounted
class_name LitLightRegistry

## Shared gather / cull / pack logic.
##
## Driven by lit_manager.gd (the autoload) at runtime, and by lit_plugin.gd for
## editor-live preview. Both call the same refresh().
##
## Each instance owns its own light-data texture, so the editor and a running game
## (separate processes and RenderingServer state) never collide.

const TEXELS_PER_LIGHT := 14

# Which shadow algorithms the shaders must support this frame, from the last refresh()
# in this process (bit 0 = Cone Traced, bit 1 = Stochastic, among enabled shadow-casting
# lights). LitSprite2D reads it every frame to pick its receiver shader variant, and
# refresh() itself re-points every other Lit receiver material via the receiver
# driver's variant walk, so the per-light algorithm dropdown works on all receivers
# (tool-converted nodes, tilemaps, hand-assigned materials) with no manual shader swap.
static var active_algos: int = 0

# LitShaderLibrary F_* activity bits, published once per refresh; active_algos /
# masks_active / gx_active remain the authoritative mirrors until plan 3 finalizes them.
static var activity_flags: int = 0

# False again after the editor's save-time script reload wipes statics; any registry
# refreshing then re-walks so RS-clone previews (wiped with the statics) rebuild.
static var _statics_alive := false

static func _activity_mirror() -> int:
	return (LitShaderLibrary.F_CONE if active_algos & 1 != 0 else 0) \
			| (LitShaderLibrary.F_STOCH if active_algos & 2 != 0 else 0) \
			| (LitShaderLibrary.F_MASKS if masks_active else 0) \
			| (LitShaderLibrary.F_GX if gx_active else 0)

# Receiver variant application and bare-receiver driving: registry/receiver_driver.gd
# owns the published-variant memo and the bare cache.
const ReceiverDriverScript := preload("res://addons/lit/runtime/registry/receiver_driver.gd")
var _receiver_driver := ReceiverDriverScript.new()

# CPU-side clamp on each light's shadow_samples, from lit/quality/shadow_samples_max;
# set by the owner (LitManager at runtime, the plugin in the editor). The shader
# additionally clamps to its compile-time LIT_MAX_SHADOW_SAMPLES = 32.
var shadow_samples_max: int = 32

# World-space shadow SDF subsystem: registry/world_sdf.gd owns the SubViewport, the
# R16F RD pack pipeline, and content polling.
const WorldSdfScript := preload("res://addons/lit/runtime/registry/world_sdf.gd")
var _world_sdf := WorldSdfScript.new()

# Light packing (pack buffer, data texture, cookie atlas) and the screen-tile light
# grid; each module owns its textures and publishes its own globals.
const LightPackerScript := preload("res://addons/lit/runtime/registry/light_packer.gd")
const ScreenTilesScript := preload("res://addons/lit/runtime/registry/screen_tiles.gd")
var _light_packer := LightPackerScript.new()
var _screen_tiles := ScreenTilesScript.new()

# Shared with the occluder tile grid below until its own module lands.
const TILE_SIZE := ScreenTilesScript.TILE_SIZE
const INDEX_TEX_WIDTH := ScreenTilesScript.INDEX_TEX_WIDTH

# Per-frame data spine shared with the modules (view data, light set, frame outputs).
const FrameContextScript := preload("res://addons/lit/runtime/registry/frame_context.gd")
var _ctx := FrameContextScript.new()

# Light cache and tree watching: registry/light_cache.gd owns the [node, kind] list;
# its tree-change handler dirties the cache, then fans out to _on_tree_changed here.
const LightCacheScript := preload("res://addons/lit/runtime/registry/light_cache.gd")
var _light_cache := LightCacheScript.new()


func _init() -> void:
	_light_cache.set_fan_out(_on_tree_changed)
	_occluder_tiles.set_fan_out(_on_tilemap_changed)
	_receiver_driver.set_fan_out(_on_tilemap_changed)

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
# True once any light has shown a non-default shadow_mask or exclusion toggle (set by
# the light setters, scene loads included); gates the per-light mask reads in refresh.
static var light_masks_seen: bool = false

# --- Per-receiver shadow exclusion (shadow_ignore_mask) ------------------------------
# Node-facing static API; the node set and rx bounds driving live in
# registry/rx_registry.gd (its statics are shared by both editor registry instances
# and wiped-and-rescanned like all editor statics).
const RxRegistryScript := preload("res://addons/lit/runtime/registry/rx_registry.gd")
var _rx_registry := RxRegistryScript.new()

static func rx_set(node: CanvasItem, mask: int) -> void:
	RxRegistryScript.rx_set(node, mask)

# --- Editor live materials -----------------------------------------------------------
# Node- and plugin-facing static API; the clone and authored-uniform maps live in
# registry/editor_live.gd (statics shared by both editor registry instances).
const EditorLiveScript := preload("res://addons/lit/runtime/registry/editor_live.gd")

static func editor_live_material(ci: CanvasItem, base: ShaderMaterial) -> ShaderMaterial:
	return EditorLiveScript.live_material(ci, base)

static func editor_release_live() -> void:
	EditorLiveScript.release_all()

# Occluder identity subsystem: registry/occluder_tiles.gd owns the caster cache, tile
# binning, gx publish, and sdf-cull state. Exclusion code below still reaches its cache
# fields directly; that surface dissolves when exclusions extract (step 5).
const OccluderTilesScript := preload("res://addons/lit/runtime/registry/occluder_tiles.gd")
var _occluder_tiles := OccluderTilesScript.new()

var _mask_seed_done := false
# Runtime only (lit/render/occluder_mask_sdf_culling): globally excluded occluders are
# pulled out of the SDF entirely instead of exempted in-shader - marches get faster, not
# slower. Never set in the editor, where mutating scene nodes would risk saves; the
# editor previews via the _gx shader tier instead.
var sdf_cull := false

# Exclusion classification, gx tiers, and exempt lists: registry/exclusions.gd.
const ExclusionsScript := preload("res://addons/lit/runtime/registry/exclusions.gd")
var _exclusions := ExclusionsScript.new()

func set_ysort(enabled: bool) -> void:
	if ysort_enabled == enabled:
		return
	ysort_enabled = enabled
	_receiver_driver._bare_dirty = true
	_occluder_tiles._occ_dirty = true
	_occluder_tiles._occ_prev_pack = PackedFloat32Array()

## Gather visible lights, pack them into the light-data texture, build the tile grid,
## and publish the global shader uniforms. Call once per frame. receiver_root bounds
## the receiver-material walk for the shadow-algorithm variant swap (the game tree root
## at runtime, the edited scene root in the editor); null skips that swap. sdf_host owns
## the world-SDF SubViewport (LitManager at runtime, the plugin in the editor); null
## skips the world SDF (headless probes).
func refresh(tree: SceneTree, viewport: Viewport, receiver_root: Node = null, sdf_host: Node = null) -> void:
	if not _ctx.begin(tree, viewport):
		return
	# Published before the early returns so the uniform is always fresh.
	RenderingServer.global_shader_parameter_set("lit_canvas_scale", _ctx.canvas_scale)

	# Collect enabled, visible lights from the cache (view-culled), plus the full
	# cached list for the tree-wide scans below.
	_ctx.visible = _light_cache.cull_visible(tree, _ctx.world_rect)
	var lights: Array = _light_cache.all()

	var count: int = _ctx.visible.size()

	if sdf_host != null:
		_world_sdf.update(sdf_host, viewport, _ctx.visible, _ctx.canvas_xform,
				_ctx.world_rect, receiver_root if receiver_root != null else tree.root)

	# Publish which non-raymarched shadow algorithms are in play and re-point receiver
	# materials to a variant compiled with exactly those (base scenes stay on the base
	# shader). Computed over every enabled light in the tree, not just the view-culled
	# set, so camera movement past a light's AABB never thrashes receiver shaders. Only
	# shadow-casting lights count: an algorithm on a shadowless light is never marched.
	var algos := 0
	var mask_potential: bool = _occluder_tiles._occ_masks_seen
	var smask_union := 0
	# The per-light reads only matter once a light or occluder has ever shown mask
	# potential; the editor always reads so live inspector edits are never missed.
	var read_masks: bool = light_masks_seen or _occluder_tiles._occ_masks_seen \
			or Engine.is_editor_hint()
	for entry in lights:
		# Untyped: enabled/shadow_enabled/shadow_algorithm live on each light class,
		# not on a shared base.
		var node = entry[0]
		if not is_instance_valid(node) or not node.enabled or not node.shadow_enabled:
			continue
		if node.shadow_algorithm != 0:
			algos |= 1 << (node.shadow_algorithm - 1)
		if read_masks:
			var smask: int = node.shadow_mask
			smask_union |= smask
			if smask != 1 or node.exclude_scene_occluders:
				mask_potential = true
	active_algos = algos
	# Skippable only while no light or occluder has ever shown mask potential, when
	# both calls are provably no-ops (their state is empty by construction).
	if read_masks or not _mask_seed_done:
		_classify_exclusions(lights, receiver_root, mask_potential, smask_union)
		_occluder_tiles.restore_unculled(_exclusions._gx_masks)
	_ctx.excl_active = not _exclusions._excl_info.is_empty()
	if masks_active:
		_ctx.texels_per_light = TEXELS_PER_LIGHT

	# Occluder identity before the variant walk (gx_active is exact) and before packing
	# (_pack_excl and the t7.w shadow-mask pack read what this builds).
	if Engine.is_editor_hint():
		if not _statics_alive:
			_statics_alive = true
			_receiver_driver._receiver_dirty = true
		RxRegistryScript.rescan_editor(receiver_root)
	if RxRegistryScript._rx_nodes.is_empty():
		_ctx.rx_union = 0
	if ysort_enabled or masks_active or not _exclusions._gx_masks.is_empty() \
			or not RxRegistryScript._rx_nodes.is_empty():
		_ctx.rx_union = _rx_registry.compute_union()
		var pack_same: bool = _occluder_tiles.build(_ctx, receiver_root, lights,
				_exclusions._gx_masks, _exclusions._excl_smasks, _exclusions._excl_owners,
				ysort_enabled, sdf_cull)
		gx_active = _occluder_tiles._gx_frame
		if masks_active:
			_exclusions.maybe_rebuild_lists(pack_same, _ctx.occ_rects, _ctx.occ_masks,
					_ctx.occ_owners)
	elif gx_active:
		gx_active = false
		_occluder_tiles.publish_gx_empty()

	activity_flags = _activity_mirror()
	_receiver_driver.apply(receiver_root, activity_flags, RxRegistryScript._rx_nodes,
			editor_live_material)
	_receiver_driver.drive_bare(receiver_root, activity_flags, ysort_enabled,
			editor_live_material)
	if _ctx.rx_union != 0:
		_rx_registry.drive_bounds(_ctx.occ_rects, _ctx.occ_masks, editor_live_material)
	if Engine.is_editor_hint():
		EditorLiveScript.sync()

	# Zero-light case: count 0 plus a 1x1 dummy (never a 4x0 image) and empty tiles.
	if count == 0:
		_light_packer.publish_empty(_ctx.vp_size)
		_screen_tiles.publish_empty(_ctx.vp_size)
		return

	# Pack directionals into the leading rows, then positional lights. The shader shades
	# rows [0, dir_count) for every fragment and finds the rest through the tile grid, so
	# this ordering keeps row indices consistent between the data texture and the buckets.
	var directionals: Array = []
	var positional: Array = []
	for l in _ctx.visible:
		if l is LitDirectionalLight2D:
			directionals.append(l)
		else:
			positional.append(l)
	_ctx.visible = directionals + positional
	_ctx.positional = positional
	_ctx.dir_count = directionals.size()

	# Cookie atlas + pack + light-data globals, then the screen-tile grid the shader
	# culls against; row order in the data texture matches ctx.visible for both.
	_light_packer.pack_and_publish(_ctx, _exclusions._excl_info, _exclusions._excl_lists,
			shadow_samples_max)
	_screen_tiles.build_and_publish(_ctx)

## Split exclusions into tiers and set masks_active. Occluder masks no shadow-casting
## light matches land in _gx_masks (global tier, no per-light state); only occluders
## that cast for SOME lights make a light carry per-light exclusions. Skipped outright
## (beyond the light loop in refresh) until a light or SDF-casting occluder shows a
## non-default mask or an exclusion toggle, so mask-free scenes pay nothing here.
func _classify_exclusions(lights: Array, root: Node, potential: bool, smask_union: int) -> void:
	_exclusions.clear_frame()
	masks_active = false
	if not _mask_seed_done:
		# One-time scan so occluder masks customized before load are honored at start.
		_mask_seed_done = true
		_occluder_tiles.ensure_fresh(root, _light_cache.all(), false)
	elif Engine.is_editor_hint() and smask_union != 0:
		# Pre-gate: live mask edits must be seen while masks are inactive too, or the
		# first non-default mask can never open the gate below (stuck until reload).
		_occluder_tiles.ensure_fresh(root, _light_cache.all(), true)
	if smask_union == 0 or not (potential or _occluder_tiles._occ_masks_seen):
		return
	_occluder_tiles.ensure_fresh(root, _light_cache.all(), false)
	masks_active = _exclusions.classify(lights, smask_union, _occluder_tiles._occ_mask_set,
			_occluder_tiles._scope_ids, _occluder_tiles._scope_occ_masks)

func _on_tree_changed(node: Node) -> void:
	_receiver_driver._receiver_dirty = true
	if node is Sprite2D or node is AnimatedSprite2D or node is TileMapLayer or node is LightOccluder2D:
		_receiver_driver._bare_dirty = true
	if node is TileMapLayer or node is LightOccluder2D:
		_occluder_tiles._occ_dirty = true
		_world_sdf.mark_content_dirty()
		if node is LightOccluder2D:
			if node.sdf_collision and node.occluder_light_mask != 1:
				_occluder_tiles._occ_masks_seen = true
		elif node.tile_set != null:
			var ts: TileSet = node.tile_set
			for l in ts.get_occlusion_layers_count():
				if ts.get_occlusion_layer_light_mask(l) != 1:
					_occluder_tiles._occ_masks_seen = true
					break
	elif node is LitPointLight2D or node is LitSpotLight2D or node is LitDirectionalLight2D:
		# Scope roots follow the light set.
		_occluder_tiles._occ_dirty = true

func _on_tilemap_changed() -> void:
	_receiver_driver._bare_dirty = true
	_occluder_tiles._occ_dirty = true

## Node-facing static API; the walk lives in registry/receiver_driver.gd.
static func tile_occluder_rects(layer: TileMapLayer) -> Array[Rect2]:
	return ReceiverDriverScript.tile_occluder_rects(layer)
