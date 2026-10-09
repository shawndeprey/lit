extends SceneTree

## Behavior gate for "Project Migration Tool": copies the Test/.update_tool_bench
## fixtures to a scratch dir, runs the full update rooted there, and asserts every
## conversion contract: property mapping, script rebasing + collision skip, override
## remap with delta preservation, connection/unique-name/occluder survival, animation
## track renames, material classification (custom materials are never auto-migrated;
## they land in the report's attention section), and byte-identical idempotency on a
## second run.
## Run both; the editor-mode run loads user scripts as placeholder instances, the way
## the editor does when the tool is used, and has caught divergence the game-mode run
## cannot (property usage flags, unvalidated placeholder set()):
##   godot --headless --path . --script res://Test/gate_update_tool.gd
##   godot --headless -e --path . --script res://Test/gate_update_tool.gd

const Tool := preload("res://addons/lit/editor/lit_update_tool.gd")
const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")
const Rewriter := preload("res://addons/lit/editor/lit_update_tool/script_rewriter.gd")
const Converter := preload("res://addons/lit/editor/lit_update_tool/scene_converter.gd")

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
	"fixture_menu.tscn", "fixture_icon.tscn", "fixture_hud_bit.tscn", "fixture_mixed.tscn",
	"fixture_preview.tscn",
	"fixture_rebase_sprite.gd", "fixture_collide_sprite.gd", "fixture_light_script.gd",
	"fixture_watcher.gd", "fixture_oneline_tile.gd", "fixture_lit_light.gd",
	"fixture_icon_sprite.gd", "fixture_rebase_anim.gd",
	"fixture_env_ref.tscn", "fixture_env_ref.gd", "fixture_hud_env.gd",
	"fixture_env_ref_parent.tscn", "fixture_env_ref_user.tscn", "fixture_env_ref_user.gd"]
# Built by _prepare from fixture_env; locks binary-scene support and .scn preservation.
const BIN_SCENE := "env_bin.scn"
const ALL_KINDS := {"lights": true, "modulates": true, "sprites": true,
	"animated_sprites": true, "tilemaps": true, "scripts": true}

var _fails := 0


func _initialize() -> void:
	print("[mode] %s" % ("editor (placeholder script instances)" if Engine.is_editor_hint() else "game (real script instances)"))
	_prepare()
	var scan1: Dictionary = Tool.scan([OUT])
	var run1: Dictionary = Tool.run(scan1, ALL_KINDS, OUT + "/report.txt")
	_gate_child()
	_gate_env()
	_gate_fx_root()
	_gate_inherited()
	_gate_parent()
	_gate_ui_shared()
	_gate_scripts()
	_gate_run_result(scan1, run1)
	_gate_idempotency()
	_gate_menus_on()
	_gate_node_refs()
	_gate_scripts_off()
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
	var scripts: Array = []
	for f in FILES:
		var text := FileAccess.get_file_as_string(SRC + "/" + f)
		var w := FileAccess.open(OUT + "/" + f, FileAccess.WRITE)
		w.store_string(text.replace(SRC + "/", OUT + "/"))
		w = null
		if f.ends_with(".gd"):
			scripts.append(OUT + "/" + f)
	# Cached GDScripts keep the source an earlier run rewrote; reset them to disk.
	Rewriter.reload_scripts(scripts)
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


