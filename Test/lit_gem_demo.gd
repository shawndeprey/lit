extends Node2D

## Gemstone PBR showcase for Lit, with translucency and colored light-through-gem casts.
##
## Gems are authored in the scene (child LitSprite2D nodes under "Gems"); lights are
## authored under "Lights". This script only does runtime work:
##   - forces the PBR lighting model on,
##   - orbits the authored lights so highlights and transmission slide across the gems,
##   - drives the receiver's translucency (the _t transmission map + strength), and
##   - builds the "stained-glass" tint buffer that lets a gem cast a colored glow of the
##     light shining through it onto the floor and other gems.
##
## The tint buffer is a screen-sized SubViewport in which each gem is redrawn flat in its
## body color, masked by its transmission map, so the buffer holds "what color does this
## gem tint light to, and how much." The modified lit_receiver shader samples it during
## its shadow march: where a fragment is shadowed by a gem, the blocked light is recolored
## by that gem instead of going black. Published via the lit_tint_buffer global.

# Mirrors LitManager.LightingModel; the gem look only makes sense in PBR.
const LIT_MODEL_PBR := 1

const GEM_TRANSMISSION_PATH := "res://Test/Gemstone_00_t.png"

@export_group("Wiring")
## Parent whose LitSprite2D children are the gems. Defaults to a sibling "Gems".
@export var gems_root: Node2D
## Parent whose Lit light children get orbited. Defaults to a sibling "Lights".
@export var lights_root: Node2D

@export_group("Motion")
@export var light_speed: float = 1.0
## Base spin rate (radians/sec). Each gem gets a randomised multiple of this, and some
## spin the other way, so they don't all turn in lockstep.
@export var gem_spin: float = 0.5
## How far each gem drifts from its authored home position, in pixels. The gems bob around
## their home on a slow lissajous so they slide over and under each other for transparency
## testing, without wandering off.
@export var gem_drift: float = 34.0
## Speed of that drift bob.
@export var gem_drift_speed: float = 0.7
@export var force_pbr: bool = true

@export_group("Translucency")
## How strongly light bleeds through each gem. Pushed to every gem's receiver material.
@export_range(0.0, 4.0) var transmission_strength: float = 1.6
## Softness of the through-glow past the terminator (0 hard, 1 very soft).
@export_range(0.0, 1.0) var transmission_wrap: float = 0.6
## Master switch for the colored light-through-gem cast (the stained-glass buffer).
@export var colored_casts: bool = true
## Resolution scale of the stained-glass tint buffer. Below 1.0 the colored cast edges
## pick up a natural softness (transmitted light shouldn't be pixel-sharp even where the
## occlusion edge is) and the per-frame gem re-draw costs a fraction of the fill. The
## receiver samples the buffer with filter_linear, so the downscale reads as blur, not
## blocks. 0.5 is a good default; 1.0 restores the old full-res buffer.
@export_range(0.25, 1.0) var tint_buffer_scale: float = 0.5
## Strength of the additive colored casts the gems throw onto the wall (the wide colored
## wash around the cluster). 0 = off. Pushed to the lit_cast_strength global. The casts are
## gated to land on the wall (not the gems) and soft-knee-ceilinged only at the extreme
## peak, so this can be strong without the white-out the ungated version had at the centre.
@export_range(0.0, 4.0) var cast_strength: float = 1.6
## How far those colored pools spread from each gem, in screen-UV units.
@export_range(0.0, 0.3) var cast_radius: float = 0.07

@export_group("Shadows")
## Auto-generate a LightOccluder2D (with sdf_collision on) under every gem, traced from
## the sprite's alpha. The receiver's shadow march runs against Godot's screen-space 2D
## SDF, and that SDF is built ONLY from LightOccluder2D nodes -- without these the gems
## are invisible to the march, no fragment ever registers as shadowed, and the colored
## stained-glass cast (which lives inside the shadowed branch) never renders at all.
@export var generate_occluders: bool = true
## Polygon simplification for the traced occluders, in texels. Higher = fewer verts,
## chunkier silhouette; the SDF blurs sub-texel detail anyway so a few px is free.
@export_range(0.5, 8.0) var occluder_epsilon: float = 2.0

