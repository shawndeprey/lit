extends LitSuiteSection

## Shadow exclusion machinery: a sprite never shadows itself (owned occluders cast
## behind it; self_shadow opts back in), light shadow_mask vs occluder_light_mask
## (per-light exclusions on the mask tier, occluders no light matches on the global
## gx tier, with and without runtime SDF culling), receiver shadow_ignore_mask (rx),
## exclude_scene_occluders (owner scoping through a PackedScene instance), y-sorted
## shadow depth, and the activity flags / receiver variants each state publishes.

const AMBIENT := 0.1
const TOL := 0.03
const F := preload("res://addons/lit/runtime/lit_shader_library.gd")

var _props: Node2D
# Every region's lights, switched off once its checks are done (a light or a sun from
# one region must not reach another region's probes) and back on for the final view.
var _region_lights: Array = []


func _region_done(lights: Array) -> void:
	for l in lights:
		l.enabled = false
		_region_lights.append(l)
	await frames(2)


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_props = group("Props")
	label("self-shadow exclusion, then y-sort depth", Vector2(24, 74))
	label("shadow masks: per-light tier (red casts, blue excluded) and the global tier", Vector2(704, 74))
	label("receiver shadow_ignore_mask: top floor ignores mask-2 casters", Vector2(24, 544))
	label("exclude_scene_occluders: a scene's light ignores its own occluder", Vector2(704, 544))
	await _self_exclusion()
	await _mask_tiers()
	await _rx()
	await _scene_exclusion()
	await _ysort()
	for l in _region_lights:
		if is_instance_valid(l):
			l.enabled = true


func _self_exclusion() -> void:
	var case_name := "self_shadow_exclusion"
	var floor_a := floor_receiver(Rect2(20, 90, 660, 430))
	var l := point_light(Vector2(120, 300), 900.0, 0.8, Color.WHITE, 300.0)
	l.falloff = 0.3
	l.shadow_enabled = true
	var wall := box_receiver(Vector2(330, 300), Vector2(160, 120))
	wall.name = "Wall"
	wall.specular_strength = 0.0
	# Wider than the light's source disc, so the umbra behind it never tapers closed.
	occluder(Vector2(-30, 0), Vector2(80, 120), wall)
	var on_wall := Vector2(380, 300)    # wall pixels right of its own occluder
	var on_floor := Vector2(520, 300)   # floor behind the wall
	await frames(3)
	var img := await capture()
	check_gt(case_name, "sprite pixels behind its own occluder stay lit (self_shadow off)",
			lum(img, on_wall), AMBIENT, 0.25)
	check_approx(case_name, "the floor behind the sprite is still shadowed", AMBIENT, lum(img, on_floor), TOL)
	check(case_name, "the sprite drove one self rect", 1, int(wall.material.get_shader_parameter("self_rect_count")))
	check(case_name, "the sprite is on the full tier", F.F_SELF_EXCL, F.flags_of(wall.material.shader) & F.TIER_MASK)
	wall.self_shadow = true
	await frames(2)
	img = await capture()
	check_approx(case_name, "self_shadow = true: the sprite is shadowed by its own occluder", AMBIENT,
			lum(img, on_wall), 0.06)
	check(case_name, "self_shadow = true drops to the fast tier", 0, F.flags_of(wall.material.shader) & F.TIER_MASK)
	wall.self_shadow = false
	await frames(2)
	img = await capture()
	check_gt(case_name, "self_shadow = false again: exempt again", lum(img, on_wall), AMBIENT, 0.25)
	# A sibling occluder (same parent) is owned too.
	var holder := group("Holder")
	var wall2 := box_receiver(Vector2(330, 450), Vector2(160, 60), Color.WHITE, holder)
	wall2.specular_strength = 0.0
	occluder(Vector2(300, 450), Vector2(80, 60), holder)
	await frames(3)
	img = await capture()
	check_gt(case_name, "a direct sibling occluder is owned too (sprite stays lit)", lum(img, Vector2(380, 450)),
			AMBIENT, 0.25)
	wall.queue_free()
	holder.queue_free()
	l.queue_free()
	floor_a.queue_free()
	await frames(2)


