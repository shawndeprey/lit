extends SceneTree

## Behavior gate for "Update Project to Lit": copies the Test/.update_tool_bench
## fixtures to a scratch dir, runs the full update rooted there, and asserts every
## conversion contract: property mapping, script rebasing + collision skip, override
## remap with delta preservation, connection/unique-name/occluder survival, animation
## track renames, material classification + CanvasGroup wrapping, and byte-identical
## idempotency on a second run.
## Run: godot --headless --path . --script res://Test/gate_update_tool.gd

const Tool := preload("res://addons/lit/editor/lit_update_tool.gd")
const Maps := preload("res://addons/lit/editor/lit_conversion_maps.gd")
const Migrations := preload("res://addons/lit/editor/lit_migrations.gd")

# The bench folder carries a .gdignore: the editor never imports the fixtures (their
# class_names must not register globally) and the update tool's own project scan
# skips them, so running the tool on this repo never rewrites the fixture sources.
# The dot prefix is load-bearing: the editor never imports the bench (fixture
# class_names must not register globally) and the update tool's own project scan
# skips dot-dirs, so running the tool on this repo never rewrites the fixtures.
const SRC := "res://Test/.update_tool_bench"
const OUT := "res://Test/.update_tool_bench/.out"
const FILES := ["fixture_child.tscn", "fixture_parent.tscn", "fixture_env.tscn",
	"fixture_fx_root.tscn", "fixture_inherited.tscn", "fixture_anim_lib.tres",
	"fixture_rebase_sprite.gd", "fixture_collide_sprite.gd", "fixture_light_script.gd",
	"fixture_watcher.gd", "fixture_oneline_tile.gd", "fixture_lit_light.gd"]
# Built by _prepare from fixture_env; locks binary-scene support and .scn preservation.
const BIN_SCENE := "env_bin.scn"
const ALL_KINDS := {"lights": true, "modulates": true, "sprites": true,
	"tilemaps": true, "scripts": true, "wrap": true}

var _fails := 0


func _initialize() -> void:
	_prepare()
	var scan1: Dictionary = Tool.scan([OUT])
	var run1: Dictionary = Tool.run(scan1, ALL_KINDS, OUT + "/report.txt")
	_gate_child()
	_gate_env()
	_gate_fx_root()
	_gate_inherited()
	_gate_parent()
	_gate_scripts()
	_gate_run_result(scan1, run1)
	_gate_idempotency()
	_gate_wrap_off()
	print("GATE RESULT: " + ("PASS" if _fails == 0 else "FAIL (%d failures)" % _fails))
	if _fails == 0:
		_cleanup()
	else:
		print("  (scratch kept at %s for inspection)" % OUT)
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, label: String) -> bool:
	if not ok:
		_fails += 1
		print("  FAIL: " + label)
	return ok