func _row_prop(state: SceneState, node_name: String, prop: String) -> Variant:
	for i in state.get_node_count():
		if String(state.get_node_name(i)) != node_name:
			continue
		for p in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, p)) == prop:
				return state.get_node_property_value(i, p)
	return null


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

	var anim_sprite := root.get_node("BareAnimSprite") as AnimatedSprite2D
	_check(_script_path(anim_sprite) == String(Maps.SWAPS[&"AnimatedSprite2D"]),
			"bare animated sprite swapped to LitAnimatedSprite2D")
	_check(anim_sprite.sprite_frames != null and anim_sprite.sprite_frames.has_animation(&"default") \
			and anim_sprite.sprite_frames.get_frame_count(&"default") == 1,
			"animated sprite keeps its SpriteFrames")
	_check(anim_sprite.sprite_frames != null \
			and anim_sprite.sprite_frames.get_frame_texture(&"default", 0).resource_path == "res://Test/base.png",
			"animated sprite frames left as authored (no CanvasTexture wrap)")
	_check(int(anim_sprite.get("receiver_mask")) == 2, "animated light_mask -> receiver_mask")
	_check(anim_sprite.offset == Vector2(3, 2), "AnimatedSprite2D offset untouched")
	_check(str(anim_sprite.get("lit_version")) == Migrations.current_version(),
			"animated sprite stamped")

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
	_check(fx_rebased.get_class() == "Sprite2D" \
			and _script_path(fx_rebased).ends_with("fixture_rebase_sprite.gd"),
			"rebased custom-material node keeps its node and script")
	_check((fx_rebased as Sprite2D).material is ShaderMaterial \
			and LitShaderLibrary.flags_of(((fx_rebased as Sprite2D).material \
			as ShaderMaterial).shader) < 0,
			"rebased custom-material node keeps its custom material")
	_check(str(fx_rebased.get("lit_version")) == Migrations.current_version(),
			"rebased custom-material node stamped")

	var unshaded_vfx := root.get_node("UnshadedVfxSprite") as Sprite2D
	_check(unshaded_vfx.get_script() == null and unshaded_vfx.material is ShaderMaterial,
			"unshaded-shader sprite left unlit")

	var fx_sprite := root.get_node("CustomFxSprite") as Sprite2D
	_check(fx_sprite.get_class() == "Sprite2D" and fx_sprite.get_script() == null \
			and fx_sprite.material is ShaderMaterial,
			"custom-material sprite kept as-is (attention section, not auto-migrated)")
	_check(fx_sprite.position == Vector2(50, 60), "custom-material sprite untouched")

	var rebased := root.get_node("RebasedSprite")
	_check(_script_path(rebased).ends_with("fixture_rebase_sprite.gd"), "rebased sprite keeps its script")
	_check(rebased.get("receiver_mask") != null and int(rebased.get("receiver_mask")) == 4,
			"rebased sprite receiver_mask from light_mask")
	_check(rebased.get("texture") is CanvasTexture, "rebased sprite texture wrapped")
	_check(is_equal_approx(float(rebased.get("speed")), 3.5), "rebased script export preserved")

	var anim_rebased := root.get_node("RebasedAnimSprite")
	_check(anim_rebased.get_class() == "AnimatedSprite2D" \
			and _script_path(anim_rebased).ends_with("fixture_rebase_anim.gd"),
			"rebased animated sprite keeps its node and script")
	_check(anim_rebased.get("receiver_mask") != null and int(anim_rebased.get("receiver_mask")) == 4,
			"rebased animated sprite receiver_mask from light_mask")
	_check((anim_rebased as CanvasItem).material is ShaderMaterial \
			and LitShaderLibrary.flags_of(((anim_rebased as CanvasItem).material \
			as ShaderMaterial).shader) >= 0,
			"rebased animated sprite gains the receiver material")
	_check(is_equal_approx(float(anim_rebased.get("bob")), 2.5),
			"rebased animated script export preserved")
	_check(str(anim_rebased.get("lit_version")) == Migrations.current_version(),
			"rebased animated sprite stamped")

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

	var named := root.get_node_or_null("Watcher/PointLight2D")
	if _check(named != null, "class-default-named light keeps its name through conversion"):
		_check(_script_path(named) == String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]),
				"class-default-named light converted")
		_check(named.unique_name_in_owner, "class-default-named light keeps %-unique flag")
	var nested := root.get_node_or_null("Watcher/Props/PointLight2D")
	_check(nested != null and _script_path(nested) == String(
			Maps.REPLACEMENTS[&"PointLight2D"]["script"]),
			"nested class-default-named light converted under its preserved path")

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
	_check(_row_has_prop(child_state, "BareAnimSprite", "material"),
			"bare-swapped animated sprite's receiver material is stored in the file")
	_check(_row_has_prop(child_state, "RebasedAnimSprite", "material"),
			"rebased animated sprite's receiver material is stored in the file")

	var menu_sprite := root.get_node("Menu/MenuSprite")
	_check(menu_sprite.get_class() == "Sprite2D" and menu_sprite.get_script() == null,
			"menu sprite under a Control left alone by default")
	var menu_light := root.get_node("Menu/MenuLight")
	_check(menu_light.get_class() == "PointLight2D" and menu_light.get_script() == null,
			"menu light under a Control left alone by default")

	var existing := root.get_node("ExistingLit")
	_check(str(existing.get("lit_version")) == Migrations.current_version(),
			"pre-existing Lit node stamped")
	_check(is_equal_approx(float(existing.get("energy")), 0.5), "pre-existing Lit node data kept")

	var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("swing")
	_check(anim != null and anim.track_get_path(0) == NodePath("Light:texture_offset"),
			"animation track renamed to texture_offset")
	_check(anim != null and anim.track_get_path(1) == NodePath("CustomFxSprite:offset"),
			"track on the kept custom-material sprite untouched")
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
	print("[gate 1c] custom-material scene root (kept; pattern menu)")
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
	_check(state.get_node_count() == 11, "parent stores 11 rows (deltas only), got %d"
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

	var hud := root.get_node("MenuBox/HudArt")
	_check(hud.get_class() == "Sprite2D" and hud.get_script() == null,
			"sprite added under an instanced menu scene left alone by default")
	root.free()


# A scene (or script) with no Control ancestry of its own but whose every instance
# site (or node attachment) is UI must classify as UI: shared icon scenes lit by the
# world was the rpghub regression this pins.
func _gate_ui_shared() -> void:
	print("[gate 2b] shared scenes/scripts used only by menus stay native")
	var untouched := ["fixture_icon.tscn", "fixture_hud_bit.tscn", "fixture_icon_sprite.gd"]
	for f in untouched:
		var want := FileAccess.get_file_as_string(SRC + "/" + f).replace(SRC + "/", OUT + "/")
		_check(FileAccess.get_file_as_string(OUT + "/" + f) == want,
				"%s byte-identical (UI-only usage, menus off)" % f)
	var mixed := _fresh(OUT + "/fixture_mixed.tscn")
	if _check(mixed != null, "mixed-usage scene loads"):
		_check(_script_path(mixed) == String(Maps.SWAPS[&"Sprite2D"]),
				"mixed-usage scene still converts (world use wins)")
		mixed.free()
	# The rpghub player pattern: a world entity whose only scene-data instance is a menu
	# preview, but which code spawns into the world. Code reference = world usage.
	var preview := _fresh(OUT + "/fixture_preview.tscn")
	if _check(preview != null, "code-referenced preview scene loads"):
		_check(_script_path(preview.get_node("GlowLight"))
				== String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]),
				"code-referenced scene's light converts despite menu-only instancing")
		_check(_script_path(preview.get_node("PreviewArt")) == String(Maps.SWAPS[&"Sprite2D"]),
				"code-referenced scene's sprite converts despite menu-only instancing")
		preview.free()