func _mask_tiers() -> void:
	var case_name := "shadow_mask_tiers"
	floor_receiver(Rect2(700, 90, 680, 430))
	var red := point_light(Vector2(800, 200), 900.0, 0.6, Color(1, 0, 0), 300.0)
	var blue := point_light(Vector2(800, 390), 900.0, 0.6, Color(0, 0, 1), 300.0)
	for l in [red, blue]:
		l.falloff = 0.3
		l.shadow_enabled = true
	red.shadow_mask = 1
	blue.shadow_mask = 3
	var box := occluder(Vector2(1000, 295), Vector2(40, 100), _props, 2)
	var p_blue := Vector2(1200, 200)   # on blue's line through the box
	var p_red := Vector2(1200, 390)    # on red's line through the box
	await frames(4)
	var img := await capture()
	var cb := probe(img, p_blue)
	var cr := probe(img, p_red)
	check_approx(case_name, "mask-2 occluder shadows the shadow_mask-3 light (blue absent)", AMBIENT, cb.b, 0.06)
	check_gt(case_name, "control: red's ray to the blue probe passes above the box (red present there)", cb.r, AMBIENT, 0.2)
	check_gt(case_name, "mask-2 occluder does not shadow the shadow_mask-1 light (red present)", cr.r, AMBIENT, 0.2)
	check_true(case_name, "per-light exclusions publish F_MASKS", LitLightRegistry.activity_flags & F.F_MASKS != 0)
	check_true(case_name, "gx folds away under masks", LitLightRegistry.activity_flags & F.F_GX == 0)
	blue.shadow_mask = 1
	await frames(4)
	img = await capture()
	check_gt(case_name, "no light matches mask 2: globally excluded, blue reaches the point",
			probe(img, p_blue).b, AMBIENT, 0.2)
	check_true(case_name, "F_MASKS cleared", LitLightRegistry.activity_flags & F.F_MASKS == 0)
	check(case_name, "runtime SDF culling pulled the occluder out of the SDF", false, box.sdf_collision)
	check_true(case_name, "with the occluder culled from the SDF no gx shader tier is needed (F_GX off)",
			LitLightRegistry.activity_flags & F.F_GX == 0)
	set_setting("lit/render/occluder_mask_sdf_culling", false)
	await frames(4)
	img = await capture()
	check(case_name, "(known gap) turning SDF culling off at runtime restores culled occluders", true, box.sdf_collision)
	# Toggle the mask so the un-cull runs, then the gx shader tier carries the exemption.
	box.occluder_light_mask = 4
	await frames(4)
	box.occluder_light_mask = 2
	await frames(4)
	img = await capture()
	check(case_name, "culling off: the occluder is back in the SDF after a mask change", true, box.sdf_collision)
	check_true(case_name, "culling off: the globally excluded occluder publishes F_GX", LitLightRegistry.activity_flags & F.F_GX != 0)
	check_gt(case_name, "culling off: the gx shader tier exempts it (blue reaches)", probe(img, p_blue).b,
			AMBIENT, 0.2)
	set_setting("lit/render/occluder_mask_sdf_culling", true)
	box.occluder_light_mask = 1
	await frames(4)
	img = await capture()
	check_approx(case_name, "occluder back on mask 1: both lights shadowed again (blue)", AMBIENT,
			probe(img, p_blue).b, 0.06)
	check_approx(case_name, "occluder back on mask 1: red shadowed", AMBIENT, probe(img, p_red).r, 0.06)
	check(case_name, "activity flags back to cone only", F.F_CONE, LitLightRegistry.activity_flags & (F.F_GX | F.F_MASKS | F.F_CONE))
	red.shadow_mask = 0
	await frames(3)
	img = await capture()
	check_gt(case_name, "shadow_mask 0: the red light casts no shadows at all", probe(img, p_red).r, AMBIENT, 0.2)
	red.shadow_mask = 1
	await _region_done([red, blue])