@export_group("Key & Fill Lighting")
## How many lights get shadows (and therefore stained-glass casts): spots are preferred
## as keys, then points, then directionals. The REST become shadowless fill. With every
## light casting, any fragment tinted by one light sat in plain black shadow from three
## others and the color was buried in murk; a key/fill split gives one or two readable
## colored casts on a visibly lit wall. Set to 99 for the old everything-casts behaviour.
@export_range(0, 16) var max_shadow_lights: int = 2
## Penumbra hardness pushed onto the key lights, overriding the authored 0.0 (which maps
## to the softest march constant and smears every cast into gloom). Caustic casts read
## best with a defined gem-shaped edge; 0.4-0.7 is the sweet spot.
@export_range(0.0, 1.0) var key_shadow_hardness: float = 0.55

@export_group("Wall Casts")
## Root whose receiver materials get the cast look below. Defaults to sibling "Background".
@export var walls_root: Node
## Fraction of blocked light that survives through a gem onto the wall. The receiver
## default (0.35) reads as faintly tinted darkness; ~0.55 reads as glowing stained glass.
## Pushed onto every receiver material under walls_root (the WALL draws the colored
## shadow, not the gem, so this must land on the wall materials).
@export_range(0.0, 1.0) var wall_transmittance: float = 0.55
## Pixel distance over which a colored pool fades along its streak, like a real caustic
## (brightest just past the gem). 0 = constant brightness along the whole streak.
@export var cast_falloff_px: float = 700.0
## Amplitude of the slow watery shimmer on the colored casts. 0 = static.
@export_range(0.0, 1.0) var cast_shimmer: float = 0.25
## Effective light radius in screen pixels for area-light soft shadows. Shadows stay
## crisp at contact and fan out with distance from the gem -- proper penumbras instead of
## a uniformly blurred silhouette. 0 = single hard march (cheapest). Cost scales with
## softness_taps per shadowed key light.
@export_range(0.0, 128.0) var shadow_softness_px: float = 28.0
## Marches averaged per fragment for the area penumbra. 3 is smooth; 2 is cheaper and
## slightly grainier (the per-fragment jitter hides most of it).
@export_range(1, 4) var shadow_softness_taps: int = 3

@export_group("Ambient")
## Override the scene's LitCanvasModulate so shadowed wall detail stays readable instead
## of collapsing to black holes. Keeps the authored blue bias, just lifts the floor.
@export var override_ambient: bool = true
@export var ambient_color: Color = Color(0.05, 0.05, 0.08)

@export_group("Glass Layering")
## Interleave a BackBufferCopy before each gem so every gem refracts the gems already
## drawn behind it -- this is what lets you see gems THROUGH other gems with their colors
## multiplying like stacked stained glass. Costs one framebuffer copy per gem, so it's
## the demo's most expensive setting; turn off to fall back to gems refracting only the
## background (each other invisible in overlaps).
@export var glass_layering: bool = true

var _area_center := Vector2(576, 324)
var _area_half := Vector2(540, 300)
var _clock := 0.0

var _transmission_tex: Texture2D

var _gems: Array[Node] = []
# Per-gem motion data, parallel to _gems:
# { node, home, spin, phase_x, phase_y, freq_x, freq_y }
var _gem_motion: Array = []
# each: { node, center, rx, ry, speed, phase, is_dir, is_spot, dir_speed }
var _lights: Array = []

# --- stained-glass tint buffer ---
var _tint_viewport: SubViewport
var _tint_root: Node2D
var _tint_proxies: Array[Sprite2D] = []   # one flat tinted copy per gem