func _gate_scripts() -> void:
	print("[gate 3] script rebase + @tool + reference retype")
	var rebased := FileAccess.get_file_as_string(OUT + "/fixture_rebase_sprite.gd")
	_check(rebased.begins_with("@tool"), "rebased root gains @tool")
	_check("\nextends LitSprite2D" in rebased, "rebase root extends LitSprite2D")
	var rebased_anim := FileAccess.get_file_as_string(OUT + "/fixture_rebase_anim.gd")
	_check(rebased_anim.begins_with("@tool"), "rebased animated root gains @tool")
	_check("\nextends LitAnimatedSprite2D" in rebased_anim,
			"rebase root extends LitAnimatedSprite2D")
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
	# Node-path tokens: default node names equal the class name and conversion keeps
	# names, so $/%%/path tokens must never be retyped - only the annotations beside them.
	_check("named_child: LitPointLight2D = $PointLight2D" in watcher,
			"$-path token untouched, its annotation retyped")
	_check("nested_light: LitPointLight2D = $Props/PointLight2D" in watcher,
			"path-segment token untouched")
	_check("unique_light: LitPointLight2D = %PointLight2D" in watcher,
			"percent-unique token untouched")
	var light_script := FileAccess.get_file_as_string(OUT + "/fixture_light_script.gd")
	_check(light_script.begins_with("extends PointLight2D"), "scripted-light extends stays core")


