extends LitSuiteSection

## The runtime registry as a game sees it: the light cache following tree changes,
## bare receivers (a Sprite2D handed the receiver material) driven through
## LitReceiverHelper (self rects, tier swaps, the self_shadow opt-out, freed-occluder
## healing), the Lit nodes driving themselves,
## activity flags and the automatic receiver variant swap following the shadow
## algorithms and mask states in play, and the rx registry.

const RegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")
const RxRegistryScript := preload("res://addons/lit/runtime/registry/rx_registry.gd")
const F := preload("res://addons/lit/runtime/lit_shader_library.gd")
const AMBIENT := 0.1

var _mgr: Node
var _props: Node2D


func run() -> void:
	_mgr = get_node("/root/LitManager")
	_props = group("Props")
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	label("bare receivers (Sprite2D + receiver material) with owned occluders, driven by the registry",
			Vector2(24, 74))
	await _light_cache()
	await _bare_driving()
	await _activity_flags()
	await _rx_registry()


func _make_bare(pos: Vector2, size := Vector2(80, 80)) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = tex_sized(size)
	s.material = receiver_material()
	s.position = pos
	add_child(s)
	return s


func _mat(n: CanvasItem) -> ShaderMaterial:
	return n.material as ShaderMaterial


func _light_cache() -> void:
	var case_name := "light_cache"
	var cache = _mgr._registry._light_cache
	var before: int = cache.all().size()
	var l := point_light(Vector2(300, 300), 200.0, 0.5)
	await frames(1)
	check(case_name, "a light entering the tree joins the cache", before + 1, cache.all().size())
	var vis: Array = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "an enabled visible light in view is culled in", vis.has(l))
	l.enabled = false
	await frames(1)
	vis = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "enabled = false drops it from the visible set", not vis.has(l))
	l.enabled = true
	l.visible = false
	await frames(1)
	vis = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "visible = false drops it from the visible set", not vis.has(l))
	l.visible = true
	l.position = Vector2(-5000, -5000)
	await frames(1)
	vis = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "a point light far outside the view is culled", not vis.has(l))
	l.position = Vector2(2400, 300)
	await frames(1)
	vis = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "480 px right of the view with range 200: culled", not vis.has(l))
	l.range = 1000.0
	await frames(1)
	vis = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "range raised to 1000: the light_state_changed re-mirror pulls it into view", vis.has(l))
	var d := directional_light(0.0, 0.2)
	d.position = Vector2(-5000, -5000)
	await frames(1)
	vis = cache.cull_visible(get_tree(), Rect2(0, 0, 1920, 1080))
	check_true(case_name, "a directional light is never positionally culled", vis.has(d))
	l.queue_free()
	d.queue_free()
	await frames(3)
	check(case_name, "freed lights leave the cache", before, cache.all().size())


func _bare_driving() -> void:
	var case_name := "bare_receiver_driving"
	var bare := _make_bare(Vector2(200, 300))
	var occ := occluder(Vector2(0, 30), Vector2(40, 10), bare)
	# (A material shared by two occluder-owning bare receivers is skipped with a Lit
	# warning; left unexercised so a green run stays warning-free.)
	var lit_node := box_receiver(Vector2(700, 300), Vector2(80, 80))
	occluder(Vector2(0, 30), Vector2(40, 10), lit_node)
	await frames(2)
	check(case_name, "bare: one self rect pushed", 1, int(_mat(bare).get_shader_parameter("self_rect_count")))
	check(case_name, "bare: tiered to full (self exclusion)", F.F_SELF_EXCL, F.flags_of(_mat(bare).shader))
	var rect_first: PackedVector4Array = _mat(bare).get_shader_parameter("self_rects")
	occ.position.x += 100.0
	await frames(2)
	check_true(case_name, "bare: rect follows the occluder", _mat(bare).get_shader_parameter("self_rects") != rect_first)
	# Y-sort participation before the raw self_shadow write below: the setting toggle
	# re-drives the material, and the two known-gap checks need that drive not to have
	# seen the raw write.
	set_setting("lit/render/y_sorting", true)
	await frames(3)
	check(case_name, "y_sorting on: a bare receiver with an owned occluder joins the y-sort (ysort_on)", true,
			_mat(bare).get_shader_parameter("ysort_on"))
	check_true(case_name, "y_sorting on: bare receiver on a _ysort variant", F.flags_of(_mat(bare).shader) & F.F_YSORT != 0)
	set_setting("lit/render/y_sorting", false)
	await frames(3)
	_mat(bare).set_shader_parameter("self_shadow", true)
	await frames(2)
	check(case_name, "(known gap) bare: self_shadow=true drops to the fast tier without another input moving",
			0, F.flags_of(_mat(bare).shader))
	check(case_name, "LitSprite2D drives its own rect", 1, int(lit_node.material.get_shader_parameter("self_rect_count")))
	check(case_name, "LitSprite2D tiered to full", F.F_SELF_EXCL, F.flags_of(lit_node.material.shader) & F.TIER_MASK)
	_mat(bare).set_shader_parameter("self_shadow", false)
	occ.free()
	await frames(3)
	check(case_name, "bare: freed occluder heals rects to zero", 0, int(_mat(bare).get_shader_parameter("self_rect_count")))
	check(case_name, "(known gap) bare receiver that lost its last occluder returns to the fast tier", 0,
			F.flags_of(_mat(bare).shader))
	# A bare receiver with a stale saved rect count and no occluders heals at cache rebuild.
	var stale := _make_bare(Vector2(900, 300))
	_mat(stale).set_shader_parameter("self_rect_count", 3)
	await frames(2)
	check(case_name, "stale self_rect_count on an occluder-less bare receiver is healed", 0,
			int(_mat(stale).get_shader_parameter("self_rect_count")))
	await frames(1)


