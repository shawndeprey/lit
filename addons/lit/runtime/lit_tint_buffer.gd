@tool
@icon("res://addons/lit/icons/lit_point_light_2d.svg")
extends SubViewport
class_name LitTintBuffer

## Screen-space tint buffer for the stained-glass effect.
##
## This is the keystone of "light tinted by translucent objects". The receiver shader and
## the beam post-pass both need to ask, for any point on screen, "what colour does light
## take on passing through here, and how strongly?". Nothing in the base Lit pipeline holds
## that: receivers shade per-fragment looking outward at unchanging lights, and shadows
## march a material-blind SDF. So we build a dedicated buffer.
##
## How it works: every translucent object that opts in (via LitTintModifier) mirrors its
## sprite into THIS SubViewport with lit_tint_writer.gdshader. The viewport is sized and
## framed to match the main view, so a writer lands at the same screen location as the
## object it mirrors. The viewport's texture is published as the GLOBAL shader uniform
## `lit_tint_buffer`, which the receiver and beam pass sample.
##
## Buffer convention (PREMULTIPLIED ADDITIVE; see lit_tint_writer.gdshader): each writer
## outputs rgb = tint*density, a = density, and stamps with ADDITIVE blend. The buffer is
## cleared to (0,0,0,0) every frame, so un-stamped texels are zero (readers gate on a>0 and
## skip them) and overlapping stamps SUM. A reader reconstructs the per-texel tint as rgb/a
## (a density-weighted average of every pane covering that texel) and reads density from a.
## This makes overlapping glass composite — red over blue reads purple in the overlap — and
## red×blue along a light's path still composites because the ray multiplies the resolved
## tints of the DIFFERENT texels it crosses.
##
## Placement: add ONE LitTintBuffer to the scene (an autoload-style singleton-per-scene).
## It tracks the active Camera2D / editor view each frame so its contents register with the
## main viewport. Writers register/deregister themselves through the static API below.

const TINT_WRITER_SHADER := preload("res://addons/lit/shaders/lit_tint_writer.gdshader")
const LitTintBlurScript := preload("res://addons/lit/runtime/lit_tint_blur.gd")

# --- Beam blur ---------------------------------------------------------------
#
# The beam post-pass marches a sparse set of samples toward each light; a small stamp (a gem
# at scale 1.0) covers only a few texels and the march steps over it, echoing its outline at
# intervals ("stamped gems with gaps") instead of a continuous shaft. We dilate a COPY of the
# buffer with a separable Gaussian and publish it as `lit_tint_buffer_blurred`; the beam pass
# samples that softened copy while the receiver keeps sampling the SHARP buffer for surface
# tint. These knobs forward to the blur node and stay live in the inspector.

## Soften the buffer the volumetric beams sample, so small translucent objects cast smooth
## shafts instead of repeated stamps. Off = beams sample the raw (sharp) buffer.
@export var beam_blur_enabled: bool = true:
	set(value):
		beam_blur_enabled = value
		_apply_blur_params()

## Gaussian kernel reach in taps per side. Larger = wider, smoother shafts, more texture
## fetches. The effective pixel radius is roughly blur_radius × blur_spread.
@export_range(1, 16) var beam_blur_radius: int = 6:
	set(value):
		beam_blur_radius = value
		_apply_blur_params()

## Spacing between blur taps in texels. The main "how far a gem bleeds into its shaft" knob;
## raise it if gaps persist at very small gem scales, lower it if shafts look too washed out.
@export_range(0.5, 8.0, 0.1) var beam_blur_spread: float = 2.0:
	set(value):
		beam_blur_spread = value
		_apply_blur_params()

# Additive clear: zero tint, zero density. Premultiplied stamps add onto this, and readers
# treat any texel with a==0 as clear. (transparent_bg already clears the SubViewport to
# (0,0,0,0); this constant documents the contract and is used if an explicit clear is wired.)
const CLEAR_COLOR := Color(0.0, 0.0, 0.0, 0.0)

# The single active buffer for the current scene. Writers find it through here instead of
# a node path, so authoring a translucent object needs no wiring to this node.
static var _active: LitTintBuffer = null

# Root inside the SubViewport that every writer-sprite parents under, so we can clear and
# rebuild the mirror set without touching the viewport's own bookkeeping.
var _writer_root: Node2D

# Registered modifiers -> their mirror sprite inside the viewport. Kept in sync each frame
# so a modifier that moves/changes drags its mirror with it.
var _mirrors: Dictionary = {}