func _gate_run_result(scan1: Dictionary, run1: Dictionary) -> void:
	print("[gate 4] run summary + report markers")
	_check(run1["changed_scenes"].size() == 9, "nine scenes rewritten, got %d"
			% run1["changed_scenes"].size())
	var c: Dictionary = scan1["counts"]
	_check(c["point_lights"] == 8 and c["directional_lights"] == 2 and c["modulates"] == 4,
			"scan counts lights + modulates")
	_check(c["sprites"] == 6 and c["animated_sprites"] == 1 and c["tilemaps"] == 1,
			"scan counts convertible receivers")
	_check(c["skipped_scripted"] == 2, "scan counts the scripted lights")
	_check(c["rebase_roots"] == 3,
			"scan counts every rebase root (plain + one-line form + animated)")
	_check(c["unlit_mats"] == 2, "scan counts deliberately-unlit materials")
	_check(c["custom_mats"] == 2, "scan counts custom shader materials")
	_check(c["menu_nodes"] == 6, "scan counts menu/UI candidates, got %d" % c["menu_nodes"])
	_check(c["menu_core"] == 1, "scan counts menu core lights/modulates")
	_check(c["menu_scripts"] == 2, "scan counts the menu-only scripts, got %d" % c["menu_scripts"])
	_check(scan1["scripts"]["ui_roots"].has(OUT + "/fixture_icon_sprite.gd"),
			"UI-only chain root classified via usage")
	_check(c["retype_scripts"] == 3, "scan counts the retypable scripts, got %d" % c["retype_scripts"])
	_check(c["tool_add"] == 4, "scan counts @tool additions (3 rebases + 1 Lit-based)")
	_check(run1["retyped_scripts"].size() == 3, "three scripts retyped")
	_check(run1["tooled_scripts"].size() == 4, "four scripts gained @tool")
	var joined := "\n".join(run1["report"])
	for marker in ["SKIPPED-COLLISION", "CLAMPED", "REMAPPED-TRACK", "REMAPPED-OVERRIDE",
			"custom script", "REBASED", "STAMPED", "UNLIT", "MatSprite", "UnshadedVfxSprite",
			"MANUAL custom material", "CustomFxSprite", "Custom Shaders docs page",
			"rendered nothing", "fixture_fx_root", "external animation",
			"inner class", "instance placeholder", "units differ", "RETYPED", "TOOLED", "RELINKED",
			"CAUTION", "string literals name core classes", "menu/UI core lights",
			"MENU-SCRIPT", "MENU-SCENE", "converts for world use"]:
		_check(marker in joined, "report mentions %s" % marker)

	var report_text := FileAccess.get_file_as_string(OUT + "/report.txt")
	_check("NEEDS YOUR ATTENTION" in report_text, "report leads with the attention section")
	_check("=".repeat(72) in report_text, "attention section fenced for copy/paste")
	_check("custom script; convert manually  (%s/fixture_child.tscn)" % OUT in report_text,
			"flagged lines carry their scene so the section is self-contained")
	_check(report_text.find("NEEDS YOUR ATTENTION") < report_text.find("--- "),
			"attention section sits above the per-scene log")


func _gate_idempotency() -> void:
	print("[gate 5] second run is a no-op")
	var tracked: Array = FILES.duplicate()
	tracked.append(BIN_SCENE)
	var hashes := {}
	for f in tracked:
		hashes[f] = FileAccess.get_md5(OUT + "/" + f)
	var scan2: Dictionary = Tool.scan([OUT])
	_check(scan2["scripts"]["lit_based"].size() == 3,
			"already-rebased scripts detected for every-run fixups")
	var run2: Dictionary = Tool.run(scan2, ALL_KINDS, OUT + "/report2.txt")
	_check(run2["changed_scenes"].is_empty(), "no scenes rewritten on the second run: %s"
			% str(run2["changed_scenes"]))
	_check(run2["rebased_scripts"].is_empty(), "no scripts rebased on the second run")
	_check(run2["tooled_scripts"].is_empty(), "no @tool added on the second run")
	_check(run2["retyped_scripts"].is_empty(), "no references retyped on the second run")
	for f in tracked:
		_check(FileAccess.get_md5(OUT + "/" + f) == hashes[f], "%s byte-identical" % f)


