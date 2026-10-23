extends LitSuiteSection

## Light node API: every method Godot's Light2D / PointLight2D / DirectionalLight2D
## declares (set_energy(), set_item_cull_mask(), set_z_range_min()...) exists on the
## matching Lit light with the core signature, read from ClassDB at run time so either
## side drifting fails; the six intentionally dropped methods (editor_only, shadow_filter,
## shadow_filter_smooth) stay absent; the methods read and write the Lit properties they
## alias (light_mask, shadow_mask, shadow_reach, texture_offset); setters keep their side
## effects (light-cache notification, range packing, the mask latch); the rendered frame
## follows values set only through the methods; and the three nodes share the LitLight2D
## base, point and spot through LitPositionalLight2D (enums, group wiring, visibility
## notification, bare-base warnings).

const AMBIENT := 0.1
const TOL := 0.03
const DROPPED: Array[String] = ["set_editor_only", "is_editor_only", "set_shadow_filter",
	"get_shadow_filter", "set_shadow_smooth", "get_shadow_smooth"]
# Own (non-inherited) method counts of the core classes under Godot 4.7.2; guards the
# ClassDB query against returning an empty surface and passing every check vacuously.
const CORE_COUNTS := {"Light2D": 32, "PointLight2D": 6, "DirectionalLight2D": 2}
const PAIRS := [
	["PointLight2D", "LitPointLight2D"],
	["PointLight2D", "LitSpotLight2D"],
	["DirectionalLight2D", "LitDirectionalLight2D"],
]
# setter, getter, Lit property, probe value (must differ from the default).
const SHARED := [
	["set_enabled", "is_enabled", "enabled", false],
	["set_color", "get_color", "color", Color(0.2, 0.4, 0.6, 1.0)],
	["set_energy", "get_energy", "energy", 2.5],
	["set_height", "get_height", "height", 42.0],
	["set_blend_mode", "get_blend_mode", "blend_mode", LitShaderLibrary.BlendMode.SUBTRACT],
	["set_shadow_enabled", "is_shadow_enabled", "shadow_enabled", true],
	["set_shadow_color", "get_shadow_color", "shadow_color", Color(0.1, 0.2, 0.3, 0.4)],
	["set_item_cull_mask", "get_item_cull_mask", "light_mask", 5],
	["set_item_shadow_cull_mask", "get_item_shadow_cull_mask", "shadow_mask", 6],
	["set_z_range_min", "get_z_range_min", "range_z_min", -7],
	["set_z_range_max", "get_z_range_max", "range_z_max", 9],
	["set_layer_range_min", "get_layer_range_min", "range_layer_min", -3],
	["set_layer_range_max", "get_layer_range_max", "range_layer_max", 4],
]

# Light L, box B, probe S behind the box, P outside the shadow band (shadows geometry).
const L := Vector2(120, 300)
const B := Vector2(330, 300)
const S := Vector2(520, 300)
const P := Vector2(520, 120)


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	label("Light2D method surface on Lit lights: parity, aliases, side effects, rendered", Vector2(24, 74))
	floor_receiver(Rect2(20, 90, 660, 430))
	await frames(2)
	_parity()
	_roundtrip()
	_side_effects()
	_base_class()
	await _rendered()


func _new_light(lit_name: String) -> LitLight2D:
	match lit_name:
		"LitPointLight2D":
			return LitPointLight2D.new()
		"LitSpotLight2D":
			return LitSpotLight2D.new()
	return LitDirectionalLight2D.new()


func _sig(m: Dictionary) -> String:
	var parts := PackedStringArray()
	for a in m["args"]:
		parts.append(_type_name(a))
	return "(%s) -> %s" % [", ".join(parts), _type_name(m["return"])]


func _type_name(info: Dictionary) -> String:
	var t: int = info["type"]
	if t == TYPE_OBJECT:
		return String(info["class_name"])
	return type_string(t)


