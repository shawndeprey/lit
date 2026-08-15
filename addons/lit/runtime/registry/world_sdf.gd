extends RefCounted

## World-space shadow SDF: a hidden SubViewport shares the scene's World2D, framed over
## the world region that can shadow the view (view rect + hull of visible shadow-casting
## light positions - every march segment lies inside that hull). Godot generates its SDF
## natively there; an encode quad copies it into the viewport's color target as signed
## distance in world px, and receiver marches sample that instead of the screen SDF, so
## shadows are zoom- and pan-invariant.

const WORLD_SDF_SIZE := 2048
const WORLD_SDF_NODE := "LitWorldSdf"
# Also warmed by the shader precompiler (against a matching HDR target).
const ENCODE_SHADER_PATH := "res://addons/lit/shaders/sdf/lit_world_sdf_encode.gdshader"
# Frames of unconditional rendering after (re)creation; a lone UPDATE_ONCE on a fresh
# viewport races pipeline readiness and bakes a black SDF.
const WORLD_SDF_WARMUP := 30

var _wsdf_vp: SubViewport
var _wsdf_mat: ShaderMaterial
var _wsdf_xform := Transform2D()
var _wsdf_mult := 1.0
var _wsdf_texel := 0.0
var _wsdf_origin_w := Vector2.ZERO
var _wsdf_warmup := WORLD_SDF_WARMUP
var _wsdf_basis_last := Vector4.INF
var _wsdf_origin_last := Vector2.INF
var _wsdf_tex_published := false
var _wsdf_occ: Array = []        # [node, xform, visible, is_occluder, res, sdf_col, poly hash]
var _wsdf_occ_dirty := true
var _wsdf_occ_root: Node = null
var _wsdf_rd_init := 0           # 0 untried, 1 pending, 2 ready, -1 unavailable
var _wsdf_pack_age := 0
var _wsdf_pack_tex: Texture2DRD
var _wsdf_rd_tex := RID()
var _wsdf_rd_shader := RID()
var _wsdf_rd_pipe := RID()
var _wsdf_rd_sampler := RID()
var _wsdf_rd_set := RID()


func mark_content_dirty() -> void:
	_wsdf_occ_dirty = true


## Create (or re-find after a script reload) the world-SDF SubViewport under `host`.
func _ensure_world_sdf(host: Node, viewport: Viewport) -> bool:
	if _wsdf_vp != null and is_instance_valid(_wsdf_vp):
		return true
	var found := host.get_node_or_null(WORLD_SDF_NODE) as SubViewport
	if found != null:
		_wsdf_vp = found
		_wsdf_mat = found.get_child(0).get_child(0).material as ShaderMaterial
		_wsdf_warmup = WORLD_SDF_WARMUP
		_wsdf_tex_published = false
		return true
	var vp := SubViewport.new()
	vp.name = WORLD_SDF_NODE
	vp.size = Vector2i(WORLD_SDF_SIZE, WORLD_SDF_SIZE)
	vp.world_2d = viewport.world_2d
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.use_hdr_2d = true
	vp.disable_3d = true
	# Occluders still rasterize into the SDF under a restrictive cull mask, so the
	# viewport draws nothing but the encode quad.
	vp.canvas_cull_mask = 1 << 19
	var layer := CanvasLayer.new()
	var rect := ColorRect.new()
	rect.size = Vector2(WORLD_SDF_SIZE, WORLD_SDF_SIZE)
	rect.visibility_layer = 1 << 19
	var mat := ShaderMaterial.new()
	mat.shader = load(ENCODE_SHADER_PATH)
	rect.material = mat
	layer.add_child(rect)
	vp.add_child(layer)
	host.add_child(vp)
	RenderingServer.viewport_set_sdf_oversize_and_scale(vp.get_viewport_rid(),
			RenderingServer.VIEWPORT_SDF_OVERSIZE_100_PERCENT,
			RenderingServer.VIEWPORT_SDF_SCALE_100_PERCENT)
	_wsdf_vp = vp
	_wsdf_mat = mat
	_wsdf_warmup = WORLD_SDF_WARMUP
	_wsdf_tex_published = false
	return true

