extends LitSuiteSection

## Light node API: every method Godot's Light2D / PointLight2D / DirectionalLight2D
## declares (set_energy(), set_item_cull_mask(), set_z_range_min()...) exists on the
## matching Lit light with the core signature, read from ClassDB at run time so either
## side drifting fails; the six intentionally dropped methods (editor_only, shadow_filter,
## shadow_filter_smooth) stay absent; the methods read and write the Lit properties they
## alias (light_mask, shadow_mask, shadow_reach, texture_offset); setters keep their side
## effects (light-cache notification, range packing, the mask latch); the rendered frame
## follows values set only through the methods; a directional light keeps its own shadow
## dials and loads, re-saves and renders every shadow value from a scene file; and the
## three nodes share the LitLight2D
## base, point and spot through LitPositionalLight2D (abstract, enums, group wiring,
## visibility notification) without splitting any inspector group across their class
## sections.

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
	["PointLight2D", "LitLineLight2D"],
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

# Every directional shadow value off its default (plus the energy/height the rendered
# checks need), written into a scene file and loaded back by _directional_surface().
const SUN_SCRIPT := "res://addons/lit/nodes/lit_directional_light_2d.gd"
const SUN_SAVED := {
	"energy": 0.8, "height": 150.0, "shadow_enabled": true, "shadow_algorithm": 0,
	"shadow_hardness": 1.0, "shadow_samples": 4, "shadow_jitter": 0.5,
	"shadow_length": 0.05, "shadow_reach": 2048.0, "source_angle": 12.0,
}

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
	_inspector_groups()
	await _rendered()
	await _directional_surface()


func _new_light(lit_name: String) -> LitLight2D:
	match lit_name:
		"LitPointLight2D":
			return LitPointLight2D.new()
		"LitSpotLight2D":
			return LitSpotLight2D.new()
		"LitLineLight2D":
			return LitLineLight2D.new()
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