func _ready() -> void:
	if force_pbr:
		RenderingServer.global_shader_parameter_set("lit_lighting_model", LIT_MODEL_PBR)

	if gems_root == null:
		gems_root = get_node_or_null("../Gems")
	if lights_root == null:
		lights_root = get_node_or_null("../Lights")

	_transmission_tex = load(GEM_TRANSMISSION_PATH) if ResourceLoader.exists(GEM_TRANSMISSION_PATH) else null

	_compute_area()
	_collect_gems()
	if generate_occluders:
		_add_gem_occluders()
	_register_lights()
	_apply_transmission_to_gems()
	_apply_wall_look()
	_apply_ambient()
	if glass_layering:
		_setup_glass_layering()
	if colored_casts:
		_build_tint_buffer()
	else:
		RenderingServer.global_shader_parameter_set("lit_tint_enabled", false)
		RenderingServer.global_shader_parameter_set("lit_cast_strength", 0.0)


func _exit_tree() -> void:
	# Leave the global in a clean state so other scenes aren't tinted by a stale buffer.
	RenderingServer.global_shader_parameter_set("lit_tint_enabled", false)
	RenderingServer.global_shader_parameter_set("lit_cast_strength", 0.0)


func _compute_area() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam:
		_area_center = cam.get_screen_center_position()
		_area_half = get_viewport_rect().size * 0.5 / cam.zoom
	else:
		_area_center = get_viewport_rect().size * 0.5
		_area_half = get_viewport_rect().size * 0.5
	_area_half *= 0.85


func _collect_gems() -> void:
	_gems.clear()
	_gem_motion.clear()
	if gems_root == null:
		return
	for c in gems_root.get_children():
		if c is Sprite2D:
			_gems.append(c)
			# Randomised per-gem motion so they turn and drift independently, sliding over
			# and under each other. Home is the authored position; drift bobs around it.
			var dir := 1.0 if randf() > 0.5 else -1.0
			_gem_motion.append({
				"node": c,
				"home": c.position,
				"spin": dir * randf_range(0.5, 1.8),          # multiple of gem_spin, mixed direction
				"phase_x": randf() * TAU,
				"phase_y": randf() * TAU,
				"freq_x": randf_range(0.7, 1.3),               # slightly different x/y rates -> lissajous
				"freq_y": randf_range(0.7, 1.3),
			})


# Trace each gem's alpha into occluder polygons and hang a LightOccluder2D under the
# sprite. This is what makes the gems exist in the screen-space SDF that lit_shadow()
# marches: shadow_enabled on the lights only means "willing to cast", but with no
# LightOccluder2D (sdf_collision = true) in the scene the SDF is empty, every march
# returns fully lit, and the stained-glass shadow branch (gated on s < 0.999) never runs.
#
# The occluder is a child, so it follows the gem's spin/drift/scale for free. Polygons are
# traced once per unique texture and cached, since several gems share the same art.
func _add_gem_occluders() -> void:
	var poly_cache := {}   # Texture2D -> Array[PackedVector2Array], centered on the sprite
	for g in _gems:
		var spr := g as Sprite2D
		# LitSprite2D wraps its art in a CanvasTexture; trace the diffuse slot's alpha.
		var canvas_tex := spr.texture as CanvasTexture
		var tex: Texture2D = canvas_tex.diffuse_texture if canvas_tex else spr.texture
		if tex == null:
			continue
		var polys: Array
		if poly_cache.has(tex):
			polys = poly_cache[tex]
		else:
			var img := tex.get_image()
			if img == null:
				continue
			var bm := BitMap.new()
			bm.create_from_image_alpha(img)
			var raw := bm.opaque_to_polygons(Rect2i(Vector2i.ZERO, img.get_size()), occluder_epsilon)
			# opaque_to_polygons works in texel space with a top-left origin; shift into the
			# sprite's local space (centered sprites put the origin at the texture middle).
			var origin := Vector2(img.get_size()) * 0.5 if spr.centered else Vector2.ZERO
			polys = []
			for poly in raw:
				var pts := PackedVector2Array()
				for p in poly:
					pts.append(p - origin + spr.offset)
				polys.append(pts)
			poly_cache[tex] = polys
		for pts in polys:
			var op := OccluderPolygon2D.new()
			op.polygon = pts
			# The SDF has no facing; disable culling so the silhouette reads from any side.
			op.cull_mode = OccluderPolygon2D.CULL_DISABLED
			var occ := LightOccluder2D.new()
			occ.occluder = op
			occ.sdf_collision = true      # the ONLY thing the receiver's march sees
			occ.occluder_light_mask = 0   # don't interact with Godot's built-in Light2D pass
			occ.name = "GemOccluder"
			spr.add_child(occ)