func _parity() -> void:
	var c := "api_parity"
	var light2d := {}
	for m in ClassDB.class_get_method_list("Light2D", true):
		light2d[String(m["name"])] = m
	check(c, "Light2D declares %d own methods" % CORE_COUNTS["Light2D"], CORE_COUNTS["Light2D"], light2d.size())
	for name in DROPPED:
		check_true(c, "core still declares the intentionally dropped %s" % name, light2d.has(name))
	for pair in PAIRS:
		var core: String = pair[0]
		var lit_name: String = pair[1]
		var node := _new_light(lit_name)
		var lit_methods := {}
		for m in node.get_method_list():
			lit_methods[String(m["name"])] = m
		var core_methods := light2d.duplicate()
		var own := ClassDB.class_get_method_list(core, true)
		check(c, "%s declares %d own methods" % [core, CORE_COUNTS[core]], CORE_COUNTS[core], own.size())
		for m in own:
			core_methods[String(m["name"])] = m
		for name in core_methods:
			if name in DROPPED:
				check_true(c, "%s: %s stays absent" % [lit_name, name], not node.has_method(name))
			elif check_true(c, "%s has %s" % [lit_name, name], node.has_method(name)):
				check(c, "%s.%s signature" % [lit_name, name], _sig(core_methods[name]), _sig(lit_methods[name]))
		node.free()


func _roundtrip() -> void:
	var c := "api_roundtrip"
	var cookie := tex_solid(8, Color.WHITE)
	for pair in PAIRS:
		var lit_name: String = pair[1]
		var node := _new_light(lit_name)
		var rows: Array = SHARED.duplicate()
		if node is LitDirectionalLight2D:
			rows.append(["set_max_distance", "get_max_distance", "shadow_reach", 2048.0])
		else:
			rows.append(["set_texture", "get_texture", "texture", cookie])
			rows.append(["set_texture_offset", "get_texture_offset", "texture_offset", Vector2(3, -5)])
			rows.append(["set_texture_scale", "get_texture_scale", "texture_scale", 1.75])
		for row in rows:
			var setter: String = row[0]
			var getter: String = row[1]
			var prop: String = row[2]
			var value: Variant = row[3]
			var before: Variant = node.get(prop)
			if not check_true(c, "%s has %s and %s" % [lit_name, setter, getter], node.has_method(setter) and node.has_method(getter)):
				continue
			if not check_true(c, "%s.%s: probe value differs from the default" % [lit_name, prop], not _eq(before, value)):
				continue
			node.call(setter, value)
			check(c, "%s.%s() writes %s" % [lit_name, setter, prop], value, node.get(prop))
			check(c, "%s.%s() reads %s back" % [lit_name, getter, prop], value, node.call(getter))
			node.set(prop, before)
			check(c, "%s.%s() follows a direct %s write" % [lit_name, getter, prop], before, node.call(getter))
		node.free()


func _side_effects() -> void:
	var c := "api_side_effects"
	var cache := LitLightRegistry.LightCacheScript
	var packer := LitLightRegistry.LightPackerScript
	var node := LitPointLight2D.new()
	var id := node.get_instance_id()
	LitLightRegistry.light_masks_seen = false
	LitLightRegistry.light_ranges_seen = false
	for probe in [["set_enabled", false], ["set_shadow_enabled", true], ["set_item_shadow_cull_mask", 6]]:
		cache._pending.erase(id)
		node.call(probe[0], probe[1])
		check_true(c, "%s() marks the light pending in the light cache" % probe[0], cache._pending.has(id))
	check_true(c, "set_item_shadow_cull_mask(6) latches light_masks_seen", LitLightRegistry.light_masks_seen)
	check_true(c, "fresh light is not ranged", not node.ranged)
	node.set_z_range_min(-7)
	check_true(c, "set_z_range_min() marks the light ranged", node.ranged)
	check(c, "set_z_range_min() packs the ranges", packer.range_pack(-7, 4096, -4096, 4096), node.range_pack)
	check_true(c, "set_z_range_min() latches light_ranges_seen", LitLightRegistry.light_ranges_seen)
	node.set_layer_range_max(3)
	check(c, "set_layer_range_max() repacks", packer.range_pack(-7, 4096, -4096, 3), node.range_pack)
	node.set_z_range_min(-4096)
	node.set_layer_range_max(4096)
	check_true(c, "restoring both ranges clears ranged", not node.ranged)
	add_child(node)
	check_true(c, "enters the lit_lights group on _enter_tree", node.is_in_group("lit_lights"))
	cache._pending.erase(id)
	node.visible = false
	check_true(c, "visibility change marks the light pending", cache._pending.has(id))
	remove_child(node)
	check_true(c, "leaves the group on _exit_tree", not node.is_in_group("lit_lights"))
	cache._pending.erase(id)
	node.free()


