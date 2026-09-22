extends LitSuiteSection

## "Update Project to Lit" (Project > Tools): the fixtures under Test/.update_tool_bench
## are copied to a scratch folder and the full update runs rooted there. Checks the
## conversion contracts the tool ships: core light / modulate replacement with property
## mapping, receiver script swaps with CanvasTexture wrapping, user-script rebasing
## (plus the collision skip, @tool insertion and reference retyping), instance override
## remaps with delta preservation, connection / unique-name / occluder survival,
## animation track renames, custom materials left for the report's attention section,
## menu/UI classification, the report file, and byte-identical idempotency.
##
## The same contracts are locked headlessly by Test/gate_update_tool.gd; this section
## keeps them in the one-window pass.

const Tool := preload("res://addons/lit/editor/lit_update_tool.gd")
const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")

const SRC := "res://Test/.update_tool_bench"
const OUT := "res://Test/.update_tool_bench/.suite_out"
const FILES := ["fixture_child.tscn", "fixture_parent.tscn", "fixture_env.tscn",
	"fixture_fx_root.tscn", "fixture_inherited.tscn", "fixture_anim_lib.tres",
	"fixture_menu.tscn", "fixture_icon.tscn", "fixture_hud_bit.tscn", "fixture_mixed.tscn",
	"fixture_preview.tscn",
	"fixture_rebase_sprite.gd", "fixture_collide_sprite.gd", "fixture_light_script.gd",
	"fixture_watcher.gd", "fixture_oneline_tile.gd", "fixture_lit_light.gd",
	"fixture_icon_sprite.gd", "fixture_rebase_anim.gd"]
const BIN_SCENE := "env_bin.scn"
const ALL_KINDS := {"lights": true, "modulates": true, "sprites": true,
	"animated_sprites": true, "tilemaps": true, "scripts": true}

var _lines: Array[String] = []


func run() -> void:
	label("Update Project to Lit: fixtures converted in a scratch copy of Test/.update_tool_bench",
			Vector2(24, 74))
	if not DirAccess.dir_exists_absolute(SRC):
		check_true("update_tool", "fixture folder %s present" % SRC, false)
		return
	_prepare()
	var scan1: Dictionary = Tool.scan([OUT])
	var run1: Dictionary = Tool.run(scan1, ALL_KINDS, OUT + "/report.txt")
	_child()
	_env()
	_parent()
	_scripts()
	_run_result(scan1, run1)
	_idempotency()
	_menus_on()
	if failed_count() == 0:
		_cleanup()
	else:
		say("SUITE   (update_tool scratch kept at %s for inspection)" % OUT)
	var y := 100.0
	for line in _lines:
		label(line, Vector2(30, y), 12)
		y += 16.0
	await frames(1)


func _note(text: String) -> void:
	_lines.append(text)