func _rx() -> void:
	var case_name := "shadow_ignore_mask"
	var top := floor_receiver(Rect2(20, 560, 660, 240))
	var bottom := floor_receiver(Rect2(20, 800, 660, 240))
	top.shadow_ignore_mask = 2
	# Each floor sees only its own light (light_mask / receiver_mask pairs), so the
	# other row's light cannot fill in a shadow.
	top.receiver_mask = 1
	bottom.receiver_mask = 2
	var l1 := point_light(Vector2(120, 680), 900.0, 0.8, Color.WHITE, 300.0)
	var l2 := point_light(Vector2(120, 920), 900.0, 0.8, Color.WHITE, 300.0)
	l1.light_mask = 1
	l2.light_mask = 2
	for l in [l1, l2]:
		l.falloff = 0.3
		l.shadow_enabled = true
		l.shadow_mask = 3
	occluder(Vector2(330, 680), Vector2(40, 100), _props, 2)
	occluder(Vector2(330, 920), Vector2(40, 100), _props, 2)
	await frames(4)
	var img := await capture()
	check_gt(case_name, "top floor (shadow_ignore_mask 2) ignores the mask-2 caster", lum(img, Vector2(520, 680)),
			AMBIENT, 0.25)
	check_approx(case_name, "bottom floor (mask 0) receives it", AMBIENT, lum(img, Vector2(520, 920)), TOL)
	check_true(case_name, "rx receiver is on an _rx variant", F.flags_of(top.material.shader) & F.F_RX != 0)
	check_true(case_name, "rx receiver material is private", not LitLightRegistry.pool_is_pooled(top.material))
	check(case_name, "rx_mask landed on the material", 2, int(top.material.get_shader_parameter("rx_mask")))
	top.shadow_ignore_mask = 0
	await frames(4)
	img = await capture()
	check_approx(case_name, "mask cleared: top floor shadowed again", AMBIENT, lum(img, Vector2(520, 680)), TOL)
	check_true(case_name, "cleared mask leaves the rx variant", F.flags_of(top.material.shader) & F.F_RX == 0)
	top.shadow_ignore_mask = 2
	await frames(4)
	img = await capture()
	check_gt(case_name, "mask set again at runtime: ignores again", lum(img, Vector2(520, 680)), AMBIENT, 0.25)
	# Under a window stretch (canvas_items mode with the final transform at 2x, emulated
	# with content_scale_factor on top of whatever stretch the window already has): the
	# shader's sdf_to_px is a framebuffer-pixel basis added to the canonical frag_px, so
	# a march sample's occluder-tile index lands tiles away from the caster (190 px along
	# this ray, three tiles) and the rx exemption never fires: the floor is shadowed as
	# if it had no ignore mask. Shadows themselves are world-space and keep casting. The
	# view is shifted down 540 so the rx rows stay inside the 2x view.
	var win := get_window()
	var base_stretch := get_viewport().get_final_transform().get_scale().x
	get_viewport().canvas_transform = Transform2D(0.0, Vector2(0.0, -540.0))
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_factor = 2.0 / base_stretch
	await frames(2)
	await _await_world_sdf_warmup()
	await frames(4)
	img = await capture()
	check_approx(case_name, "window stretch emulated at 2x for the next checks (final transform scale)",
			2.0, get_viewport().get_final_transform().get_scale().x, 0.1)
	check_lt(case_name, "2x stretch: the bottom floor (mask 0) is still shadowed by its caster",
			lum(img, Vector2(520, 920)), AMBIENT + 0.15)
	check_gt(case_name, "(known gap) shadow_ignore_mask still applies under a 2x window stretch",
			lum(img, Vector2(520, 680)), AMBIENT, 0.25)
	pin_render_size(win)
	get_viewport().canvas_transform = Transform2D()
	await frames(2)
	await _await_world_sdf_warmup()
	await frames(4)
	l1.shadow_mask = 1
	await frames(4)
	img = await capture()
	check_gt(case_name, "light shadow_mask 1 vs occluder mask 2: no shadow regardless", lum(img, Vector2(520, 680)),
			AMBIENT, 0.25)
	await _region_done([l1, l2])


func _scene_exclusion() -> void:
	var case_name := "exclude_scene_occluders"
	floor_receiver(Rect2(700, 560, 680, 480))
	# A packed scene owning both its light and an occluder.
	var proto := Node2D.new()
	proto.name = "Lamp"
	var pl := LitPointLight2D.new()
	pl.name = "Light"
	pl.position = Vector2(100, 250)
	pl.range = 900.0
	pl.energy = 0.8
	pl.height = 300.0
	pl.falloff = 0.3
	pl.shadow_enabled = true
	proto.add_child(pl)
	pl.owner = proto
	var po := LightOccluder2D.new()
	po.name = "OwnOccluder"
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-20, -50), Vector2(20, -50), Vector2(20, 50), Vector2(-20, 50)])
	po.occluder = poly
	po.position = Vector2(300, 250)
	proto.add_child(po)
	po.owner = proto
	var packed := PackedScene.new()
	packed.pack(proto)
	proto.free()
	var inst := packed.instantiate() as Node2D
	inst.position = Vector2(700, 540)
	add_child(inst)
	var light := inst.get_node("Light") as LitPointLight2D
	occluder(Vector2(1000, 900), Vector2(40, 100), _props)   # an outside occluder
	var own_pt := Vector2(1200, 790)
	var outside_pt := Vector2(1200, 1010)
	await frames(4)
	var img := await capture()
	check_true(case_name, "instanced light has its scene root as owner", light.owner == inst)
	check_approx(case_name, "exclude off: the scene's own occluder shadows", AMBIENT, lum(img, own_pt), TOL)
	light.exclude_scene_occluders = true
	await frames(4)
	img = await capture()
	check_gt(case_name, "exclude on: the scene's own occluder is ignored", lum(img, own_pt), AMBIENT, 0.25)
	check_approx(case_name, "exclude on: an outside occluder still shadows", AMBIENT, lum(img, outside_pt), 0.06)
	check_true(case_name, "owner scoping publishes F_MASKS", LitLightRegistry.activity_flags & F.F_MASKS != 0)
	light.exclude_scene_occluders = false
	await frames(4)
	img = await capture()
	check_approx(case_name, "exclude off again: own occluder shadows", AMBIENT, lum(img, own_pt), TOL)
	await _region_done([light])