## A directional light's own shadow surface, whatever the inspector grouping: the
## algorithm-gated dials show only when they apply, shadow_length still reaches 0 (no
## shadow), no positional property leaks onto it, and a scene file carrying every
## shadow value loads, re-saves each one exactly once and renders with them.
func _directional_surface() -> void:
	var c := "directional_surface"
	var sun := LitDirectionalLight2D.new()
	var info := {}
	for p in sun.get_property_list():
		info[String(p.name)] = p
	var length_range := String(info["shadow_length"].hint_string).split(",")
	check(c, "shadow_length range is 0..1 (0 = no shadow stays reachable)", [0.0, 1.0],
			[float(length_range[0]), float(length_range[1])])
	var leaked := []
	for p in ["range", "falloff", "texture", "texture_scale", "texture_size_mode",
			"texture_offset", "source_radius", "spot_angle", "spot_softness"]:
		if info.has(p):
			leaked.append(p)
	check(c, "no positional property on a directional light", [], leaked)
	var always := ["shadow_enabled", "shadow_mask", "exclude_scene_occluders",
			"shadow_algorithm", "shadow_color", "shadow_hardness", "shadow_length", "shadow_reach"]
	var gated := ["source_angle", "shadow_samples", "shadow_jitter"]
	var expect := {
		LitShaderLibrary.ShadowAlgorithm.RAYMARCHED: [],
		LitShaderLibrary.ShadowAlgorithm.CONE_TRACED: ["source_angle"],
		LitShaderLibrary.ShadowAlgorithm.STOCHASTIC: gated,
	}
	for algo in expect:
		sun.shadow_algorithm = algo
		var algo_name := String(LitShaderLibrary.ShadowAlgorithm.find_key(algo))
		check(c, "%s: shadow dials always shown" % algo_name, always, _shown(sun, always))
		check(c, "%s: algorithm-gated dials shown" % algo_name, expect[algo], _shown(sun, gated))
	sun.free()

	# Load a scene file carrying every value, as a saved scene stores them.
	var lines := PackedStringArray(["[gd_scene format=3]", "",
			"[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]" % SUN_SCRIPT, "",
			"[node name=\"Sun\" type=\"Node2D\"]", "script = ExtResource(\"1\")"])
	for key in SUN_SAVED:
		lines.append("%s = %s" % [key, var_to_str(SUN_SAVED[key])])
	var path := "user://lit_suite_directional.tscn"
	var resaved_path := "user://lit_suite_directional_resaved.tscn"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	var scene := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var loaded: LitDirectionalLight2D = scene.instantiate() if scene != null else null
	if not check_true(c, "the scene file loads as a LitDirectionalLight2D", loaded != null):
		return
	for key in SUN_SAVED:
		check(c, "loads %s" % key, SUN_SAVED[key], loaded.get(key))

	# Re-save it as a plain node (not an instance of the file it came from).
	loaded.scene_file_path = ""
	var repacked := PackedScene.new()
	repacked.pack(loaded)
	ResourceSaver.save(repacked, resaved_path)
	var text := FileAccess.get_file_as_string(resaved_path)
	var miswritten := []
	for key in SUN_SAVED:
		if text.count("\n%s = " % key) != 1:
			miswritten.append(key)
	check(c, "re-saving writes each value exactly once", [], miswritten)
	var reloaded := (ResourceLoader.load(resaved_path, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	for key in SUN_SAVED:
		check(c, "re-saved %s loads back" % key, SUN_SAVED[key], reloaded.get(key))
	reloaded.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(resaved_path))

	# Render the loaded sun (rotation 0, from the left) over a box at B: its shadow stops
	# at shadow_reach x shadow_length past the box.
	var props := group("SunProps")
	occluder(B, Vector2(40, 100), props)
	add_child(loaded)
	await frames(3)
	var img := await capture()
	_lit(c, "loaded sun lights the floor outside the shadow band", img, P)
	_lit(c, "loaded reach 2048 x length 0.05 (102 px) stops short of the probe 170 px past the box",
			img, S, 0.15)
	loaded.shadow_length = 0.25
	await frames(3)
	img = await capture()
	_dark(c, "length 0.25 (512 px) reaches the probe: in shadow", img, S)
	loaded.shadow_length = 0.0
	await frames(3)
	img = await capture()
	_lit(c, "length 0: no shadow at all", img, S, 0.15)
	loaded.queue_free()
	props.queue_free()
	await frames(2)


## The subset of `names` the inspector shows on `obj`, in `names` order.
func _shown(obj: Object, names: Array) -> Array:
	var shown := {}
	for p in obj.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR:
			shown[String(p.name)] = true
	return names.filter(func(n: String) -> bool: return shown.has(n))


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
	check_true(c, "LitLight2D is abstract", base.is_abstract())
	check_true(c, "LitPositionalLight2D is abstract", positional.is_abstract())
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
		# Calling the virtual directly errors when the script doesn't override it, which
		# would abort the rest of this loop.
		var warnings: PackedStringArray = node._get_configuration_warnings() \
				if node.has_method("_get_configuration_warnings") else PackedStringArray()
		check(c, "%s carries no configuration warning" % lit_name, 0, warnings.size())
		check(c, "%s.BlendMode is the shared enum" % lit_name, LitShaderLibrary.BlendMode, node.get_script().get("BlendMode"))
		check(c, "%s.ShadowAlgorithm is the shared enum" % lit_name, LitShaderLibrary.ShadowAlgorithm, node.get_script().get("ShadowAlgorithm"))
		if node is LitDirectionalLight2D:
			check_true(c, "%s has no cookie methods" % lit_name, not node.has_method("set_texture") and not node.has_method("get_texture_offset"))
		else:
			check(c, "%s.TextureSizeMode is the shared enum" % lit_name, LitShaderLibrary.TextureSizeMode, node.get_script().get("TextureSizeMode"))
			check_true(c, "%s has no set_max_distance" % lit_name, not node.has_method("set_max_distance"))
		node.free()


func _inspector_groups() -> void:
	var c := "inspector_groups"
	for pair in PAIRS:
		var lit_name: String = pair[1]
		var node := _new_light(lit_name)
		check(c, "%s: no group split across Lit class sections" % lit_name, [], _split_groups(node))
		node.free()


## Group names that show under more than one Lit class section of the inspector: Godot
## gives every script in the chain its own section and never merges same-named groups.
func _split_groups(obj: Object) -> Array:
	var section_of := {}
	var split := []
	var section := ""
	for p in obj.get_property_list():
		if p.usage & PROPERTY_USAGE_CATEGORY:
			section = p.hint_string if String(p.hint_string).begins_with("res://addons/lit/") else ""
		elif p.usage & PROPERTY_USAGE_GROUP and not section.is_empty():
			if section_of.get(p.name, section) != section and not split.has(p.name):
				split.append(p.name)
			section_of[p.name] = section
	return split


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