func _prepare() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(OUT)
	for f in FILES:
		var text := FileAccess.get_file_as_string(SRC + "/" + f)
		var w := FileAccess.open(OUT + "/" + f, FileAccess.WRITE)
		w.store_string(text.replace(SRC + "/", OUT + "/"))
	var env_scene := ResourceLoader.load(OUT + "/fixture_env.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	ResourceSaver.save(env_scene, OUT + "/" + BIN_SCENE)


func _cleanup() -> void:
	if not DirAccess.dir_exists_absolute(OUT):
		return
	for f in DirAccess.get_files_at(OUT):
		DirAccess.remove_absolute(OUT + "/" + f)
	DirAccess.remove_absolute(OUT)


func _fresh(path: String) -> Node:
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	return null if packed == null else packed.instantiate()


func _script_path(node: Node) -> String:
	var s := node.get_script() as Script
	return "" if s == null else s.resource_path


func _row_has_prop(state: SceneState, node_path: String, prop: String) -> bool:
	for i in state.get_node_count():
		if String(state.get_node_path(i)).trim_prefix("./") == node_path:
			for p in state.get_node_property_count(i):
				if String(state.get_node_property_name(i, p)) == prop:
					return true
	return false


func _row_is_instance(state: SceneState, node_path: String) -> bool:
	for i in state.get_node_count():
		if String(state.get_node_path(i)).trim_prefix("./") == node_path:
			return state.get_node_instance(i) != null
	return false


func _child() -> void:
	var c := "update_child_scene"
	var root := _fresh(OUT + "/fixture_child.tscn")
	if not check_true(c, "converted child scene loads", root != null):
		return
	var ver := Migrations.current_version()
	var light := root.get_node("Light")
	check(c, "light carries the LitPointLight2D script", String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]), _script_path(light))
	check(c, "light native base is Node2D", "Node2D", light.get_class())
	check_true(c, "light transform, z_index, group and metadata survive", light.position == Vector2(100, 50)
			and (light as Node2D).z_index == 3 and light.is_in_group("torches")
			and light.has_meta("_edit_lock_") and bool(light.get_meta("_edit_lock_")))
	check(c, "offset -> texture_offset", Vector2(4, -6), light.get("texture_offset"))
	check(c, "shadow_item_cull_mask -> shadow_mask", 5, int(light.get("shadow_mask")))
	check(c, "range_item_cull_mask -> light_mask", 3, light.light_mask)
	check(c, "blend_mode MIX clamped to ADD", 0, int(light.get("blend_mode")))
	check_true(c, "shadow_color premultiplied toward white", (light.get("shadow_color") as Color).is_equal_approx(Color(0.75, 0.5, 0.5, 1)))
	check_true(c, "core height not copied, energy and colour copied", is_equal_approx(float(light.get("height")), 16.0)
			and is_equal_approx(float(light.get("energy")), 1.5) and (light.get("color") as Color).is_equal_approx(Color(1, 0.8, 0.6, 1)))
	var cookie := light.get("texture") as Texture2D
	check_true(c, "cookie texture copied", cookie != null and cookie.resource_path == "res://Test/base.png")
	var base_tex := load("res://Test/base.png") as Texture2D
	var want_range := maxf(base_tex.get_size().x, base_tex.get_size().y) * 0.5 * 2.0
	check_true(c, "range from the cookie footprint, falloff 0 with a cookie",
			is_equal_approx(float(light.get("range")), want_range) and is_equal_approx(float(light.get("falloff")), 0.0))
	check_true(c, "shadow_enabled copied, shadow_filter dropped, light stamped",
			bool(light.get("shadow_enabled")) and light.get("shadow_filter") == null and str(light.get("lit_version")) == ver)

	var sprite := root.get_node("BareSprite") as Sprite2D
	check(c, "bare sprite swapped to LitSprite2D", String(Maps.SWAPS[&"Sprite2D"]), _script_path(sprite))
	check_true(c, "unique name survives", sprite.unique_name_in_owner)
	check_true(c, "sprite texture wrapped in a CanvasTexture", sprite.texture is CanvasTexture
			and (sprite.texture as CanvasTexture).diffuse_texture != null
			and (sprite.texture as CanvasTexture).diffuse_texture.resource_path == "res://Test/base.png")
	check_true(c, "light_mask -> receiver_mask, sprite light_mask and offset untouched, stamped",
			int(sprite.get("receiver_mask")) == 2 and sprite.light_mask == 2 and sprite.offset == Vector2(10, 5)
			and str(sprite.get("lit_version")) == ver)

	var anim_sprite := root.get_node("BareAnimSprite") as AnimatedSprite2D
	check(c, "bare animated sprite swapped to LitAnimatedSprite2D", String(Maps.SWAPS[&"AnimatedSprite2D"]), _script_path(anim_sprite))
	check_true(c, "animated sprite keeps its SpriteFrames as authored", anim_sprite.sprite_frames != null
			and anim_sprite.sprite_frames.has_animation(&"default") and anim_sprite.sprite_frames.get_frame_count(&"default") == 1
			and anim_sprite.sprite_frames.get_frame_texture(&"default", 0).resource_path == "res://Test/base.png")
	check_true(c, "animated light_mask -> receiver_mask, offset untouched, stamped",
			int(anim_sprite.get("receiver_mask")) == 2 and anim_sprite.offset == Vector2(3, 2) and str(anim_sprite.get("lit_version")) == ver)

	var scripted := root.get_node("ScriptedLight")
	check_true(c, "scripted core light skipped", scripted.get_class() == "PointLight2D" and _script_path(scripted).ends_with("fixture_light_script.gd"))
	var mat_sprite := root.get_node("MatSprite")
	check_true(c, "blend-material sprite left unlit", mat_sprite.get_class() == "Sprite2D" and mat_sprite.get_script() == null and (mat_sprite as Sprite2D).material != null)
	var def_mat := root.get_node("DefaultMatSprite") as Sprite2D
	check_true(c, "default-material sprite converted onto the receiver material", _script_path(def_mat) == String(Maps.SWAPS[&"Sprite2D"])
			and def_mat.material is ShaderMaterial and LitShaderLibrary.flags_of((def_mat.material as ShaderMaterial).shader) >= 0)
	var naked := root.get_node("NakedLight")
	check_true(c, "textureless light converted with Lit's analytic defaults", _script_path(naked) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"])
			and is_equal_approx(float(naked.get("range")), 256.0) and is_equal_approx(float(naked.get("falloff")), 1.0))
	var recv := root.get_node("ReceiverSprite") as Sprite2D
	check_true(c, "already-receiver sprite gains the Lit script, keeps its material, syncs receiver_mask, no double wrap",
			_script_path(recv) == String(Maps.SWAPS[&"Sprite2D"]) and recv.material is ShaderMaterial
			and (recv.material as ShaderMaterial).shader != null
			and (recv.material as ShaderMaterial).shader.resource_path.ends_with("lit_receiver_fast.gdshader")
			and int(recv.get("receiver_mask")) == 4 and recv.texture is CanvasTexture
			and not ((recv.texture as CanvasTexture).diffuse_texture is CanvasTexture))
	var fx_rebased := root.get_node("RebasedFxSprite")
	check_true(c, "rebased custom-material node keeps node, script and custom material, stamped",
			fx_rebased.get_class() == "Sprite2D" and _script_path(fx_rebased).ends_with("fixture_rebase_sprite.gd")
			and (fx_rebased as Sprite2D).material is ShaderMaterial
			and LitShaderLibrary.flags_of(((fx_rebased as Sprite2D).material as ShaderMaterial).shader) < 0
			and str(fx_rebased.get("lit_version")) == ver)
	var unshaded_vfx := root.get_node("UnshadedVfxSprite") as Sprite2D
	check_true(c, "unshaded-shader sprite left unlit", unshaded_vfx.get_script() == null and unshaded_vfx.material is ShaderMaterial)
	var fx_sprite := root.get_node("CustomFxSprite") as Sprite2D
	check_true(c, "custom-material sprite kept as-is (attention section, not auto-migrated)",
			fx_sprite.get_class() == "Sprite2D" and fx_sprite.get_script() == null and fx_sprite.material is ShaderMaterial and fx_sprite.position == Vector2(50, 60))
	var rebased := root.get_node("RebasedSprite")
	check_true(c, "rebased sprite keeps its script, receiver_mask from light_mask, texture wrapped, export preserved",
			_script_path(rebased).ends_with("fixture_rebase_sprite.gd") and rebased.get("receiver_mask") != null
			and int(rebased.get("receiver_mask")) == 4 and rebased.get("texture") is CanvasTexture
			and is_equal_approx(float(rebased.get("speed")), 3.5))
	var anim_rebased := root.get_node("RebasedAnimSprite")
	check_true(c, "rebased animated sprite keeps node and script, gains the receiver material, export preserved, stamped",
			anim_rebased.get_class() == "AnimatedSprite2D" and _script_path(anim_rebased).ends_with("fixture_rebase_anim.gd")
			and anim_rebased.get("receiver_mask") != null and int(anim_rebased.get("receiver_mask")) == 4
			and (anim_rebased as CanvasItem).material is ShaderMaterial
			and LitShaderLibrary.flags_of(((anim_rebased as CanvasItem).material as ShaderMaterial).shader) >= 0
			and is_equal_approx(float(anim_rebased.get("bob")), 2.5) and str(anim_rebased.get("lit_version")) == ver)
	check_true(c, "colliding script not rebased", root.get_node("CollideSprite").get("receiver_mask") == null)
	var mod_node := root.get_node("Modulate")
	check_true(c, "CanvasModulate replaced by LitCanvasModulate with its colour", _script_path(mod_node) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"])
			and mod_node.get_class() == "Node2D" and (mod_node.get("color") as Color).is_equal_approx(Color(0.2, 0.2, 0.3, 1)))
	var occ := root.get_node("Occluder")
	check_true(c, "occluder untouched", occ is LightOccluder2D and (occ as LightOccluder2D).occluder_light_mask == 5)
	var timer := root.get_node("Blocker") as Timer
	check_true(c, "incoming connection rewired", timer.timeout.is_connected(Callable(light, "hide")))
	var watcher := root.get_node("Watcher")
	check_true(c, "outgoing connection rewired", (light as Node2D).visibility_changed.is_connected(Callable(watcher, "_on_light_vis")))
	var named := root.get_node_or_null("Watcher/PointLight2D")
	check_true(c, "class-default-named light keeps its name, converts, keeps %-unique", named != null
			and _script_path(named) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]) and named.unique_name_in_owner)
	var nested := root.get_node_or_null("Watcher/Props/PointLight2D")
	check_true(c, "nested class-default-named light converted under its preserved path", nested != null
			and _script_path(nested) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]))
	var oneline := root.get_node("OnelineTile")
	check_true(c, "one-line class_name script kept, receiver_mask from light_mask, stamped",
			_script_path(oneline).ends_with("fixture_oneline_tile.gd") and oneline.get("receiver_mask") != null
			and int(oneline.get("receiver_mask")) == 8 and str(oneline.get("lit_version")) == ver)
	var child_state := (ResourceLoader.load(OUT + "/fixture_child.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene).get_state()
	check_true(c, "receiver materials stored in the file for rebased and swapped nodes",
			_row_has_prop(child_state, "OnelineTile", "material") and _row_has_prop(child_state, "BareSprite", "material")
			and _row_has_prop(child_state, "BareAnimSprite", "material") and _row_has_prop(child_state, "RebasedAnimSprite", "material"))
	var menu_sprite := root.get_node("Menu/MenuSprite")
	var menu_light := root.get_node("Menu/MenuLight")
	check_true(c, "menu sprite and light under a Control left alone by default", menu_sprite.get_class() == "Sprite2D"
			and menu_sprite.get_script() == null and menu_light.get_class() == "PointLight2D" and menu_light.get_script() == null)
	var existing := root.get_node("ExistingLit")
	check_true(c, "pre-existing Lit node stamped and its data kept", str(existing.get("lit_version")) == ver and is_equal_approx(float(existing.get("energy")), 0.5))
	var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("swing")
	check_true(c, "animation tracks: offset renamed to texture_offset, kept custom sprite and height tracks untouched",
			anim != null and anim.track_get_path(0) == NodePath("Light:texture_offset")
			and anim.track_get_path(1) == NodePath("CustomFxSprite:offset") and anim.track_get_path(2) == NodePath("Light:height"))
	root.free()
	_note("child scene: lights, modulate, sprites, scripts, connections, tracks converted")


func _env() -> void:
	var c := "update_scene_roots"
	var root := _fresh(OUT + "/fixture_env.tscn")
	if check_true(c, "env scene (CanvasModulate root) loads", root != null):
		check_true(c, "root CanvasModulate replaced, keeps its name, colour, stamp, and re-owns its child",
				root.get_class() == "Node2D" and _script_path(root) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"])
				and root.name == "FixtureEnv" and (root.get("color") as Color).is_equal_approx(Color(0.15, 0.12, 0.24, 1))
				and str(root.get("lit_version")) == Migrations.current_version()
				and root.get_node_or_null("Marker") != null and (root.get_node("Marker") as Node2D).position == Vector2(5, 5))
		root.free()
	var bin_root := _fresh(OUT + "/" + BIN_SCENE)
	if check_true(c, "binary .scn scene loads after conversion", bin_root != null):
		check(c, "binary .scn root converted and stays .scn", String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"]), _script_path(bin_root))
		bin_root.free()
	var fx := _fresh(OUT + "/fixture_fx_root.tscn")
	if check_true(c, "fx-root scene loads", fx != null):
		check_true(c, "custom-material root left untouched", fx.get_class() == "Sprite2D" and fx.get_script() == null and (fx as Sprite2D).material is ShaderMaterial)
		fx.free()
	var text := FileAccess.get_file_as_string(OUT + "/fixture_inherited.tscn")
	check_true(c, "inherited scene still inherits its base, base nodes not baked in", "instance=ExtResource" in text and not ("Marker" in text))
	var inh := _fresh(OUT + "/fixture_inherited.tscn")
	if check_true(c, "inherited scene loads", inh != null):
		check_true(c, "inherited root follows its converted base with its colour override, own sprite converted",
				_script_path(inh) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"])
				and (inh.get("color") as Color).is_equal_approx(Color(0.3, 0.1, 0.1, 1))
				and inh.get_node_or_null("OwnSprite") != null and _script_path(inh.get_node("OwnSprite")) == String(Maps.SWAPS[&"Sprite2D"]))
		inh.free()
	_note("scene roots: env, binary .scn, custom-material root, inherited scene")


func _parent() -> void:
	var c := "update_parent_overrides"
	var text := FileAccess.get_file_as_string(OUT + "/fixture_parent.tscn")
	check_true(c, "editable-instance marker survives", "[editable path=\"Child\"]" in text)
	check_true(c, "offset override remapped in place, old one gone", "texture_offset = Vector2(30, 30)" in text and not ("\noffset = Vector2(30, 30)" in text))
	check_true(c, "child nodes not baked into the parent", not ("BareSprite" in text))
	var packed := ResourceLoader.load(OUT + "/fixture_parent.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if not check_true(c, "parent scene loads", packed != null):
		return
	var state := packed.get_state()
	check(c, "parent stores 10 rows (deltas only)", 10, state.get_node_count())
	check_true(c, "env stays an instance, placeholder preserved", _row_is_instance(state, "Env") and "instance_placeholder=" in text)
	var root := packed.instantiate()
	var child_light := root.get_node("Child/Light")
	check_true(c, "remapped and native overrides apply, user-added node survives",
			child_light.get("texture_offset") == Vector2(30, 30) and (child_light.get("color") as Color).is_equal_approx(Color(0, 0, 1, 1))
			and root.get_node_or_null("Child/Extra") != null)
	var sun := root.get_node("Sun")
	check_true(c, "DirectionalLight2D -> LitDirectionalLight2D: max_distance -> shadow_reach, energy, rotation, height default",
			_script_path(sun) == String(Maps.REPLACEMENTS[&"DirectionalLight2D"]["script"])
			and is_equal_approx(float(sun.get("shadow_reach")), 8000.0) and is_equal_approx(float(sun.get("height")), 16.0)
			and is_equal_approx(float(sun.get("energy")), 0.8) and is_equal_approx((sun as Node2D).rotation, 0.5))
	var tiles := root.get_node("Tiles")
	check_true(c, "TileMapLayer swapped, light_mask -> receiver_mask, tile_set survives",
			_script_path(tiles) == String(Maps.SWAPS[&"TileMapLayer"]) and int(tiles.get("receiver_mask")) == 4 and (tiles as TileMapLayer).tile_set != null)
	var hud := root.get_node("MenuBox/HudArt")
	check_true(c, "sprite under an instanced menu scene left alone by default", hud.get_class() == "Sprite2D" and hud.get_script() == null)
	root.free()
	for f in ["fixture_icon.tscn", "fixture_hud_bit.tscn", "fixture_icon_sprite.gd"]:
		var want := FileAccess.get_file_as_string(SRC + "/" + f).replace(SRC + "/", OUT + "/")
		check_true(c, "%s byte-identical (UI-only usage, menus off)" % f, FileAccess.get_file_as_string(OUT + "/" + f) == want)
	var mixed := _fresh(OUT + "/fixture_mixed.tscn")
	if check_true(c, "mixed-usage scene loads", mixed != null):
		check(c, "mixed-usage scene still converts (world use wins)", String(Maps.SWAPS[&"Sprite2D"]), _script_path(mixed))
		mixed.free()
	var preview := _fresh(OUT + "/fixture_preview.tscn")
	if check_true(c, "code-referenced preview scene loads", preview != null):
		check_true(c, "code-referenced scene converts despite menu-only instancing",
				_script_path(preview.get_node("GlowLight")) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"])
				and _script_path(preview.get_node("PreviewArt")) == String(Maps.SWAPS[&"Sprite2D"]))
		preview.free()
	_note("parent scene: overrides remapped, deltas preserved, menu/UI classification")


func _scripts() -> void:
	var c := "update_scripts"
	var rebased := FileAccess.get_file_as_string(OUT + "/fixture_rebase_sprite.gd")
	check_true(c, "rebased root gains @tool and extends LitSprite2D", rebased.begins_with("@tool") and "\nextends LitSprite2D" in rebased)
	var rebased_anim := FileAccess.get_file_as_string(OUT + "/fixture_rebase_anim.gd")
	check_true(c, "rebased animated root gains @tool and extends LitAnimatedSprite2D", rebased_anim.begins_with("@tool") and "\nextends LitAnimatedSprite2D" in rebased_anim)
	var oneline := FileAccess.get_file_as_string(OUT + "/fixture_oneline_tile.gd")
	check_true(c, "one-line class_name form rebased with @tool", oneline.begins_with("@tool") and "class_name FixtureOnelineTile extends LitTileMapLayer" in oneline)
	check_true(c, "colliding script left untouched", FileAccess.get_file_as_string(OUT + "/fixture_collide_sprite.gd").begins_with("extends Sprite2D"))
	check_true(c, "hand-authored Lit-based script gains @tool", FileAccess.get_file_as_string(OUT + "/fixture_lit_light.gd").begins_with("@tool"))
	var watcher := FileAccess.get_file_as_string(OUT + "/fixture_watcher.gd")
	check_true(c, "non-Lit-based script gets no @tool", not watcher.begins_with("@tool"))
	check_true(c, "annotations, constructors, is-checks, returns and casts retyped",
			": LitPointLight2D" in watcher and "LitPointLight2D.new()" in watcher and "is LitCanvasModulate" in watcher
			and "-> LitDirectionalLight2D" in watcher and "as LitDirectionalLight2D" in watcher)
	check_true(c, "string literals and comments left untouched", "\"PointLight2D\"" in watcher and "# A PointLight2D mention in a comment" in watcher)
	check_true(c, "node-path tokens untouched, their annotations retyped",
			"named_child: LitPointLight2D = $PointLight2D" in watcher and "nested_light: LitPointLight2D = $Props/PointLight2D" in watcher
			and "unique_light: LitPointLight2D = %PointLight2D" in watcher)
	check_true(c, "scripted-light extends stays core", FileAccess.get_file_as_string(OUT + "/fixture_light_script.gd").begins_with("extends PointLight2D"))
	_note("scripts: rebased, @tool added, references retyped, collisions skipped")


func _run_result(scan1: Dictionary, run1: Dictionary) -> void:
	var c := "update_report"
	check(c, "seven scenes rewritten", 7, run1["changed_scenes"].size())
	var cnt: Dictionary = scan1["counts"]
	check_true(c, "scan counts lights, modulates, receivers, scripted, rebase roots, materials",
			cnt["point_lights"] == 5 and cnt["directional_lights"] == 1 and cnt["modulates"] == 3
			and cnt["sprites"] == 6 and cnt["animated_sprites"] == 1 and cnt["tilemaps"] == 1
			and cnt["skipped_scripted"] == 1 and cnt["rebase_roots"] == 3 and cnt["unlit_mats"] == 2 and cnt["custom_mats"] == 2)
	check_true(c, "scan counts menu candidates, menu core, menu scripts, retypes, @tool additions",
			cnt["menu_nodes"] == 6 and cnt["menu_core"] == 1 and cnt["menu_scripts"] == 1 and cnt["retype_scripts"] == 1 and cnt["tool_add"] == 4)
	check_true(c, "UI-only chain root classified via usage", scan1["scripts"]["ui_roots"].has(OUT + "/fixture_icon_sprite.gd"))
	check_true(c, "one script retyped, four gained @tool", run1["retyped_scripts"].size() == 1 and run1["tooled_scripts"].size() == 4)
	var joined := "\n".join(run1["report"])
	var missing: Array[String] = []
	for tag in ["SKIPPED-COLLISION", "CLAMPED", "REMAPPED-TRACK", "REMAPPED-OVERRIDE",
			"custom script", "REBASED", "STAMPED", "UNLIT", "MatSprite", "UnshadedVfxSprite",
			"MANUAL custom material", "CustomFxSprite", "Custom Shaders docs page",
			"rendered nothing", "fixture_fx_root", "external animation",
			"inner class", "instance placeholder", "units differ", "RETYPED", "TOOLED",
			"CAUTION", "string literals name core classes", "menu/UI core lights",
			"MENU-SCRIPT", "MENU-SCENE", "converts for world use"]:
		if not (tag in joined):
			missing.append(tag)
	check(c, "report mentions every tag", "all present", "all present" if missing.is_empty() else "missing: " + ", ".join(missing))
	var report_text := FileAccess.get_file_as_string(OUT + "/report.txt")
	check_true(c, "report file leads with a fenced attention section above the per-scene log",
			"NEEDS YOUR ATTENTION" in report_text and "=".repeat(72) in report_text
			and report_text.find("NEEDS YOUR ATTENTION") < report_text.find("--- "))
	check_true(c, "flagged lines carry their scene", "custom script; convert manually  (%s/fixture_child.tscn)" % OUT in report_text)
	_note("report: %d scenes rewritten, attention section written" % run1["changed_scenes"].size())


func _idempotency() -> void:
	var c := "update_idempotency"
	var tracked: Array = FILES.duplicate()
	tracked.append(BIN_SCENE)
	var hashes := {}
	for f in tracked:
		hashes[f] = FileAccess.get_md5(OUT + "/" + f)
	var scan2: Dictionary = Tool.scan([OUT])
	check(c, "already-rebased scripts detected for every-run fixups", 3, scan2["scripts"]["lit_based"].size())
	var run2: Dictionary = Tool.run(scan2, ALL_KINDS, OUT + "/report2.txt")
	check_true(c, "second run rewrites, rebases, tools and retypes nothing",
			run2["changed_scenes"].is_empty() and run2["rebased_scripts"].is_empty()
			and run2["tooled_scripts"].is_empty() and run2["retyped_scripts"].is_empty())
	var same := true
	for f in tracked:
		same = same and FileAccess.get_md5(OUT + "/" + f) == hashes[f]
	check_true(c, "every file byte-identical after the second run", same)
	_note("idempotency: second run is a no-op")


func _menus_on() -> void:
	var c := "update_menus_on"
	_prepare()
	var kinds := ALL_KINDS.duplicate()
	kinds["menus"] = true
	var scan4: Dictionary = Tool.scan([OUT])
	var run4: Dictionary = Tool.run(scan4, kinds, OUT + "/report4.txt")
	var root := _fresh(OUT + "/fixture_child.tscn")
	if check_true(c, "child loads after the menus-on run", root != null):
		check_true(c, "menu sprite and light converted when menus checked",
				_script_path(root.get_node("Menu/MenuSprite")) == String(Maps.SWAPS[&"Sprite2D"])
				and _script_path(root.get_node("Menu/MenuLight")) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]))
		root.free()
	var menu_root := _fresh(OUT + "/fixture_menu.tscn")
	if check_true(c, "menu scene loads after the menus-on run", menu_root != null):
		check(c, "Control-rooted menu scene's art converted", String(Maps.SWAPS[&"Sprite2D"]), _script_path(menu_root.get_node("MenuArt")))
		menu_root.free()
	var parent_root := _fresh(OUT + "/fixture_parent.tscn")
	if check_true(c, "parent loads after the menus-on run", parent_root != null):
		check(c, "sprite under an instanced menu converted", String(Maps.SWAPS[&"Sprite2D"]), _script_path(parent_root.get_node("MenuBox/HudArt")))
		parent_root.free()
	check_true(c, "menu scene rewritten", run4["changed_scenes"].has(OUT + "/fixture_menu.tscn"))
	var icon_script := FileAccess.get_file_as_string(OUT + "/fixture_icon_sprite.gd")
	check_true(c, "menu-only script rebased and retyped", icon_script.begins_with("@tool") and "extends LitSprite2D" in icon_script
			and "linked_light: LitPointLight2D" in icon_script)
	var icon_root := _fresh(OUT + "/fixture_icon.tscn")
	if check_true(c, "icon scene loads after the menus-on run", icon_root != null):
		check_true(c, "usage-classified icon root and child converted",
				(icon_root as Sprite2D).material is ShaderMaterial
				and LitShaderLibrary.flags_of(((icon_root as Sprite2D).material as ShaderMaterial).shader) >= 0
				and _script_path(icon_root.get_node("IconArt")) == String(Maps.SWAPS[&"Sprite2D"]))
		icon_root.free()
	_note("menus on: UI candidates convert")