func _prepare() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(OUT)
	for f in FILES:
		var text := FileAccess.get_file_as_string(SRC + "/" + f)
		var w := FileAccess.open(OUT + "/" + f, FileAccess.WRITE)
		w.store_string(text.replace(SRC + "/", OUT + "/"))
	var env := ResourceLoader.load(OUT + "/fixture_env.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	ResourceSaver.save(env, OUT + "/" + BIN_SCENE)
	print("[prep] fixtures copied to scratch")


func _cleanup() -> void:
	if not DirAccess.dir_exists_absolute(OUT):
		return
	for f in DirAccess.get_files_at(OUT):
		DirAccess.remove_absolute(OUT + "/" + f)
	DirAccess.remove_absolute(OUT)


func _fresh(path: String) -> Node:
	var packed := ResourceLoader.load(path, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	return null if packed == null else packed.instantiate()


func _script_path(node: Node) -> String:
	var s := node.get_script() as Script
	return "" if s == null else s.resource_path


func _row_is_instance(state: SceneState, node_path: String) -> bool:
	for i in state.get_node_count():
		if String(state.get_node_path(i)).trim_prefix("./") == node_path:
			return state.get_node_instance(i) != null
	return false


func _row_has_prop(state: SceneState, node_path: String, prop: String) -> bool:
	for i in state.get_node_count():
		if String(state.get_node_path(i)).trim_prefix("./") == node_path:
			for p in state.get_node_property_count(i):
				if String(state.get_node_property_name(i, p)) == prop:
					return true
	return false


func _gate_child() -> void:
	print("[gate 1] converted child scene")
	var root := _fresh(OUT + "/fixture_child.tscn")
	if not _check(root != null, "child scene loads"):
		return

	var light := root.get_node("Light")
	_check(_script_path(light) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]),
			"light carries the LitPointLight2D script")
	_check(light.get_class() == "Node2D", "light native base is Node2D")
	_check(light.position == Vector2(100, 50), "light transform copied")
	_check((light as Node2D).z_index == 3, "light z_index copied")
	_check(light.is_in_group("torches"), "light persistent group survives")
	_check(light.has_meta("_edit_lock_") and bool(light.get_meta("_edit_lock_")),
			"light metadata (editor lock) survives")
	_check(light.get("texture_offset") == Vector2(4, -6), "offset -> texture_offset")
	_check(int(light.get("shadow_mask")) == 5, "shadow_item_cull_mask -> shadow_mask")
	_check(light.light_mask == 3, "range_item_cull_mask -> light_mask")
	_check(int(light.get("blend_mode")) == 0, "blend_mode MIX clamped to ADD")
	_check((light.get("shadow_color") as Color).is_equal_approx(Color(0.75, 0.5, 0.5, 1)),
			"shadow_color premultiplied toward white")
	_check(is_equal_approx(float(light.get("height")), 16.0), "core height not copied")
	_check(is_equal_approx(float(light.get("energy")), 1.5), "energy copied")
	_check((light.get("color") as Color).is_equal_approx(Color(1, 0.8, 0.6, 1)), "color copied")
	var cookie := light.get("texture") as Texture2D
	_check(cookie != null and cookie.resource_path == "res://Test/base.png", "cookie texture copied")
	var base_tex := load("res://Test/base.png") as Texture2D
	var want_range := maxf(base_tex.get_size().x, base_tex.get_size().y) * 0.5 * 2.0
	_check(is_equal_approx(float(light.get("range")), want_range), "range from cookie footprint")
	_check(is_equal_approx(float(light.get("falloff")), 0.0), "falloff 0 with a cookie")
	_check(bool(light.get("shadow_enabled")), "shadow_enabled copied")
	_check(str(light.get("lit_version")) == Migrations.current_version(), "light stamped")
	_check(light.get("shadow_filter") == null, "shadow_filter dropped")

	var sprite := root.get_node("BareSprite") as Sprite2D
	_check(_script_path(sprite) == String(Maps.SWAPS[&"Sprite2D"]), "bare sprite swapped to LitSprite2D")
	_check(sprite.unique_name_in_owner, "unique name survives")
	_check(sprite.texture is CanvasTexture \
			and (sprite.texture as CanvasTexture).diffuse_texture != null \
			and (sprite.texture as CanvasTexture).diffuse_texture.resource_path == "res://Test/base.png",
			"sprite texture wrapped in CanvasTexture")
	_check(int(sprite.get("receiver_mask")) == 2, "light_mask -> receiver_mask")
	_check(sprite.light_mask == 2, "sprite light_mask untouched")
	_check(sprite.offset == Vector2(10, 5), "Sprite2D offset untouched")
	_check(str(sprite.get("lit_version")) == Migrations.current_version(), "sprite stamped")

	var scripted := root.get_node("ScriptedLight")
	_check(scripted.get_class() == "PointLight2D" \
			and _script_path(scripted).ends_with("fixture_light_script.gd"),
			"scripted core light skipped")
	var mat_sprite := root.get_node("MatSprite")
	_check(mat_sprite.get_class() == "Sprite2D" and mat_sprite.get_script() == null \
			and (mat_sprite as Sprite2D).material != null, "blend-material sprite left unlit")

	var def_mat := root.get_node("DefaultMatSprite") as Sprite2D
	_check(_script_path(def_mat) == String(Maps.SWAPS[&"Sprite2D"]),
			"default-material sprite converted")
	_check(def_mat.material is ShaderMaterial \
			and LitShaderLibrary.flags_of((def_mat.material as ShaderMaterial).shader) >= 0,
			"default material replaced by the receiver material")

	var naked := root.get_node("NakedLight")
	_check(_script_path(naked) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]),
			"textureless light converted")
	_check(is_equal_approx(float(naked.get("range")), 256.0) \
			and is_equal_approx(float(naked.get("falloff")), 1.0),
			"textureless light keeps Lit's analytic defaults")

	var recv := root.get_node("ReceiverSprite") as Sprite2D
	_check(_script_path(recv) == String(Maps.SWAPS[&"Sprite2D"]),
			"already-receiver sprite gains the Lit script")
	_check(recv.material is ShaderMaterial and (recv.material as ShaderMaterial).shader != null \
			and (recv.material as ShaderMaterial).shader.resource_path.ends_with("lit_receiver_fast.gdshader"),
			"already-receiver sprite keeps its material")
	_check(int(recv.get("receiver_mask")) == 4, "receiver_mask export synced from the material")
	_check(recv.texture is CanvasTexture \
			and not ((recv.texture as CanvasTexture).diffuse_texture is CanvasTexture),
			"existing CanvasTexture not double-wrapped")

	var fx_rebased := root.get_node("RebasedFxSprite")
	_check(fx_rebased is CanvasGroup and (fx_rebased as CanvasGroup).material is ShaderMaterial,
			"rebased custom-material node wrapped in a CanvasGroup")
	var fx_rebased_inner := root.get_node_or_null("RebasedFxSprite/RebasedFxSprite")
	if _check(fx_rebased_inner != null, "wrapped rebased node keeps its name one level down"):
		_check(_script_path(fx_rebased_inner).ends_with("fixture_rebase_sprite.gd"),
				"wrapped rebased node keeps its user script")
		_check((fx_rebased_inner as Sprite2D).material is ShaderMaterial \
				and LitShaderLibrary.flags_of(((fx_rebased_inner as Sprite2D).material \
				as ShaderMaterial).shader) >= 0,
				"wrapped rebased node got the receiver material")
		_check(int(fx_rebased_inner.get("receiver_mask")) == 16,
				"wrapped rebased node receiver_mask from light_mask")

	var unshaded_vfx := root.get_node("UnshadedVfxSprite") as Sprite2D
	_check(unshaded_vfx.get_script() == null and unshaded_vfx.material is ShaderMaterial,
			"unshaded-shader sprite left unlit")

	var fx_group := root.get_node("CustomFxSprite")
	_check(fx_group is CanvasGroup, "custom-shader sprite wrapped in a CanvasGroup")
	_check((fx_group as CanvasGroup).material is ShaderMaterial,
			"wrap group carries the custom material")
	_check((fx_group as Node2D).position == Vector2(50, 60), "wrap group takes the transform")
	var fx_sprite := root.get_node_or_null("CustomFxSprite/CustomFxSprite") as Sprite2D
	if _check(fx_sprite != null, "wrapped sprite keeps its name one level down"):
		_check(_script_path(fx_sprite) == String(Maps.SWAPS[&"Sprite2D"]),
				"wrapped sprite became a LitSprite2D")
		_check(fx_sprite.material is ShaderMaterial \
				and LitShaderLibrary.flags_of((fx_sprite.material as ShaderMaterial).shader) >= 0,
				"wrapped sprite carries the receiver material")
		_check(fx_sprite.position == Vector2.ZERO, "wrapped sprite transform moved to the group")
		_check(fx_sprite.texture is CanvasTexture, "wrapped sprite texture wrapped")
		_check(str(fx_sprite.get("lit_version")) == Migrations.current_version(),
				"wrapped sprite stamped")

	var rebased := root.get_node("RebasedSprite")
	_check(_script_path(rebased).ends_with("fixture_rebase_sprite.gd"), "rebased sprite keeps its script")
	_check(rebased.get("receiver_mask") != null and int(rebased.get("receiver_mask")) == 4,
			"rebased sprite receiver_mask from light_mask")
	_check(rebased.get("texture") is CanvasTexture, "rebased sprite texture wrapped")
	_check(is_equal_approx(float(rebased.get("speed")), 3.5), "rebased script export preserved")

	var collide := root.get_node("CollideSprite")
	_check(collide.get("receiver_mask") == null, "colliding script not rebased")

	var modulate := root.get_node("Modulate")
	_check(_script_path(modulate) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"]),
			"modulate carries the LitCanvasModulate script")
	_check(modulate.get_class() == "Node2D", "no native CanvasModulate remains")
	_check((modulate.get("color") as Color).is_equal_approx(Color(0.2, 0.2, 0.3, 1)),
			"modulate color copied")

	var occluder := root.get_node("Occluder")
	_check(occluder is LightOccluder2D and (occluder as LightOccluder2D).occluder_light_mask == 5,
			"occluder untouched")

	var timer := root.get_node("Blocker") as Timer
	_check(timer.timeout.is_connected(Callable(light, "hide")), "incoming connection rewired")
	var watcher := root.get_node("Watcher")
	_check((light as Node2D).visibility_changed.is_connected(Callable(watcher, "_on_light_vis")),
			"outgoing connection rewired")

	var oneline := root.get_node("OnelineTile")
	_check(_script_path(oneline).ends_with("fixture_oneline_tile.gd"),
			"one-line class_name script kept on its node")
	_check(oneline.get("receiver_mask") != null and int(oneline.get("receiver_mask")) == 8,
			"one-line-rebased tilemap receiver_mask from light_mask")
	_check(str(oneline.get("lit_version")) == Migrations.current_version(),
			"one-line-rebased tilemap stamped")
	# STORED, not just live: in-editor, non-@tool scripts get placeholder instances
	# and the Lit _init never runs, so the file itself must carry the material.
	var child_state := (ResourceLoader.load(OUT + "/fixture_child.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene).get_state()
	_check(_row_has_prop(child_state, "OnelineTile", "material"),
			"rebased-script node's receiver material is stored in the file")
	_check(_row_has_prop(child_state, "BareSprite", "material"),
			"bare-swapped sprite's receiver material is stored in the file")

	var existing := root.get_node("ExistingLit")
	_check(str(existing.get("lit_version")) == Migrations.current_version(),
			"pre-existing Lit node stamped")
	_check(is_equal_approx(float(existing.get("energy")), 0.5), "pre-existing Lit node data kept")

	var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("swing")
	_check(anim != null and anim.track_get_path(0) == NodePath("Light:texture_offset"),
			"animation track renamed to texture_offset")
	_check(anim != null and anim.track_get_path(1) == NodePath("CustomFxSprite/CustomFxSprite:offset"),
			"animation track repathed into the wrap group")
	_check(anim != null and anim.track_get_path(2) == NodePath("Light:height"),
			"height track left for the manual note")
	root.free()


func _gate_env() -> void:
	print("[gate 1b] converted scene ROOT (environment-lighting pattern)")
	var root := _fresh(OUT + "/fixture_env.tscn")
	if not _check(root != null, "env scene loads"):
		return
	_check(root.get_class() == "Node2D", "root CanvasModulate replaced")
	_check(_script_path(root) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"]),
			"root carries the LitCanvasModulate script")
	_check(root.name == "FixtureEnv", "root keeps its name")
	_check((root.get("color") as Color).is_equal_approx(Color(0.15, 0.12, 0.24, 1)),
			"root color copied")
	_check(str(root.get("lit_version")) == Migrations.current_version(), "root stamped")
	var marker := root.get_node_or_null("Marker")
	_check(marker != null and (marker as Node2D).position == Vector2(5, 5),
			"root's child re-owned onto the new root")
	root.free()

	var bin_root := _fresh(OUT + "/" + BIN_SCENE)
	if _check(bin_root != null, "binary .scn scene loads after conversion"):
		_check(_script_path(bin_root) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"]),
				"binary .scn root converted and stays .scn")
		bin_root.free()


func _gate_fx_root() -> void:
	print("[gate 1c] custom-material scene root (cannot wrap; pattern menu)")
	var root := _fresh(OUT + "/fixture_fx_root.tscn")
	if not _check(root != null, "fx-root scene loads"):
		return
	_check(root.get_class() == "Sprite2D" and root.get_script() == null \
			and (root as Sprite2D).material is ShaderMaterial,
			"custom-material root left untouched")
	root.free()


func _gate_inherited() -> void:
	print("[gate 1d] inherited scene (base converted first)")
	var text := FileAccess.get_file_as_string(OUT + "/fixture_inherited.tscn")
	_check("instance=ExtResource" in text, "scene still inherits its base")
	_check(not ("Marker" in text), "base nodes not baked into the inherited scene")
	var root := _fresh(OUT + "/fixture_inherited.tscn")
	if not _check(root != null, "inherited scene loads"):
		return
	_check(_script_path(root) == String(Maps.REPLACEMENTS[&"CanvasModulate"]["script"]),
			"inherited root follows its converted base")
	_check((root.get("color") as Color).is_equal_approx(Color(0.3, 0.1, 0.1, 1)),
			"inherited color override still applies")
	var own := root.get_node_or_null("OwnSprite")
	_check(own != null and _script_path(own) == String(Maps.SWAPS[&"Sprite2D"]),
			"own-added sprite in the inherited scene converted")
	root.free()


func _gate_parent() -> void:
	print("[gate 2] parent scene: overrides + delta preservation")
	var text := FileAccess.get_file_as_string(OUT + "/fixture_parent.tscn")
	_check("[editable path=\"Child\"]" in text, "editable-instance marker survives")
	_check("texture_offset = Vector2(30, 30)" in text, "offset override remapped in place")
	_check(not ("\noffset = Vector2(30, 30)" in text), "old offset override gone")
	_check(not ("BareSprite" in text), "child nodes not baked into the parent")

	var packed := ResourceLoader.load(OUT + "/fixture_parent.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if not _check(packed != null, "parent scene loads"):
		return
	var state := packed.get_state()
	_check(state.get_node_count() == 8, "parent stores 8 rows (deltas only), got %d"
			% state.get_node_count())
	_check(_row_is_instance(state, "Env"), "env stays an instance in the parent")
	_check("instance_placeholder=" in text, "instance placeholder preserved")

	var root := packed.instantiate()
	var child_light := root.get_node("Child/Light")
	_check(child_light.get("texture_offset") == Vector2(30, 30), "remapped override applies")
	_check((child_light.get("color") as Color).is_equal_approx(Color(0, 0, 1, 1)),
			"native override still applies")
	_check(root.get_node_or_null("Child/Extra") != null, "user-added node in editable instance survives")

	var sun := root.get_node("Sun")
	_check(_script_path(sun) == String(Maps.REPLACEMENTS[&"DirectionalLight2D"]["script"]),
			"sun carries the LitDirectionalLight2D script")
	_check(is_equal_approx(float(sun.get("shadow_reach")), 8000.0), "max_distance -> shadow_reach")
	_check(is_equal_approx(float(sun.get("height")), 16.0), "core height not copied on sun")
	_check(is_equal_approx(float(sun.get("energy")), 0.8), "sun energy copied")
	_check(is_equal_approx((sun as Node2D).rotation, 0.5), "sun rotation copied")

	var tiles := root.get_node("Tiles")
	_check(_script_path(tiles) == String(Maps.SWAPS[&"TileMapLayer"]), "tilemap swapped")
	_check(int(tiles.get("receiver_mask")) == 4, "tilemap light_mask -> receiver_mask")
	_check((tiles as TileMapLayer).tile_set != null, "tile_set survives")
	root.free()


func _gate_scripts() -> void:
	print("[gate 3] script rebase + @tool + reference retype")
	var rebased := FileAccess.get_file_as_string(OUT + "/fixture_rebase_sprite.gd")
	_check(rebased.begins_with("@tool"), "rebased root gains @tool")
	_check("\nextends LitSprite2D" in rebased, "rebase root extends LitSprite2D")
	var oneline := FileAccess.get_file_as_string(OUT + "/fixture_oneline_tile.gd")
	_check(oneline.begins_with("@tool"), "one-line rebased root gains @tool")
	_check("class_name FixtureOnelineTile extends LitTileMapLayer" in oneline,
			"one-line class_name form rebased")
	var collide := FileAccess.get_file_as_string(OUT + "/fixture_collide_sprite.gd")
	_check(collide.begins_with("extends Sprite2D"), "colliding script left untouched")
	var lit_light := FileAccess.get_file_as_string(OUT + "/fixture_lit_light.gd")
	_check(lit_light.begins_with("@tool"), "hand-authored Lit-based script gains @tool")
	var watcher := FileAccess.get_file_as_string(OUT + "/fixture_watcher.gd")
	_check(not watcher.begins_with("@tool"), "non-Lit-based script gets no @tool")
	_check(": LitPointLight2D" in watcher, "typed annotation retyped")
	_check("LitPointLight2D.new()" in watcher, "constructor call retyped")
	_check("is LitCanvasModulate" in watcher, "is-check retyped")
	_check("-> LitDirectionalLight2D" in watcher, "return annotation retyped")
	_check("as LitDirectionalLight2D" in watcher, "cast retyped")
	_check("\"PointLight2D\"" in watcher, "string literal left untouched")
	_check("# A PointLight2D mention in a comment" in watcher, "comment left untouched")
	var light_script := FileAccess.get_file_as_string(OUT + "/fixture_light_script.gd")
	_check(light_script.begins_with("extends PointLight2D"), "scripted-light extends stays core")


func _gate_run_result(scan1: Dictionary, run1: Dictionary) -> void:
	print("[gate 4] run summary + report markers")
	_check(run1["changed_scenes"].size() == 5, "five scenes rewritten, got %d"
			% run1["changed_scenes"].size())
	var c: Dictionary = scan1["counts"]
	_check(c["point_lights"] == 2 and c["directional_lights"] == 1 and c["modulates"] == 3,
			"scan counts lights + modulates")
	_check(c["sprites"] == 4 and c["tilemaps"] == 1, "scan counts convertible receivers")
	_check(c["skipped_scripted"] == 1, "scan counts the scripted light")
	_check(c["rebase_roots"] == 2, "scan counts both rebase roots (plain + one-line form)")
	_check(c["unlit_mats"] == 2, "scan counts deliberately-unlit materials")
	_check(c["custom_mats"] == 2, "scan counts custom shader materials")
	_check(c["retype_scripts"] == 1, "scan counts the retypable script")
	_check(c["tool_add"] == 3, "scan counts @tool additions (2 rebases + 1 Lit-based)")
	_check(run1["retyped_scripts"].size() == 1, "one script retyped")
	_check(run1["tooled_scripts"].size() == 3, "three scripts gained @tool")
	var joined := "\n".join(run1["report"])
	for marker in ["SKIPPED-COLLISION", "CLAMPED", "REMAPPED-TRACK", "REMAPPED-OVERRIDE",
			"custom script", "REBASED", "STAMPED", "UNLIT", "MatSprite", "UnshadedVfxSprite",
			"WRAPPED", "CustomFxSprite", "premultiplied", "rendered nothing",
			"Pick a pattern per shader", "fixture_fx_root", "external animation",
			"inner class", "instance placeholder", "units differ", "RETYPED", "TOOLED",
			"CAUTION", "string literals name core classes"]:
		_check(marker in joined, "report mentions %s" % marker)


func _gate_idempotency() -> void:
	print("[gate 5] second run is a no-op")
	var tracked: Array = FILES.duplicate()
	tracked.append(BIN_SCENE)
	var hashes := {}
	for f in tracked:
		hashes[f] = FileAccess.get_md5(OUT + "/" + f)
	var scan2: Dictionary = Tool.scan([OUT])
	_check(scan2["scripts"]["lit_based"].size() == 2,
			"already-rebased scripts detected for every-run fixups")
	var run2: Dictionary = Tool.run(scan2, ALL_KINDS, OUT + "/report2.txt")
	_check(run2["changed_scenes"].is_empty(), "no scenes rewritten on the second run: %s"
			% str(run2["changed_scenes"]))
	_check(run2["rebased_scripts"].is_empty(), "no scripts rebased on the second run")
	_check(run2["tooled_scripts"].is_empty(), "no @tool added on the second run")
	_check(run2["retyped_scripts"].is_empty(), "no references retyped on the second run")
	for f in tracked:
		_check(FileAccess.get_md5(OUT + "/" + f) == hashes[f], "%s byte-identical" % f)


func _gate_wrap_off() -> void:
	print("[gate 6] wrap checkbox off: custom materials kept + pattern menu")
	_prepare()
	var kinds := ALL_KINDS.duplicate()
	kinds["wrap"] = false
	var scan3: Dictionary = Tool.scan([OUT])
	var run3: Dictionary = Tool.run(scan3, kinds, OUT + "/report3.txt")
	var root := _fresh(OUT + "/fixture_child.tscn")
	if _check(root != null, "child loads after wrap-off run"):
		var fx := root.get_node("CustomFxSprite")
		_check(fx.get_class() == "Sprite2D" and (fx as Sprite2D).material is ShaderMaterial,
				"custom-material sprite kept unwrapped when unchecked")
		root.free()
	var joined := "\n".join(run3["report"])
	_check(not ("WRAPPED" in joined), "no wrapping when unchecked")
	_check("custom shader materials" in joined and "Pick a pattern per shader" in joined,
			"grouped pattern menu emitted when unchecked")