## Frame the world-SDF viewport over everything that can shadow the view this frame
## (view rect + shadow-casting light positions; directionals extend the rect one view
## diagonal toward the light) and publish the sampling globals. The viewport re-renders
## only when its content or framing changed: on the world-anchored grid an unchanged
## framing re-renders to identical texels, so skipping those renders is invisible.
func update(host: Node, viewport: Viewport, visible: Array,
		canvas_xform: Transform2D, world_rect: Rect2, occ_root: Node) -> void:
	if not _ensure_world_sdf(host, viewport):
		return
	var dirty := false
	if _wsdf_vp.world_2d != viewport.world_2d:
		_wsdf_vp.world_2d = viewport.world_2d
		dirty = true

	var rect := world_rect
	var diag := world_rect.size.length()
	for light in visible:
		if not light.shadow_enabled:
			continue
		if light is LitDirectionalLight2D:
			# Extend by the light's effective world-px shadow cap, so the window always
			# contains its marches at any zoom (a view-derived extension would shrink
			# the world coverage when zoomed in, truncating shadows on screen).
			var reach: float = maxf(light.shadow_reach, 0.0) \
					* clampf(light.shadow_length, 0.0, 1.0)
			var toward := -Vector2.from_angle(light.global_rotation) * reach
			rect = rect.expand(world_rect.position + toward).expand(world_rect.end + toward)
		else:
			rect = rect.expand(light.global_position)
	rect = rect.grow(8.0)

	# Texel from the view, not the hull: sized to cover the worst-case directional hull
	# at any angle plus slack, so hull motion neither rescales the grid nor slides the
	# window every frame. The pow2 multiplier covers hulls stretched further by distant
	# lights, with hysteresis against flip-flop.
	var floor_texel := ((maxf(world_rect.size.x, world_rect.size.y) + diag) * 1.06 + 32.0) \
			/ float(WORLD_SDF_SIZE)
	var needed := maxf(rect.size.x, rect.size.y)
	var cap := float(WORLD_SDF_SIZE - 8)
	while needed > floor_texel * _wsdf_mult * cap:
		_wsdf_mult *= 2.0
	while _wsdf_mult > 1.0 and needed < floor_texel * _wsdf_mult * cap * 0.45:
		_wsdf_mult *= 0.5
	var texel := floor_texel * _wsdf_mult

	# Reframe only when the texel changed (zoom, escalation) or the hull escaped the
	# framed window. The world-anchored origin snaps to texel multiples, so the window
	# slides in whole texels and a reframe never re-discretizes an outline.
	var cov := texel * float(WORLD_SDF_SIZE)
	var framed := Rect2(_wsdf_origin_w, Vector2(cov, cov))
	if not is_equal_approx(texel, _wsdf_texel) or not framed.grow(-4.0 * texel).encloses(rect):
		_wsdf_texel = texel
		_wsdf_origin_w = ((rect.get_center() - Vector2(cov, cov) * 0.5) / texel).floor() * texel
		dirty = true

	var s := 1.0 / texel
	var xf := Transform2D(Vector2(s, 0.0), Vector2(0.0, s), -_wsdf_origin_w * s)
	if xf != _wsdf_xform:
		_wsdf_vp.canvas_transform = xf
		_wsdf_mat.set_shader_parameter("screen_to_world", texel)
		_wsdf_xform = xf

	if _poll_wsdf_content(occ_root):
		dirty = true

	if _wsdf_warmup > 0:
		_wsdf_warmup -= 1
		if _wsdf_vp.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
			_wsdf_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif dirty:
		_wsdf_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif _wsdf_vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		# The scene-side property lags the server's ONCE -> DISABLED flip; re-park both.
		_wsdf_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	# Fold screen px -> world -> world-SDF UV into one affine map for the shader;
	# publishes are gated on change.
	var to_uv := Transform2D(
			Vector2(s / float(WORLD_SDF_SIZE), 0.0),
			Vector2(0.0, s / float(WORLD_SDF_SIZE)),
			-_wsdf_origin_w * s / float(WORLD_SDF_SIZE))
	var m := to_uv * canvas_xform.affine_inverse()
	var basis := Vector4(m.x.x, m.x.y, m.y.x, m.y.y)
	if basis != _wsdf_basis_last:
		_wsdf_basis_last = basis
		RenderingServer.global_shader_parameter_set("lit_wsdf_basis", basis)
	if m.origin != _wsdf_origin_last:
		_wsdf_origin_last = m.origin
		RenderingServer.global_shader_parameter_set("lit_wsdf_origin", m.origin)
	# Source binding: the raw RT while content settles (fresh same-frame for movers);
	# two clean frames later, a packed R16F copy of it - same f16 values, a quarter of
	# the per-sample bandwidth. Without a RenderingDevice the raw RT stays bound.
	if _wsdf_rd_init == 0:
		_wsdf_rd_setup()
	elif _wsdf_rd_init == 2 and _wsdf_pack_tex == null:
		_wsdf_pack_tex = Texture2DRD.new()
		_wsdf_pack_tex.texture_rd_rid = _wsdf_rd_tex
		if not _wsdf_vp.has_meta("lit_wsdf_pack"):
			_wsdf_vp.set_meta("lit_wsdf_pack",
					[_wsdf_rd_tex, _wsdf_rd_shader, _wsdf_rd_pipe, _wsdf_rd_sampler, _wsdf_rd_set])
		if not _wsdf_vp.tree_exiting.is_connected(_wsdf_rd_free):
			_wsdf_vp.tree_exiting.connect(_wsdf_rd_free)
	if _wsdf_warmup > 0 or dirty or _wsdf_rd_init != 2 or _wsdf_pack_tex == null:
		_wsdf_pack_age = 0
		if not _wsdf_tex_published:
			_wsdf_tex_published = true
			RenderingServer.global_shader_parameter_set("lit_world_sdf", _wsdf_vp.get_texture())
	else:
		_wsdf_pack_age = mini(_wsdf_pack_age + 1, 3)
		if _wsdf_pack_age == 1:
			RenderingServer.call_on_render_thread(_wsdf_pack_copy)
		elif _wsdf_pack_age == 2 and _wsdf_tex_published:
			_wsdf_tex_published = false
			RenderingServer.global_shader_parameter_set("lit_world_sdf", _wsdf_pack_tex)