func _activity_flags() -> void:
	var case_name := "activity_flags"
	# Runtime SDF culling would pull a globally excluded occluder out of the SDF instead
	# of publishing the gx shader tier; off here so the tier itself is exercised.
	set_setting("lit/render/occluder_mask_sdf_culling", false)
	await frames(1)
	var plain := _make_bare(Vector2(300, 600))
	var lit := box_receiver(Vector2(450, 600), Vector2(80, 80))
	var version_start: int = RegistryScript.activity_version
	var l := point_light(Vector2(200, 700), 500.0, 0.5)
	l.shadow_enabled = true
	l.shadow_algorithm = F.ShadowAlgorithm.CONE_TRACED
	occluder(Vector2(400, 720), Vector2(40, 40), _props, 1)
	await frames(3)
	var fl: int = RegistryScript.activity_flags
	check_true(case_name, "cone light publishes F_CONE", fl & F.F_CONE != 0 and fl & F.F_STOCH == 0)
	check_true(case_name, "activity_version moved", RegistryScript.activity_version > version_start)
	check_true(case_name, "bare receiver material re-pointed to a _cone variant", F.flags_of(_mat(plain).shader) & F.F_CONE != 0)
	check_true(case_name, "LitSprite2D material re-pointed to a _cone variant", F.flags_of(lit.material.shader) & F.F_CONE != 0)
	l.shadow_algorithm = F.ShadowAlgorithm.STOCHASTIC
	await frames(3)
	fl = RegistryScript.activity_flags
	check_true(case_name, "algorithm switch publishes F_STOCH", fl & F.F_STOCH != 0 and fl & F.F_CONE == 0)
	check_true(case_name, "materials follow to a _stoch variant", F.flags_of(_mat(plain).shader) & F.F_STOCH != 0)
	l.shadow_algorithm = F.ShadowAlgorithm.RAYMARCHED
	await frames(3)
	check(case_name, "raymarched with default masks publishes 0", 0, RegistryScript.activity_flags)
	check(case_name, "materials back on the base variant", 0, F.flags_of(_mat(plain).shader))
	var gx := occluder(Vector2(500, 720), Vector2(40, 40), _props, 2)
	await frames(6)
	fl = RegistryScript.activity_flags
	check_true(case_name, "occluder excluded from every light publishes F_GX", fl & F.F_GX != 0)
	check_true(case_name, "no per-light masks yet", fl & F.F_MASKS == 0)
	var l2 := point_light(Vector2(200, 900), 500.0, 0.5)
	l2.shadow_enabled = true
	l2.shadow_mask = 3
	await frames(6)
	fl = RegistryScript.activity_flags
	check_true(case_name, "split shadow masks publish F_MASKS", fl & F.F_MASKS != 0)
	check_true(case_name, "gx tier folds away under masks", fl & F.F_GX == 0)
	check_true(case_name, "materials on a _mask variant", F.flags_of(_mat(plain).shader) & F.F_MASKS != 0)
	l2.queue_free()
	gx.queue_free()
	l.shadow_enabled = false
	await frames(6)
	check(case_name, "everything back off: flags 0", 0, RegistryScript.activity_flags)
	check_true(case_name, "shadow_enabled = false with a cone light: no F_CONE (only casting lights count)",
			RegistryScript.activity_flags & F.F_CONE == 0)
	l.queue_free()
	plain.queue_free()
	lit.queue_free()
	await frames(1)
	restore_settings()


func _rx_registry() -> void:
	var case_name := "rx_registry"
	var s := box_receiver(Vector2(1100, 600), Vector2(80, 80))
	await frames(1)
	check_true(case_name, "a receiver with mask 0 is not registered", not RxRegistryScript.nodes().has(s))
	s.shadow_ignore_mask = 6
	check(case_name, "shadow_ignore_mask registers the node with its mask", 6, int(RxRegistryScript.nodes().get(s, 0)))
	await frames(2)
	check_true(case_name, "rx node on an _rx variant", F.flags_of(s.material.shader) & F.F_RX != 0)
	check(case_name, "rx_mask landed", 6, int(s.material.get_shader_parameter("rx_mask")))
	s.shadow_ignore_mask = 0
	check_true(case_name, "clearing the mask unregisters", not RxRegistryScript.nodes().has(s))
	await frames(2)
	check_true(case_name, "cleared node leaves the _rx variant", F.flags_of(s.material.shader) & F.F_RX == 0)
	s.shadow_ignore_mask = 2
	s.queue_free()
	await frames(2)
	var live := 0
	for n in RxRegistryScript.nodes():
		if is_instance_valid(n) and n.is_inside_tree():
			live += 1
	check(case_name, "freed rx nodes are pruned", 0, live)