# Two-pass blur that produces lit_tint_buffer_blurred for the beam pass. Built lazily once the
# buffer is in the tree (a SubViewport can host the blur node as a child for tree lifecycle).
var _blur: LitTintBlur = null


func _enter_tree() -> void:
	_active = self

	# A SubViewport renders its own children to an offscreen texture. We want a persistent,
	# transparent buffer we clear ourselves each frame, sized to the window.
	transparent_bg = true
	render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Match the main window so screen-UV lines up 1:1 between this buffer and the receiver.
	size = _main_view_size()

	if _writer_root == null:
		_writer_root = Node2D.new()
		_writer_root.name = "TintWriters"
		add_child(_writer_root, false, Node.INTERNAL_MODE_BACK)

	# Build the beam-blur node as a child so it shares this buffer's tree lifecycle. It owns
	# two offscreen passes that dilate a copy of this buffer into lit_tint_buffer_blurred.
	if _blur == null:
		_blur = LitTintBlurScript.new()
		_blur.name = "TintBeamBlur"
		add_child(_blur, false, Node.INTERNAL_MODE_BACK)
		_apply_blur_params()


func _exit_tree() -> void:
	if _active == self:
		_active = null


func _process(_delta: float) -> void:
	# Keep the buffer the size of the main view and framed by the same camera, so a writer
	# stamped here overlaps the object it mirrors in the receiver's SCREEN_UV.
	var vp_size := _main_view_size()
	if size != vp_size:
		size = vp_size

	# Mirror the active canvas transform so the offscreen render matches on-screen framing.
	# A writer's own LOCAL transform (its world transform) is then applied on top of this,
	# placing it at the same screen pixel as the object it mirrors.
	var xform := _main_canvas_transform()
	if _writer_root != null:
		_writer_root.transform = xform

	# Poll the modifier group each frame rather than relying on register() having run in the
	# right tree order. This makes the buffer immune to scene-entry ordering: any
	# LitTintModifier present gets a mirror, any that vanished loses its mirror. The static
	# register/deregister API still works as an optimisation, but this guarantees correctness.
	var live: Dictionary = {}
	for mod in get_tree().get_nodes_in_group("lit_tint_modifiers"):
		if not is_instance_valid(mod) or not is_instance_valid(mod.source):
			continue
		live[mod] = true
		if not _mirrors.has(mod):
			_add_mirror(mod)
		_sync_mirror(mod, _mirrors[mod])

	# Drop mirrors whose modifier left the tree.
	var dead: Array = []
	for mod in _mirrors:
		if not live.has(mod):
			dead.append(mod)
	for d in dead:
		_drop_mirror(d)

	# Publish the buffer as a global so the receiver shader and beam pass can sample it
	# without a per-material assignment.
	RenderingServer.global_shader_parameter_set("lit_tint_buffer", get_texture())

	# Drive the beam blur from the raw buffer. When enabled it publishes the softened copy as
	# lit_tint_buffer_blurred; when disabled we point that global straight at the sharp buffer
	# so the beam pass (which always samples the blurred global) still works — it just gets the
	# unsoftened image, reproducing the old behaviour.
	if beam_blur_enabled and _blur != null:
		_blur.update(get_texture(), size)
	else:
		RenderingServer.global_shader_parameter_set("lit_tint_buffer_blurred", get_texture())


## Forward the inspector blur knobs onto the blur node. Safe before _blur exists (no-op).
func _apply_blur_params() -> void:
	if _blur == null:
		return
	_blur.radius = beam_blur_radius
	_blur.spread = beam_blur_spread


# =====================================================================================
# Static writer API — LitTintModifier calls these in its _enter_tree / _exit_tree.
# =====================================================================================

## Register a modifier so its source sprite is mirrored into the buffer. Safe to call
## before the buffer exists; the modifier retries via has_active().
static func register(modifier: Node) -> void:
	if _active == null:
		return
	_active._add_mirror(modifier)


static func deregister(modifier: Node) -> void:
	if _active == null:
		return
	_active._drop_mirror(modifier)


static func has_active() -> bool:
	return _active != null


# =====================================================================================
# Internal mirror management
# =====================================================================================

func _add_mirror(modifier: Node) -> void:
	if _mirrors.has(modifier):
		return
	var mirror := Sprite2D.new()
	var mat := ShaderMaterial.new()
	mat.shader = TINT_WRITER_SHADER
	mirror.material = mat
	_writer_root.add_child(mirror)
	_mirrors[modifier] = mirror
	_sync_mirror(modifier, mirror)