## Create (or recover from viewport metadata after a script reload) the R16F pack
## texture and compute pipeline; RD resource creation runs on the render thread.
func _wsdf_rd_setup() -> void:
	if RenderingServer.get_rendering_device() == null:
		_wsdf_rd_init = -1
		return
	if _wsdf_vp.has_meta("lit_wsdf_pack"):
		var ids: Array = _wsdf_vp.get_meta("lit_wsdf_pack")
		_wsdf_rd_tex = ids[0]
		_wsdf_rd_shader = ids[1]
		_wsdf_rd_pipe = ids[2]
		_wsdf_rd_sampler = ids[3]
		_wsdf_rd_set = ids[4]
		_wsdf_pack_tex = Texture2DRD.new()
		_wsdf_pack_tex.texture_rd_rid = _wsdf_rd_tex
		if not _wsdf_vp.tree_exiting.is_connected(_wsdf_rd_free):
			_wsdf_vp.tree_exiting.connect(_wsdf_rd_free)
		_wsdf_rd_init = 2
		return
	var sf: RDShaderFile = load("res://addons/lit/shaders/sdf/lit_world_sdf_pack.glsl")
	var spirv: RDShaderSPIRV = sf.get_spirv() if sf != null else null
	if spirv == null or spirv.compile_error_compute != "":
		_wsdf_rd_init = -1
		return
	_wsdf_rd_init = 1
	RenderingServer.call_on_render_thread(_wsdf_rd_create.bind(spirv,
			_wsdf_vp.get_texture().get_rid()))