# Stained-glass layering: insert a BackBufferCopy in front of every gem so that when a gem
# reads hint_screen_texture, the screen already contains the gems drawn before it. Without
# this, all gems sample the same pre-gem snapshot (the bare background) and overlaps show
# only wall-through-glass, never gem-through-glass. With one copy per gem, gem N refracts
# the accumulated result of gems 0..N-1, and because each earlier gem has already tinted
# those pixels by its own color, the tints multiply through the stack -- real stained glass.
#
# We reparent each gem under its own copy node so the draw order is strictly
# copy0 -> gem0 -> copy1 -> gem1 -> ...; child order under Gems is preserved, so the
# authored back-to-front ordering (and thus which gem shows through which) stays editable.
func _setup_glass_layering() -> void:
	if gems_root == null:
		return
	# Snapshot the current gem children in order; we'll wrap each one.
	var gems := []
	for c in gems_root.get_children():
		if c is Sprite2D:
			gems.append(c)
	var order := 0
	for gem in gems:
		var copy := BackBufferCopy.new()
		copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT   # full-screen re-copy
		copy.name = "GlassCopy_%d" % order
		gems_root.add_child(copy)
		# Keep the copy immediately before its gem in the tree so it draws first.
		gems_root.move_child(copy, gem.get_index())
		order += 1


# Push the translucency settings onto every gem's receiver material. Each gem keeps its
# own ShaderMaterial (authored in the scene), so we set the params per-instance and hand
# it the shared transmission map.
func _apply_transmission_to_gems() -> void:
	for g in _gems:
		var spr := g as Sprite2D
		var mat := spr.material as ShaderMaterial
		if mat == null:
			continue
		mat.set_shader_parameter("transmission_strength", transmission_strength)
		mat.set_shader_parameter("transmission_wrap", transmission_wrap)
		if _transmission_tex:
			mat.set_shader_parameter("transmission_map", _transmission_tex)


func _register_lights() -> void:
	_lights.clear()
	if lights_root == null:
		return
	# Key/fill split. The colored "stained-glass shadow" is produced by the receiver's
	# shadow march, which only runs for shadow-casting lights -- but when EVERY light
	# casts, their plain shadows overlap and bury each other's colored casts in black.
	# So we pick a few keys (spots first: a moving cone reads best as the "beam through
	# the gems"; then points; directionals last, since a full-screen directional shadow
	# darkens everything) and demote the rest to shadowless fill that keeps the gems
	# modeled and the wall readable.
	var candidates: Array = []
	for n in lights_root.get_children():
		var is_dir := n is LitDirectionalLight2D
		var is_spot := n is LitSpotLight2D
		var is_point := n is LitPointLight2D
		if not (is_dir or is_spot or is_point):
			continue
		var pref := 0 if is_spot else (1 if is_point else 2)
		candidates.append({ "node": n, "is_dir": is_dir, "is_spot": is_spot, "pref": pref })
	candidates.sort_custom(func(a, b): return a.pref < b.pref)

	for i in candidates.size():
		var c: Dictionary = candidates[i]
		var n = c.node
		var is_key: bool = i < max_shadow_lights
		if "shadow_enabled" in n:
			n.shadow_enabled = is_key
		# The scene authors hardness at 0.0 (softest possible penumbra constant), which
		# smears every cast into gloom; keys get a defined gem-shaped silhouette instead.
		if is_key and "shadow_hardness" in n:
			n.shadow_hardness = key_shadow_hardness
		var center: Vector2 = n.position if not c.is_dir else _area_center
		_lights.append({
			"node": n,
			"center": center,
			"rx": randf_range(_area_half.x * 0.35, _area_half.x * 0.8),
			"ry": randf_range(_area_half.y * 0.35, _area_half.y * 0.8),
			"speed": randf_range(0.2, 0.55) * (1.0 if randf() > 0.5 else -1.0),
			"phase": randf() * TAU,
			"is_dir": c.is_dir,
			"is_spot": c.is_spot,
			"dir_speed": randf_range(0.15, 0.4) * (1.0 if randf() > 0.5 else -1.0),
		})