func _base_class() -> void:
	var c := "base_class"
	var base := load("res://addons/lit/nodes/lit_light_2d.gd") as GDScript
	var registered := false
	for entry in ProjectSettings.get_global_class_list():
		if entry["class"] == &"LitLight2D":
			registered = entry["base"] == &"Node2D" and entry["path"] == base.resource_path
	check_true(c, "LitLight2D is a registered global class on Node2D", registered)
	var positional := load("res://addons/lit/nodes/lit_positional_light_2d.gd") as GDScript
	check(c, "LitPositionalLight2D extends the base script", base, positional.get_base_script())
	for bare in [LitLight2D.new(), LitPositionalLight2D.new()]:
		check(c, "a bare %s node carries one configuration warning" % bare.get_script().get_global_name(), 1, bare._get_configuration_warnings().size())
		bare.free()
	for pair in PAIRS:
		var lit_name: String = pair[1]
		var node := _new_light(lit_name)
		check_true(c, "%s is LitLight2D" % lit_name, node is LitLight2D)
		if node is LitDirectionalLight2D:
			check_true(c, "%s is not positional" % lit_name, not node is LitPositionalLight2D)
			check(c, "%s extends the base script directly" % lit_name, base, (node.get_script() as GDScript).get_base_script())
		else:
			check_true(c, "%s is LitPositionalLight2D" % lit_name, node is LitPositionalLight2D)
			check(c, "%s extends the positional script" % lit_name, positional, (node.get_script() as GDScript).get_base_script())
		check(c, "%s carries no configuration warning" % lit_name, 0, node._get_configuration_warnings().size())
		check(c, "%s.BlendMode is the shared enum" % lit_name, LitShaderLibrary.BlendMode, node.get_script().get("BlendMode"))
		check(c, "%s.ShadowAlgorithm is the shared enum" % lit_name, LitShaderLibrary.ShadowAlgorithm, node.get_script().get("ShadowAlgorithm"))
		if node is LitDirectionalLight2D:
			check_true(c, "%s has no cookie methods" % lit_name, not node.has_method("set_texture") and not node.has_method("get_texture_offset"))
		else:
			check(c, "%s.TextureSizeMode is the shared enum" % lit_name, LitShaderLibrary.TextureSizeMode, node.get_script().get("TextureSizeMode"))
			check_true(c, "%s has no set_max_distance" % lit_name, not node.has_method("set_max_distance"))
		node.free()


func _lit(c: String, desc: String, img: Image, at: Vector2, margin := 0.25) -> void:
	check_gt(c, desc, lum(img, at), AMBIENT, margin)


func _dark(c: String, desc: String, img: Image, at: Vector2) -> void:
	check_approx(c, desc, AMBIENT, lum(img, at), TOL)