func _wsdf_rd_create(spirv: RDShaderSPIRV, vp_tex: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	_wsdf_rd_shader = rd.shader_create_from_spirv(spirv)
	if not _wsdf_rd_shader.is_valid():
		_wsdf_rd_init = -1
		return
	_wsdf_rd_pipe = rd.compute_pipeline_create(_wsdf_rd_shader)
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	tf.width = WORLD_SDF_SIZE
	tf.height = WORLD_SDF_SIZE
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_wsdf_rd_tex = rd.texture_create(tf, RDTextureView.new())
	_wsdf_rd_sampler = rd.sampler_create(RDSamplerState.new())
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u0.binding = 0
	u0.add_id(_wsdf_rd_sampler)
	u0.add_id(RenderingServer.texture_get_rd_texture(vp_tex))
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(_wsdf_rd_tex)
	_wsdf_rd_set = rd.uniform_set_create([u0, u1], _wsdf_rd_shader, 0)
	_wsdf_rd_init = 2

## Free the pack pipeline's RD resources when their SubViewport leaves the tree (game
## quit, plugin disable) - the moment they can no longer be recovered from its metadata.
func _wsdf_rd_free() -> void:
	if _wsdf_rd_init != 2:
		return
	_wsdf_rd_init = 0
	if _wsdf_pack_tex != null:
		_wsdf_pack_tex.texture_rd_rid = RID()
	_wsdf_pack_tex = null
	_wsdf_tex_published = false
	if is_instance_valid(_wsdf_vp) and _wsdf_vp.has_meta("lit_wsdf_pack"):
		_wsdf_vp.remove_meta("lit_wsdf_pack")
	RenderingServer.call_on_render_thread(_wsdf_rd_do_free.bind(
			[_wsdf_rd_set, _wsdf_rd_pipe, _wsdf_rd_shader, _wsdf_rd_sampler, _wsdf_rd_tex]))
	_wsdf_rd_set = RID()
	_wsdf_rd_pipe = RID()
	_wsdf_rd_shader = RID()
	_wsdf_rd_sampler = RID()
	_wsdf_rd_tex = RID()

func _wsdf_rd_do_free(rids: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)

func _wsdf_pack_copy() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not _wsdf_rd_pipe.is_valid() or not _wsdf_rd_set.is_valid():
		return
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _wsdf_rd_pipe)
	rd.compute_list_bind_uniform_set(cl, _wsdf_rd_set, 0)
	rd.compute_list_dispatch(cl, WORLD_SDF_SIZE >> 3, WORLD_SDF_SIZE >> 3, 1)
	rd.compute_list_end()

## True when SDF content changed: an occluder or tilemap moved, toggled visibility or
## SDF flags, swapped its polygon resource, or the cached list went stale.
func _poll_wsdf_content(root: Node) -> bool:
	if _wsdf_occ_dirty or root != _wsdf_occ_root:
		_wsdf_occ_root = root
		_wsdf_occ_dirty = false
		_wsdf_occ.clear()
		if root != null:
			for occ in root.find_children("*", "LightOccluder2D", true, false):
				_wsdf_occ.append([occ, occ.global_transform, occ.is_visible_in_tree(),
						true, occ.occluder, occ.sdf_collision, _wsdf_poly_hash(occ)])
			for layer in root.find_children("*", "TileMapLayer", true, false):
				_wsdf_occ.append([layer, layer.global_transform, layer.is_visible_in_tree(),
						false, null, false, 0])
		return true
	var changed := false
	for entry in _wsdf_occ:
		var node = entry[0]
		if not is_instance_valid(node) or not node.is_inside_tree():
			_wsdf_occ_dirty = true
			return true
		var vis: bool = node.is_visible_in_tree()
		if node.global_transform != entry[1] or vis != entry[2]:
			entry[1] = node.global_transform
			entry[2] = vis
			changed = true
		if entry[3]:
			var h := _wsdf_poly_hash(node)
			if node.occluder != entry[4] or node.sdf_collision != entry[5] or h != entry[6]:
				entry[4] = node.occluder
				entry[5] = node.sdf_collision
				entry[6] = h
				changed = true
	return changed

## Editor-only polygon content probe; point edits keep the same resource instance.
func _wsdf_poly_hash(occ) -> int:
	if not Engine.is_editor_hint() or occ.occluder == null:
		return 0
	return hash(occ.occluder.polygon)