func _gate_node_refs() -> void:
	print("[gate 7] @export node references survive conversion")
	_prepare()
	var scan7: Dictionary = Tool.scan([OUT])
	var run7: Dictionary = Tool.run(scan7, ALL_KINDS, OUT + "/report7.txt")
	var joined := "\n".join(run7["report"])
	# Parent scene: an override on an instanced child re-points at a light converted here.
	var parent := _fresh(OUT + "/fixture_env_ref_parent.tscn")
	if _check(parent != null, "env-ref parent scene loads"):
		var holder := parent.get_node("EnvRef/Holder")
		_check(holder.get("lamp") == parent.get_node("ParentLamp"),
				"override reference resolves to the parent's converted light")
		_check(holder.get("env") == parent.get_node("EnvRef/Modulate"),
				"non-overridden reference inside the instance still resolves")
		parent.free()
	# Menu-only script (menus unchecked) keeps its core annotation: the Lit node cannot
	# be re-linked, so the loss must be reported, never silent, and never a wrong node.
	_check("MANUAL ./Hud/EnvReadout: `env: CanvasModulate`" in joined,
			"report flags the un-relinkable menu-script reference")
	_check(not ("RELINKED ./Hud/EnvReadout" in joined),
			"menu-script reference is not re-linked while the annotation stays core")
	# Reverse direction: the annotation was retyped to Lit but the light kept its custom
	# script and stays core; the reference is refused, cleared and reported.
	_check("MANUAL ./Holder: `scripted: LitPointLight2D` pointed at ../ScriptedLamp, now a PointLight2D"
			in joined, "report flags the retyped reference to a core light left scripted")
	_check(joined.count("MANUAL ./Holder") == 1,
			"no other Holder reference is flagged, got %d" % joined.count("MANUAL ./Holder"))
	# A scene with nothing of its own to convert, referencing a node inside an instanced
	# child: processed for the reference pass, left untouched when the annotation accepts.
	var user_packed := ResourceLoader.load(OUT + "/fixture_env_ref_user.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if _check(user_packed != null, "env-ref user scene loads"):
		_check(_row_prop(user_packed.get_state(), "User", "lamp") == NodePath("../EnvRef/Lamp"),
				"cross-instance reference kept in the file")
		var user_root := user_packed.instantiate()
		_check(user_root.get_node("User").get("lamp") == user_root.get_node("EnvRef/Lamp"),
				"cross-instance reference resolves to the converted light")
		user_root.free()
		_check("--- %s/fixture_env_ref_user.tscn\nUNCHANGED" % OUT in joined,
				"cross-instance scene processed and left unchanged")
	# A reference into a load-placeholder instance: intact in the file, never a reason
	# to rewrite the scene (gate 5 locks the second-run side).
	var parent_packed := ResourceLoader.load(OUT + "/fixture_parent.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if _check(parent_packed != null, "parent scene loads for the placeholder reference"):
		_check(_row_prop(parent_packed.get_state(), "GhostWatch", "lamp") == NodePath("../Ghost/Light"),
				"reference into a placeholder instance kept in the file")
		_check(not ("RELINKED ./GhostWatch" in joined),
				"reference into a placeholder instance is not reported as re-linked")
		_check(str(_row_prop(parent_packed.get_state(), "GhostWatch", "lamps")) == str([NodePath("../Ghost/Light")]),
				"array reference into a placeholder instance kept in the file")
		_check(str(_row_prop(parent_packed.get_state(), "GhostWatch", "by_name")) == str({"ghost": NodePath("../Ghost/Light")}),
				"dictionary reference into a placeholder instance kept in the file")
	# Annotation parser: comma-separated class lists, native and global class names.
	var lit_light := Node2D.new()
	lit_light.set_script(load(String(Maps.REPLACEMENTS[&"PointLight2D"]["script"])))
	_check(Converter._annotation_accepts("Node2D", lit_light), "native base accepts the Lit node")
	_check(not Converter._annotation_accepts("PointLight2D", lit_light), "core class refuses the Lit node")
	_check(Converter._annotation_accepts("LitPointLight2D", lit_light), "global class name accepts the Lit node")
	_check(not Converter._annotation_accepts("LitCanvasModulate", lit_light), "other Lit class refuses the Lit node")
	_check(Converter._annotation_accepts("Control, LitPointLight2D", lit_light), "any listed class accepts")
	_check(not Converter._annotation_accepts("Control,Node3D", lit_light), "no listed class refuses")
	_check(Converter._annotation_accepts("", lit_light), "empty annotation accepts")
	lit_light.free()
	var script := FileAccess.get_file_as_string(OUT + "/fixture_env_ref.gd")
	_check("@export var env: LitCanvasModulate" in script, "modulate export annotation retyped")
	_check("@export var lamp: LitPointLight2D" in script, "light export annotation retyped")
	_check("@export var sun: LitDirectionalLight2D" in script,
			"directional export annotation retyped")
	_check("Array[LitPointLight2D]" in script, "typed array element retyped")
	_check("Dictionary[String, LitPointLight2D]" in script, "typed dictionary value retyped")
	_check("Dictionary[LitCanvasModulate, int]" in script, "typed dictionary key retyped")
	var packed := ResourceLoader.load(OUT + "/fixture_env_ref.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if not _check(packed != null, "env-ref scene loads"):
		return
	var stored := {}
	var state := packed.get_state()
	for i in state.get_node_count():
		if String(state.get_node_name(i)) != "Holder":
			continue
		for p in state.get_node_property_count(i):
			stored[String(state.get_node_property_name(i, p))] = state.get_node_property_value(i, p)
	_check(stored.get("env_path") == NodePath("../Modulate"), "plain NodePath export untouched")
	_check(stored.get("env") == NodePath("../Modulate"),
			"stored env reference still points at the modulate, got %s" % str(stored.get("env")))
	_check(stored.get("lamp") == NodePath("../Lamp"),
			"stored lamp reference still points at the light, got %s" % str(stored.get("lamp")))
	_check(stored.get("sun") == NodePath("../Sun"),
			"stored sun reference still points at the directional, got %s" % str(stored.get("sun")))
	_check(str(stored.get("lamps")) == str([NodePath("../Lamp"), NodePath("../Lamp2")]),
			"stored typed array still lists both lights, got %s" % str(stored.get("lamps")))
	_check(stored.get("any_node") == NodePath("../Lamp2"),
			"stored untyped Node export still points at the light, got %s" % str(stored.get("any_node")))
	_check(str(stored.get("by_name")) == str({"main": NodePath("../Lamp"), "side": NodePath("../Lamp2")}),
			"stored typed dictionary values still list both lights, got %s" % str(stored.get("by_name")))
	_check(str(stored.get("keyed")) == str({NodePath("../Modulate"): 1}),
			"stored typed dictionary key still names the modulate, got %s" % str(stored.get("keyed")))
	_check(not stored.has("scripted"), "refused reference to the scripted core light cleared, got %s"
			% str(stored.get("scripted")))
	var root := packed.instantiate()
	var holder := root.get_node("Holder")
	_check(holder.get("env") == root.get_node("Modulate"), "live env resolves to the Lit modulate")
	_check(holder.get("lamp") == root.get_node("Lamp"), "live lamp resolves to the Lit light")
	_check(holder.get("sun") == root.get_node("Sun"), "live sun resolves to the Lit directional")
	var lamps: Array = holder.get("lamps")
	_check(lamps.size() == 2 and lamps[0] == root.get_node("Lamp") and lamps[1] == root.get_node("Lamp2"),
			"live typed array resolves to both Lit lights")
	var by_name: Dictionary = holder.get("by_name")
	_check(by_name.size() == 2 and by_name.get("main") == root.get_node("Lamp") \
			and by_name.get("side") == root.get_node("Lamp2"),
			"live typed dictionary values resolve to both Lit lights")
	var keyed: Dictionary = holder.get("keyed")
	_check(keyed.size() == 1 and keyed.has(root.get_node("Modulate")) \
			and keyed[root.get_node("Modulate")] == 1,
			"live typed dictionary key resolves to the Lit modulate")
	root.free()


func _gate_menus_on() -> void:
	print("[gate 6] menus checkbox on: UI candidates convert")
	_prepare()
	var kinds := ALL_KINDS.duplicate()
	kinds["menus"] = true
	var scan4: Dictionary = Tool.scan([OUT])
	var run4: Dictionary = Tool.run(scan4, kinds, OUT + "/report4.txt")
	var root := _fresh(OUT + "/fixture_child.tscn")
	if _check(root != null, "child loads after menus-on run"):
		_check(_script_path(root.get_node("Menu/MenuSprite")) == String(Maps.SWAPS[&"Sprite2D"]),
				"menu sprite converted when menus checked")
		_check(_script_path(root.get_node("Menu/MenuLight"))
				== String(Maps.REPLACEMENTS[&"PointLight2D"]["script"]),
				"menu light converted when menus checked")
		root.free()
	var menu_root := _fresh(OUT + "/fixture_menu.tscn")
	if _check(menu_root != null, "menu scene loads after menus-on run"):
		_check(_script_path(menu_root.get_node("MenuArt")) == String(Maps.SWAPS[&"Sprite2D"]),
				"Control-rooted menu scene's art converted when menus checked")
		menu_root.free()
	var parent_root := _fresh(OUT + "/fixture_parent.tscn")
	if _check(parent_root != null, "parent loads after menus-on run"):
		_check(_script_path(parent_root.get_node("MenuBox/HudArt")) == String(Maps.SWAPS[&"Sprite2D"]),
				"sprite under an instanced menu converted when menus checked")
		parent_root.free()
	_check(run4["changed_scenes"].has(OUT + "/fixture_menu.tscn"),
			"menu scene rewritten when menus checked")
	var icon_script := FileAccess.get_file_as_string(OUT + "/fixture_icon_sprite.gd")
	_check(icon_script.begins_with("@tool") and "extends LitSprite2D" in icon_script,
			"menu-only script rebased when menus checked")
	_check("linked_light: LitPointLight2D" in icon_script,
			"menu-only script references retyped when menus checked")
	var icon_root := _fresh(OUT + "/fixture_icon.tscn")
	if _check(icon_root != null, "icon scene loads after menus-on run"):
		_check((icon_root as Sprite2D).material is ShaderMaterial \
				and LitShaderLibrary.flags_of(((icon_root as Sprite2D).material \
				as ShaderMaterial).shader) >= 0,
				"usage-classified icon root gains the receiver material when menus checked")
		_check(_script_path(icon_root.get_node("IconArt")) == String(Maps.SWAPS[&"Sprite2D"]),
				"usage-classified icon child converted when menus checked")
		icon_root.free()
	var hud_script := FileAccess.get_file_as_string(OUT + "/fixture_hud_env.gd")
	_check("@export var env: LitCanvasModulate" in hud_script,
			"menu-only HUD script retyped when menus checked")
	var env_root := _fresh(OUT + "/fixture_env_ref.tscn")
	if _check(env_root != null, "env-ref scene loads after menus-on run"):
		var readout := env_root.get_node("Hud/EnvReadout")
		_check(readout.get("env") == env_root.get_node("Modulate"),
				"retyped menu-script reference re-links to the Lit modulate when menus checked")
		_check(readout.get("lamp") == env_root.get_node("Lamp"),
				"retyped menu-script reference re-links to the Lit light when menus checked")
		env_root.free()


# Scripts unchecked: annotations stay core and refuse the Lit nodes, so every exported
# reference to a converted node must be reported and cleared - never left pointing at
# whatever node reused the freed slot.
func _gate_scripts_off() -> void:
	print("[gate 8] scripts checkbox off: references are reported, never dangling")
	_prepare()
	var kinds := ALL_KINDS.duplicate()
	kinds["scripts"] = false
	var scan5: Dictionary = Tool.scan([OUT])
	var run5: Dictionary = Tool.run(scan5, kinds, OUT + "/report5.txt")
	var joined := "\n".join(run5["report"])
	var script := FileAccess.get_file_as_string(OUT + "/fixture_env_ref.gd")
	_check("@export var env: CanvasModulate" in script, "script left on core types")
	for prop in ["env", "lamp", "sun"]:
		_check("MANUAL ./Holder: `%s: " % prop in joined, "report flags `%s` as un-relinkable" % prop)
	_check("MANUAL ./Holder: `lamps` (Array[PointLight2D]) pointed at ../Lamp, now a LitPointLight2D"
			in joined, "report flags the typed array elements")
	_check("MANUAL ./Holder: `by_name[main]` (Dictionary[..., PointLight2D]) pointed at ../Lamp"
			in joined, "report flags the typed dictionary value")
	_check("MANUAL ./Holder: `keyed` key (Dictionary[CanvasModulate, ...], value 1) pointed at ../Modulate"
			in joined, "report flags the typed dictionary key with its value")
	_check(not ("MANUAL ./Holder: `scripted" in joined),
			"core-typed reference to the core scripted light is not flagged")
	_check("MANUAL ./User: `lamp: PointLight2D` pointed at ../EnvRef/Lamp, now a LitPointLight2D" in joined,
			"report flags the core-typed cross-instance reference")
	var user_packed := ResourceLoader.load(OUT + "/fixture_env_ref_user.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if _check(user_packed != null, "env-ref user scene loads after scripts-off run"):
		_check(_row_prop(user_packed.get_state(), "User", "lamp") == null,
				"cross-instance reference cleared rather than dangling, got %s"
				% str(_row_prop(user_packed.get_state(), "User", "lamp")))
	_check(not ("RELINKED ./Holder: `env`" in joined), "core-typed env not re-linked")
	var packed := ResourceLoader.load(OUT + "/fixture_env_ref.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if not _check(packed != null, "env-ref scene loads after scripts-off run"):
		return
	var stored := {}
	var state := packed.get_state()
	for i in state.get_node_count():
		if String(state.get_node_name(i)) != "Holder":
			continue
		for p in state.get_node_property_count(i):
			stored[String(state.get_node_property_name(i, p))] = state.get_node_property_value(i, p)
	# Cleared references equal the null default, so pack omits them: absence is the contract.
	for name in ["env", "lamp", "sun"]:
		_check(not stored.has(name), "stored `%s` cleared rather than dangling, got %s"
				% [name, str(stored.get(name))])
	_check(stored.get("scripted") == NodePath("../ScriptedLamp"),
			"core-typed reference to the core scripted light kept, got %s" % str(stored.get("scripted")))
	_check(stored.get("any_node") == NodePath("../Lamp2"),
			"untyped Node export re-linked, got %s" % str(stored.get("any_node")))
	_check(stored.get("env_path") == NodePath("../Modulate"), "plain NodePath export untouched")
	var lamps: Variant = stored.get("lamps")
	_check(lamps is Array and lamps.size() == 2 and lamps[0] == null and lamps[1] == null,
			"stored `lamps` elements cleared rather than dangling, got %s" % str(lamps))
	var by_name: Variant = stored.get("by_name")
	_check(by_name is Dictionary and by_name.size() == 2 and by_name.get("main") == null \
			and by_name.get("side") == null,
			"stored `by_name` keeps its keys with cleared values, got %s" % str(by_name))
	_check(not stored.has("keyed") or (stored["keyed"] is Dictionary and stored["keyed"].is_empty()),
			"stored `keyed` drops the un-relinkable key, got %s" % str(stored.get("keyed")))
	var root := packed.instantiate()
	_check(root.get_node("Holder").get("any_node") == root.get_node("Lamp2"),
			"untyped Node export resolves live after scripts-off run")
	root.free()