## A point light driven only through the Light2D methods, over the shadows-section
## geometry; every method that changes what is rendered is read back from the frame.
func _rendered() -> void:
	var c := "api_rendered"
	var light := LitPointLight2D.new()
	light.position = L
	light.range = 500.0
	light.falloff = 0.3
	light.set_energy(0.8)
	light.set_height(300.0)
	light.set_enabled(false)
	add_child(light)
	var props := group("Props")
	occluder(B, Vector2(40, 100), props)
	await frames(3)
	var img := await capture()
	_dark(c, "set_enabled(false): probe at ambient", img, S)
	light.set_enabled(true)
	await frames(2)
	img = await capture()
	_lit(c, "set_enabled(true): probe lit", img, S)

	light.set_item_cull_mask(2)
	await frames(2)
	img = await capture()
	_dark(c, "set_item_cull_mask(2) misses the mask-1 receiver", img, S)
	light.set_item_cull_mask(1)
	await frames(2)
	img = await capture()
	_lit(c, "set_item_cull_mask(1) lights it again", img, S)

	light.set_energy(0.0)
	await frames(2)
	img = await capture()
	_dark(c, "set_energy(0) is dark", img, S)
	light.set_energy(0.8)
	light.set_color(Color(1.0, 0.0, 0.0))
	await frames(2)
	img = await capture()
	var col := probe(img, S)
	check_gt(c, "set_color(red): red channel lit", col.r, AMBIENT, 0.25)
	check_approx(c, "set_color(red): green channel ambient", AMBIENT, col.g, TOL)
	light.set_color(Color.WHITE)

	light.set_z_range_min(5)
	await frames(2)
	img = await capture()
	_dark(c, "set_z_range_min(5) excludes the z 0 receiver", img, S)
	light.set_z_range_min(-4096)
	await frames(2)
	img = await capture()
	_lit(c, "set_z_range_min(-4096) includes it again", img, S)

	light.set_shadow_enabled(true)
	await frames(3)
	img = await capture()
	_dark(c, "set_shadow_enabled(true): probe behind the box at ambient", img, S)
	_lit(c, "set_shadow_enabled(true): outside the shadow band lit", img, P, 0.15)
	light.set_shadow_color(Color(1.0, 0.0, 0.0))
	await frames(2)
	img = await capture()
	col = probe(img, S)
	check_gt(c, "set_shadow_color(red): red stays in the shadow", col.r, AMBIENT, 0.25)
	check_approx(c, "set_shadow_color(red): green channel ambient", AMBIENT, col.g, TOL)
	light.set_shadow_color(Color.BLACK)
	light.set_item_shadow_cull_mask(2)
	await frames(4)
	img = await capture()
	_lit(c, "set_item_shadow_cull_mask(2): the mask-1 box no longer casts", img, S)
	light.set_item_shadow_cull_mask(1)
	await frames(4)
	img = await capture()
	_dark(c, "set_item_shadow_cull_mask(1): shadow back", img, S)
	light.set_shadow_enabled(false)

	var cookie := tex_solid(64, Color.WHITE)
	light.set_texture(cookie)
	await frames(3)
	img = await capture()
	_dark(c, "set_texture(64 px cookie): probe outside the cookie is dark", img, S)
	light.set_texture_offset(Vector2(400.0, 0.0))
	await frames(2)
	img = await capture()
	_lit(c, "set_texture_offset(400, 0) slides the cookie onto the probe", img, S)
	light.set_texture_offset(Vector2.ZERO)
	light.set_texture_scale(16.0)
	await frames(2)
	img = await capture()
	_lit(c, "set_texture_scale(16) grows the cookie over the probe", img, S)
	light.set_texture_scale(1.0)
	light.set_texture(null)
	await frames(3)
	img = await capture()
	_lit(c, "set_texture(null): analytic light back", img, S)
	light.set_enabled(false)

	var sun := LitDirectionalLight2D.new()
	sun.set_energy(0.8)
	sun.set_height(150.0)
	add_child(sun)
	await frames(2)
	img = await capture()
	_lit(c, "directional set_energy(0.8): probe lit", img, P)
	sun.set_enabled(false)
	await frames(2)
	img = await capture()
	_dark(c, "directional set_enabled(false): probe at ambient", img, P)