# Push the cast look onto every receiver material under walls_root. The WALL is the
# receiver that draws the colored shadow (the gem only blocks the light), so the
# transmittance/falloff/shimmer uniforms must land on the wall materials -- and there
# are ~180 wall instances sharing a handful of materials, so we dedupe and set each
# ShaderMaterial once instead of hand-editing scenes.
func _apply_wall_look() -> void:
	if walls_root == null:
		walls_root = get_node_or_null("../Background")
	if walls_root == null:
		return
	var mats := {}
	_collect_receiver_materials(walls_root, mats)
	for mat in mats:
		mat.set_shader_parameter("lit_shadow_transmittance", wall_transmittance)
		mat.set_shader_parameter("tint_cast_falloff", cast_falloff_px)
		mat.set_shader_parameter("tint_shimmer", cast_shimmer)
		mat.set_shader_parameter("shadow_penumbra_px", shadow_softness_px)
		mat.set_shader_parameter("shadow_penumbra_taps", shadow_softness_taps)


func _collect_receiver_materials(node: Node, out: Dictionary) -> void:
	var ci := node as CanvasItem
	if ci and ci.material is ShaderMaterial:
		out[ci.material] = true   # Dictionary as a set: shared materials collected once
	for c in node.get_children():
		_collect_receiver_materials(c, out)


# Lift the ambient floor so shadowed wall detail stays readable instead of collapsing to
# black holes. Set through the LitCanvasModulate node (found via its group) so its color
# setter republishes the lit_ambient_* globals -- writing the globals directly would be
# undone the next time the node re-applies.
func _apply_ambient() -> void:
	if not override_ambient:
		return
	for m in get_tree().get_nodes_in_group("lit_canvas_modulate"):
		if "color" in m:
			m.color = ambient_color


# =====================================================================================
# Stained-glass tint buffer
# =====================================================================================