func _ysort() -> void:
	var case_name := "y_sort_shadows"
	var floor_a := floor_receiver(Rect2(20, 90, 660, 430))
	# The floor owns a strip occluder: self-excluded, and it sets the floor's depth line
	# at world y 460 (the strip's bottom).
	occluder(Vector2(0, 150), Vector2(600, 10), floor_a)
	var l := point_light(Vector2(120, 415), 900.0, 0.8, Color.WHITE, 300.0)
	l.falloff = 0.3
	l.shadow_enabled = true
	var behind := occluder(Vector2(330, 330), Vector2(40, 60), _props)   # bottom 360: above the line
	var front := occluder(Vector2(330, 470), Vector2(40, 60), _props)    # bottom 500: below the line
	var p_behind := Vector2(540, 245)   # on the light's line through the higher box
	var p_front := Vector2(480, 509)    # on its line through the lower box, still on the floor
	await frames(4)
	var img := await capture()
	check_approx(case_name, "y-sort off: the higher occluder shadows the floor", AMBIENT, lum(img, p_behind), 0.06)
	check_approx(case_name, "y-sort off: the lower occluder shadows the floor", AMBIENT, lum(img, p_front), 0.06)
	set_setting("lit/render/y_sorting", true)
	await frames(4)
	img = await capture()
	check_true(case_name, "y-sort on: the floor is on a _ysort variant", F.flags_of(floor_a.material.shader) & F.F_YSORT != 0)
	check(case_name, "floor ysort_on landed", true, floor_a.material.get_shader_parameter("ysort_on"))
	check_approx(case_name, "floor depth line = its owned strip's bottom (460)", 460.0,
			float(floor_a.material.get_shader_parameter("ysort_y")), 1.0)
	var lit_on := lum(img, p_behind)
	check_gt(case_name, "y-sort on: an occluder above the floor's line no longer shadows it", lit_on,
			AMBIENT, 0.25)
	check_approx(case_name, "y-sort on: an occluder below the line still shadows", AMBIENT, lum(img, p_front), 0.06)
	# Same window-stretch defect as the rx case: at a 2x final transform the y-sort
	# candidate lookup reads a tile near the light instead of the higher box (230 px off
	# along this ray), finds nothing, and the box shadows the floor again.
	var win := get_window()
	var base_stretch := get_viewport().get_final_transform().get_scale().x
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_factor = 2.0 / base_stretch
	await frames(2)
	await _await_world_sdf_warmup()
	await frames(4)
	img = await capture()
	check_approx(case_name, "window stretch emulated at 2x for the next check (final transform scale)",
			2.0, get_viewport().get_final_transform().get_scale().x, 0.1)
	check_gt(case_name, "(known gap) y-sort exclusion still applies under a 2x window stretch",
			lum(img, p_behind), AMBIENT, 0.25)
	pin_render_size(win)
	await frames(2)
	await _await_world_sdf_warmup()
	await frames(4)
	img = await capture()
	# Band 400: the higher box's bottom (360) sits 100 px above the line (460), so its
	# shadow keeps weight smoothstep(-400, 400, -100) = 0.32 (lit_ysort.gdshaderinc): a
	# partial shadow, neither the full umbra nor the y-sort-on lit value.
	set_setting("lit/render/y_sort_smoothing", 400.0)
	await frames(3)
	img = await capture()
	check_between(case_name, "y_sort_smoothing 400: an occluder 100 px above the line casts a partial shadow",
			lum(img, p_behind), AMBIENT + 0.03, lit_on - 0.03)
	# The band is symmetric: the lower box's bottom (500) is 40 px below the line, weight
	# smoothstep(-400, 400, 40) = 0.57, so its full umbra opens up into a partial shadow.
	check_gt(case_name, "y_sort_smoothing 400: the occluder 40 px below the line also fades to a partial shadow",
			lum(img, p_front), AMBIENT, 0.1)
	set_setting("lit/render/y_sorting", false)
	await frames(4)
	img = await capture()
	check_approx(case_name, "y-sort off again: the higher occluder shadows again", AMBIENT, lum(img, p_behind), 0.06)
	check_true(case_name, "y-sort off: the floor left the _ysort variant", F.flags_of(floor_a.material.shader) & F.F_YSORT == 0)
	behind.name = "Behind"
	front.name = "Front"