func _drop_mirror(modifier: Node) -> void:
	if not _mirrors.has(modifier):
		return
	var mirror: Sprite2D = _mirrors[modifier]
	if is_instance_valid(mirror):
		mirror.queue_free()
	_mirrors.erase(modifier)


## Copy the source sprite's texture, transform, and frame into the mirror, and push the
## modifier's tint parameters onto the mirror's writer material. Called every frame so the
## mirror tracks an animated / moving source.
func _sync_mirror(modifier: Node, mirror: Sprite2D) -> void:
	var src = modifier.source
	if not is_instance_valid(src) or not is_instance_valid(mirror):
		return

	# The mirror is a child of _writer_root, which carries the main canvas (camera) transform.
	# Setting the mirror's LOCAL transform to the source's WORLD transform makes its final
	# position canvas_xform * source_world — the source's screen pixel — which is where the
	# receiver samples it in SCREEN_UV. (Setting global_transform here would double-correct
	# against the root's transform and push the writer off-screen.)
	mirror.transform = src.global_transform
	mirror.visible = src.visible and modifier.enabled

	var mat: ShaderMaterial = mirror.material

	# Pull the art off the source if it's a Sprite2D-like node; fall back to the modifier's
	# explicit override texture.
	var tex: Texture2D = modifier.source_texture
	if tex == null and src is Sprite2D:
		tex = src.texture

	# CRITICAL: set the mirror's OWN texture, not just the shader uniform. A Sprite2D with no
	# texture has zero size and never rasterizes, so its fragment shader never runs and nothing
	# is stamped into the buffer. Setting texture gives the sprite geometry; the writer shader
	# then reads it as TEXTURE/UV. Also mirror the source's region/frame so the stamp matches.
	mirror.texture = tex
	if src is Sprite2D:
		var ssrc := src as Sprite2D
		mirror.region_enabled = ssrc.region_enabled
		mirror.region_rect = ssrc.region_rect
		mirror.hframes = ssrc.hframes
		mirror.vframes = ssrc.vframes
		mirror.frame = ssrc.frame
		mirror.centered = ssrc.centered
		mirror.offset = ssrc.offset

	mat.set_shader_parameter("source_tex", tex)
	# resolved_* honour the modifier's auto_from_source mode: a gem feeds its own
	# transmission_color × modulate and its transmission_map with no manual copying.
	mat.set_shader_parameter("tint_color", modifier.resolved_tint_color())
	mat.set_shader_parameter("transmission_map", modifier.resolved_transmission_map())
	mat.set_shader_parameter("density", modifier.density)


# =====================================================================================
# View tracking — keep the buffer matched to the main viewport's size and framing.
# =====================================================================================

func _main_view_size() -> Vector2i:
	# Size the buffer to match the space SCREEN_UV is normalized against in the receiver:
	# the parent viewport's VISIBLE RECT, not the OS window. With content-scale / stretch
	# modes these differ (e.g. a 2560x1377 window rendering a 1080x1920 viewport), and a
	# mismatch maps the gem's screen position to the wrong buffer UV — the receiver then
	# samples empty texels and no tint appears. Using the visible rect keeps them 1:1.
	var parent_vp := get_parent_viewport()
	if parent_vp != null:
		var s: Vector2 = parent_vp.get_visible_rect().size
		if s.x >= 1.0 and s.y >= 1.0:
			return Vector2i(int(round(s.x)), int(round(s.y)))
	var win := get_window()
	if win != null:
		return win.size
	return Vector2i(1152, 648)


func _main_canvas_transform() -> Transform2D:
	# Mirror whatever transform the main viewport applies to its canvas (camera at runtime,
	# pan/zoom in the editor), so a world-space writer maps to the same screen pixel as in
	# the main view. Parent viewport is the one this SubViewport hangs under.
	var parent_vp := get_parent_viewport()
	if parent_vp != null:
		return parent_vp.get_global_canvas_transform() * parent_vp.get_canvas_transform()
	return Transform2D.IDENTITY


func get_parent_viewport() -> Viewport:
	# The authoritative main viewport is the scene tree root (the Window). Its visible rect is
	# the render size SCREEN_UV normalizes against, and its canvas transform carries the
	# active Camera2D. Walking the parent chain can stop at this SubViewport's own ancestors,
	# so go straight to the root, falling back to a parent-chain walk only if unavailable.
	if get_tree() != null and get_tree().root != null:
		return get_tree().root
	var n := get_parent()
	while n != null:
		if n is Viewport and not (n is SubViewport):
			return n
		n = n.get_parent()
	return get_window()