# Build a screen-sized SubViewport that re-renders each gem flat in its body color,
# masked by the transmission map, on a transparent background. The receiver samples the
# result during its shadow march. We keep one proxy Sprite2D per gem and sync its
# transform to the real gem every frame.
func _build_tint_buffer() -> void:
	_tint_viewport = SubViewport.new()
	# Reduced-resolution buffer: same world coverage (the camera zoom below compensates),
	# fewer texels. Softens the cast edges for free and cuts the per-frame gem fill cost.
	_tint_viewport.size = Vector2i((get_viewport_rect().size * tint_buffer_scale).ceil())
	_tint_viewport.transparent_bg = true
	_tint_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_tint_viewport.disable_3d = true
	add_child(_tint_viewport)

	# A camera in the SubViewport matching the main camera, so gem screen positions line up
	# with the main view (which is what the receiver samples with SCREEN_UV). The zoom is
	# scaled with the buffer so the half-size viewport still frames the SAME world rect --
	# the receiver samples with normalized UVs, so only the framing has to match, not the
	# pixel density.
	var cam := Camera2D.new()
	cam.position = _area_center
	cam.zoom = Vector2(tint_buffer_scale, tint_buffer_scale)
	_tint_viewport.add_child(cam)
	cam.make_current()

	_tint_root = Node2D.new()
	_tint_viewport.add_child(_tint_root)

	# A tiny shader that outputs the gem's modulate color with silhouette coverage in
	# alpha: RGB = body color, A = how much this texel recolors blocked light.
	var tint_shader := Shader.new()
	tint_shader.code = """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D t_map : hint_default_white;
void fragment() {
	float t = texture(t_map, UV).r;
	float a = texture(TEXTURE, UV).a;
	// Coverage must match the gem's SDF occluder -- the FULL alpha silhouette -- because
	// the receiver recolors exactly the region the SDF march darkened. The old version
	// masked coverage by the transmission map, which is sparse facet art, so tint existed
	// only on small bright patches: the shadow march found color only where a sample
	// crossed one of those patches, and each sample fraction projected them as scaled
	// copies about the light -- the cascade of repeated colored facet shapes inside an
	// otherwise black silhouette shadow. Instead the transmission map now SHAPES the
	// coverage (clear areas recolor fully, opaque areas recolor at a floor) without ever
	// punching a hole in it, so the colored cast fills the whole gem shadow.
	float cov = a * mix(0.5, 1.0, t);
	COLOR = vec4(COLOR.rgb, cov);
}
"""
	for g in _gems:
		var spr := g as Sprite2D
		var proxy := Sprite2D.new()
		proxy.texture = spr.texture
		proxy.modulate = spr.modulate              # the gem's random body color
		# Linear even when the gem art draws nearest: this buffer is a light-coverage mask,
		# not visible art, and soft texels here become soft cast edges on the wall.
		proxy.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var pmat := ShaderMaterial.new()
		pmat.shader = tint_shader
		if _transmission_tex:
			pmat.set_shader_parameter("t_map", _transmission_tex)
		proxy.material = pmat
		_tint_root.add_child(proxy)
		_tint_proxies.append(proxy)

	# Publish the buffer to the receiver shader.
	RenderingServer.global_shader_parameter_set("lit_tint_buffer", _tint_viewport.get_texture())
	RenderingServer.global_shader_parameter_set("lit_tint_enabled", true)
	# Drive the additive colored-pool projection.
	RenderingServer.global_shader_parameter_set("lit_cast_strength", cast_strength)
	RenderingServer.global_shader_parameter_set("lit_cast_radius", cast_radius)


func _sync_tint_proxies() -> void:
	if _tint_root == null:
		return
	for i in _gems.size():
		var gem := _gems[i] as Sprite2D
		var proxy := _tint_proxies[i]
		if not (is_instance_valid(gem) and is_instance_valid(proxy)):
			continue
		proxy.global_position = gem.global_position
		proxy.rotation = gem.rotation
		proxy.scale = gem.scale
		proxy.modulate = gem.modulate


func _process(dt: float) -> void:
	_clock += dt
	for d in _lights:
		var n = d.node
		if not is_instance_valid(n):
			continue
		if d.is_dir:
			n.rotation = d.phase + _clock * d.dir_speed * light_speed
		else:
			var t: float = _clock * d.speed * light_speed + d.phase
			var p: Vector2 = d.center + Vector2(cos(t) * d.rx, sin(t) * d.ry)
			n.position = p
			if d.is_spot:
				n.rotation = (_area_center - p).angle()

	# Gems: each spins at its own rate/direction and bobs around its home position on a
	# slow lissajous, so they slide over and under each other (good for testing the glass
	# transparency) while staying in the cluster.
	for m in _gem_motion:
		var g = m.node
		if not is_instance_valid(g):
			continue
		g.rotation += dt * gem_spin * m.spin
		var t := _clock * gem_drift_speed
		var off := Vector2(
			sin(t * m.freq_x + m.phase_x),
			cos(t * m.freq_y + m.phase_y)
		) * gem_drift
		g.position = m.home + off

	if colored_casts:
		_sync_tint_proxies()
