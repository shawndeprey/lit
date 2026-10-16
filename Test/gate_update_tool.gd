extends SceneTree

## Behavior gate for "Update Project to Lit": copies the Test/.update_tool_bench fixtures
## to a scratch dir and runs the update rooted there against synthetic migrations
## (fixture_*_migration.gd), asserting the safe-update contract: Lit nodes migrated
## through their chain (two-step renames included) and stamped, renamed properties
## re-applied from instance overrides (editable, nested, placeholder, inherited root)
## and embedded animation tracks, external animations reported, scenes skipped whole
## when saving would lose data (a node stamped newer than the plugin, a stored value
## no property or migration accounts for), and above all every script byte-identical
## and every node's type and script unchanged. Then a byte-identical second run, and
## a run on the registered chain.
## Run both; the editor-mode run loads user scripts as placeholder instances:
##   godot --headless --path . --script res://Test/gate_update_tool.gd
##   godot --headless -e --path . --script res://Test/gate_update_tool.gd

const Tool := preload("res://addons/lit/editor/lit_update_tool.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")

const SRC := "res://Test/.update_tool_bench"
const OUT := "res://Test/.update_tool_bench/.out"
const FILES := ["fixture_level.tscn", "fixture_parent.tscn", "fixture_lamp.tscn",
	"fixture_inherited.tscn", "fixture_newer.tscn", "fixture_current.tscn", "fixture_stale.tscn",
	"fixture_outer.tscn", "fixture_newer_user.tscn", "fixture_plain.tscn",
	"fixture_anim_lib.tres", "fixture_user_light.gd", "fixture_user_light2.gd",
	"fixture_user_sprite.gd", "fixture_watcher.gd"]
# Built by _prepare from fixture_lamp; locks binary-scene support.
const BIN_SCENE := "lamp_bin.scn"
const UNTOUCHED := ["fixture_user_light.gd", "fixture_user_light2.gd", "fixture_user_sprite.gd",
	"fixture_watcher.gd", "fixture_anim_lib.tres", "fixture_newer.tscn", "fixture_current.tscn",
	"fixture_newer_user.tscn"]
const MIGRATION_FILES := ["fixture_spot_a_migration.gd", "fixture_light_migration.gd",
	"fixture_sprite_migration.gd", "fixture_spot_b_migration.gd"]

var _fails := 0
var _rows_before := {}
var _hashes := {}


func _initialize() -> void:
	print("[mode] %s" % ("editor (placeholder script instances)" if Engine.is_editor_hint() else "game (real script instances)"))
	var migs := _migrations()
	_prepare()
	var scan1: Dictionary = Tool.scan([OUT], migs)
	_gate_scan(scan1)
	var run1: Dictionary = Tool.run(scan1, OUT + "/report.txt", migs)
	_gate_level()
	_gate_parent()
	_gate_roots()
	_gate_untouched("after the update", UNTOUCHED)
	_gate_run_result(scan1, run1)
	_gate_idempotency(migs)
	_gate_registered_chain()
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


func _migrations() -> Array:
	var out := []
	for f in MIGRATION_FILES:
		out.append((load(SRC + "/" + f) as GDScript).new())
	return out


func _expected(f: String) -> String:
	return FileAccess.get_file_as_string(SRC + "/" + f).replace(SRC + "/", OUT + "/") \
			.replace("__CURRENT__", Migrations.current_version())


func _scenes() -> Array:
	var out := []
	for f in FILES:
		if f.ends_with(".tscn"):
			out.append(f)
	out.append(BIN_SCENE)
	return out


func _prepare() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(OUT)
	for f in FILES:
		var w := FileAccess.open(OUT + "/" + f, FileAccess.WRITE)
		w.store_string(_expected(f))
		w = null
	var lamp := ResourceLoader.load(OUT + "/fixture_lamp.tscn", "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	ResourceSaver.save(lamp, OUT + "/" + BIN_SCENE)
	_rows_before.clear()
	_hashes.clear()
	for f in _scenes():
		_rows_before[f] = _rows(OUT + "/" + f)
	for f in FILES:
		_hashes[f] = FileAccess.get_md5(OUT + "/" + f)
	_hashes[BIN_SCENE] = FileAccess.get_md5(OUT + "/" + BIN_SCENE)
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


func _state(path: String) -> SceneState:
	var packed := ResourceLoader.load(path, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	return null if packed == null else packed.get_state()


## {node path: "type|script|instance"} - the identity of every row, from the file.
func _rows(path: String) -> Dictionary:
	var out := {}
	var state := _state(path)
	if state == null:
		return out
	for i in state.get_node_count():
		var script_path := ""
		for p in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, p)) == "script":
				var s = state.get_node_property_value(i, p)
				script_path = (s as Script).resource_path if s is Script else "<non-script>"
		var inst := state.get_node_instance(i)
		var inst_path := inst.resource_path if inst != null else state.get_node_instance_placeholder(i)
		out[String(state.get_node_path(i))] = "%s|%s|%s" % [state.get_node_type(i), script_path, inst_path]
	return out


func _row_prop(state: SceneState, node_name: String, prop: String) -> Variant:
	for i in state.get_node_count():
		if String(state.get_node_name(i)) != node_name:
			continue
		for p in state.get_node_property_count(i):
			if String(state.get_node_property_name(i, p)) == prop:
				return state.get_node_property_value(i, p)
	return null


func _script_path(node: Node) -> String:
	var s := node.get_script() as Script
	return "" if s == null else s.resource_path


func _unchanged(f: String, label: String) -> void:
	_check(FileAccess.get_md5(OUT + "/" + f) == _hashes[f], "%s byte-identical %s" % [f, label])


func _gate_scan(scan: Dictionary) -> void:
	print("[gate 1] scan counts")
	var c: Dictionary = scan["counts"]
	_check(c["scenes"] == 11, "eleven scenes scanned, got %d" % c["scenes"])
	_check(c["lit_nodes"] == 16, "sixteen Lit nodes on older versions (skipped scene excluded), got %d" % c["lit_nodes"])
	_check(c["lit_current"] == 2, "two Lit nodes already current, got %d" % c["lit_current"])
	_check(c["newer"] == 1, "one node stamped newer than the plugin, got %d" % c["newer"])
	_check(c["core_nodes"] == 2, "two unscripted core nodes counted for the port hint, got %d" % c["core_nodes"])
	_check(c["override_rows"] == 7, "seven instance overrides store names their Lit class retires, got %d" % c["override_rows"])
	_check(c["track_rows"] == 3, "three animation mixers drive retired names on Lit nodes, got %d" % c["track_rows"])
	_check(c["scenes_to_process"] == 9, "nine scenes to process, got %d" % c["scenes_to_process"])
	_check(c["scenes_skipped"] == 1, "one scene skipped for newer data, got %d" % c["scenes_skipped"])
	_check(Tool.lit_class_of(scan, OUT + "/fixture_user_light.gd") == &"LitPointLight2D",
			"user script extending a Lit class resolves to that class")
	_check(Tool.lit_class_of(scan, OUT + "/fixture_user_light2.gd") == &"LitPointLight2D",
			"user script two levels below a Lit class resolves to that class")
	_check(Tool.lit_class_of(scan, OUT + "/fixture_user_sprite.gd") == &"",
			"user script extending a core class resolves to no Lit class")
	_check(Tool.lit_class_of(scan, "res://addons/lit/nodes/lit_precompile_overlay.gd") == &"",
			"an unversioned Lit class (no lit_version) is not an update target")
	var order: Array = scan["order"]
	_check(order.find(OUT + "/fixture_level.tscn") < order.find(OUT + "/fixture_parent.tscn")
			and order.find(OUT + "/fixture_parent.tscn") < order.find(OUT + "/fixture_outer.tscn")
			and order.find(OUT + "/fixture_lamp.tscn") < order.find(OUT + "/fixture_inherited.tscn"),
			"instanced scenes order before the scenes that instance them")


func _gate_level() -> void:
	print("[gate 2] Lit nodes migrated and stamped, everything else untouched")
	var ver := Migrations.current_version()
	var text := FileAccess.get_file_as_string(OUT + "/fixture_level.tscn")
	for retired in ["legacy_glow", "legacy_mask", "legacy_emit", "old_cone", "mid_cone"]:
		_check(not (retired in text), "retired name `%s` gone from the level file" % retired)
	var root := _fresh(OUT + "/fixture_level.tscn")
	if not _check(root != null, "level scene loads"):
		return
	var lamp := root.get_node("Lamp")
	_check(is_equal_approx(float(lamp.get("energy")), 2.5), "legacy_glow -> energy on the point light")
	_check(str(lamp.get("lit_version")) == ver, "point light stamped")
	_check(lamp.unique_name_in_owner and lamp.is_in_group("torches") and lamp.position == Vector2(100, 50)
			and int(lamp.get("range_z_max")) == 7 and (lamp.get("color") as Color).is_equal_approx(Color(1, 0.8, 0.6, 1)),
			"point light keeps unique name, group, transform and authored data")
	var sun := root.get_node("Sun")
	_check(str(sun.get("lit_version")) == ver and is_equal_approx(float(sun.get("energy")), 0.8),
			"directional light stamped from 1.1.3 with its data kept")
	var spot := root.get_node("Spot")
	_check(is_equal_approx(float(spot.get("spot_angle")), 45.0), "two-step rename old_cone -> mid_cone -> spot_angle lands on spot_angle")
	_check(str(spot.get("lit_version")) == ver, "spot light stamped from 1.1.3")
	var spot2 := root.get_node("Spot2")
	_check(is_equal_approx(float(spot2.get("spot_angle")), 50.0), "1.1.4 spot light only runs the second rename")
	_check(str(spot2.get("lit_version")) == ver, "spot light stamped from 1.1.4")
	var env := root.get_node("Env")
	_check(str(env.get("lit_version")) == ver and (env.get("color") as Color).is_equal_approx(Color(0.2, 0.2, 0.3, 1)),
			"already-current modulate untouched")
	var hero := root.get_node("Hero")
	_check(hero.get_class() == "Sprite2D" and _script_path(hero) == "res://addons/lit/nodes/lit_sprite_2d.gd",
			"LitSprite2D keeps its node type and script")
	_check(int(hero.get("receiver_mask")) == 4, "legacy_mask -> receiver_mask on the sprite")
	_check(is_equal_approx(float(hero.get("emissive_strength")), 0.25), "apply() moved legacy_emit into emissive_strength")
	_check(str(hero.get("lit_version")) == ver, "sprite stamped")
	var tiles := root.get_node("Tiles")
	_check(str(tiles.get("lit_version")) == ver and int(tiles.get("receiver_mask")) == 8
			and (tiles as TileMapLayer).tile_set != null, "tilemap stamped from a legacy metadata stamp, data and tile_set kept")
	_check(str(root.get_node("Walker").get("lit_version")) == ver, "animated sprite stamped")
	_check(str(root.get_node("Post").get("lit_version")) == ver
			and str(root.get_node("Post/Vignette").get("lit_version")) == ver, "post-process host and effect stamped")
	_check(root.get_node("Overlay").get("lit_version") == null and root.get_node("Overlay") is CanvasLayer,
			"unversioned overlay left alone")
	var scripted := root.get_node("Scripted")
	_check(_script_path(scripted).ends_with("fixture_user_light.gd"), "user script extending a Lit class stays attached")
	_check(is_equal_approx(float(scripted.get("energy")), 3.5), "legacy_glow -> energy through the user subclass")
	_check(is_equal_approx(float(scripted.get("intensity")), 2.0), "user script export preserved")
	_check(str(scripted.get("lit_version")) == ver, "user-subclassed Lit node stamped")
	var scripted2 := root.get_node("Scripted2")
	_check(_script_path(scripted2).ends_with("fixture_user_light2.gd") and is_equal_approx(float(scripted2.get("energy")), 4.5)
			and str(scripted2.get("lit_version")) == ver, "two-level user subclass migrated and stamped")
	var legacy := root.get_node("Legacy")
	_check(legacy.get_class() == "Sprite2D" and _script_path(legacy).ends_with("fixture_user_sprite.gd")
			and is_equal_approx(float(legacy.get("speed")), 3.0) and legacy.get("lit_version") == null,
			"core-extending user script node left exactly as authored")
	var core_light := root.get_node("CoreLight")
	_check(core_light.get_class() == "PointLight2D" and core_light.get_script() == null
			and is_equal_approx((core_light as PointLight2D).energy, 0.7), "core light left native")
	var core_sprite := root.get_node("CoreSprite")
	_check(core_sprite.get_class() == "Sprite2D" and core_sprite.get_script() == null
			and (core_sprite as Sprite2D).light_mask == 2, "core sprite left native")
	_check(root.get_node("Occluder") is LightOccluder2D, "occluder untouched")
	_check(root.get_node("Watcher").get("lamp") == core_light, "exported core reference still resolves")
	_check((root.get_node("Blocker") as Timer).timeout.is_connected(Callable(lamp, "hide")),
			"persisted connection survives")
	var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("swing")
	if _check(anim != null, "embedded animation present"):
		_check(anim.track_get_path(0) == NodePath("Lamp:energy"), "track to legacy_glow renamed to energy")
		_check(anim.track_get_path(1) == NodePath("Lamp:color"), "track to a live property untouched")
		_check(anim.track_get_path(2) == NodePath("Hero:receiver_mask"), "sprite track renamed to receiver_mask")
		_check(anim.track_get_path(3) == NodePath("CoreLight:energy"), "track to a core node untouched")
		_check(anim.track_get_path(4) == NodePath("Spot:spot_angle"), "two-step rename carried onto the track")
	var ext := (root.get_node("Anim") as AnimationPlayer).get_animation("ext/ext_swing")
	_check(ext != null and ext.track_get_path(0) == NodePath("Lamp:legacy_glow"),
			"external animation track left as authored")
	var tree := (root.get_node("Tree") as AnimationTree).get_animation("tree_swing")
	_check(tree != null and tree.track_get_path(0) == NodePath("Lamp:energy"), "AnimationTree track follows the rename")
	root.free()


func _gate_parent() -> void:
	print("[gate 3] instance overrides and parent-scene tracks follow renames")
	var ver := Migrations.current_version()
	var text := FileAccess.get_file_as_string(OUT + "/fixture_parent.tscn")
	_check("[editable path=\"Level\"]" in text, "editable-instance marker survives")
	_check("energy = 4.0" in text and not ("legacy_glow = 4.0" in text), "editable override re-applied under the live name")
	_check("color = Color(0, 0, 1, 1)" in text, "native override kept")
	_check("energy = 9.0" in text and not ("legacy_glow = 9.0" in text), "placeholder override re-applied under the live name")
	_check("instance_placeholder=\"%s/fixture_lamp.tscn\"" % OUT in text, "placeholder stays a placeholder")
	_check("energy = 5.5" in text and not ("legacy_glow = 5.5" in text), "Lit-rooted instance's root override re-applied")
	_check("shadow_filter = 2" in text, "core node override keeps a name only a Lit class retires")
	_check(not ("Hero" in text), "instanced scene's nodes not baked into the parent")
	var state := _state(OUT + "/fixture_parent.tscn")
	if _check(state != null, "parent scene loads"):
		_check(state.get_node_count() == _rows_before["fixture_parent.tscn"].size(),
				"parent stores the same rows (deltas only), got %d" % state.get_node_count())
		_check(_row_prop(state, "Lamp", "energy") == 4.0, "stored override energy = 4.0")
		_check(_row_prop(state, "Ghost", "energy") == 9.0, "stored placeholder override energy = 9.0")
		_check(_row_prop(state, "Lantern", "energy") == 5.5, "stored instance-root override energy = 5.5")
	var root := _fresh(OUT + "/fixture_parent.tscn")
	if not _check(root != null, "parent scene instantiates"):
		return
	var lamp := root.get_node("Level/Lamp")
	_check(is_equal_approx(float(lamp.get("energy")), 4.0), "override wins over the child's migrated value")
	_check((lamp.get("color") as Color).is_equal_approx(Color(0, 0, 1, 1)), "native override applies")
	_check(is_equal_approx(float(root.get_node("Level/Sun").get("energy")), 0.3), "same-name override applies")
	_check(root.get_node_or_null("Level/Extra") != null, "user-added node in the editable instance survives")
	var core := root.get_node("Level/CoreLight")
	_check(core.get_class() == "PointLight2D" and (core as PointLight2D).shadow_filter == 2, "core override applies natively")
	var torch := root.get_node("Torch")
	_check(str(torch.get("lit_version")) == ver and is_equal_approx(float(torch.get("energy")), 0.6),
			"parent's own Lit node stamped with its data kept")
	var lantern := root.get_node("Lantern")
	_check(is_equal_approx(float(lantern.get("energy")), 5.5) and str(lantern.get("lit_version")) == ver,
			"instance-root override wins, root stamped through its scene")
	var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("walk")
	_check(anim != null and anim.track_get_path(0) == NodePath("Lamp:energy"),
			"parent track through a non-root root_node into the instanced child follows the rename")
	root.free()


func _gate_roots() -> void:
	print("[gate 4] Lit scene roots, binary scenes, inherited, nested and stale overrides")
	var ver := Migrations.current_version()
	var lamp := _fresh(OUT + "/fixture_lamp.tscn")
	if _check(lamp != null, "light-rooted scene loads"):
		_check(is_equal_approx(float(lamp.get("energy")), 1.5) and str(lamp.get("lit_version")) == ver,
				"scene root migrated and stamped")
		lamp.free()
	var bin := _fresh(OUT + "/" + BIN_SCENE)
	if _check(bin != null, "binary .scn scene loads after the update"):
		_check(is_equal_approx(float(bin.get("energy")), 1.5) and str(bin.get("lit_version")) == ver,
				"binary scene root migrated and stamped, stays .scn")
		bin.free()
	var text := FileAccess.get_file_as_string(OUT + "/fixture_inherited.tscn")
	_check("instance=ExtResource" in text, "inherited scene still inherits its base")
	_check("energy = 6.0" in text and not ("legacy_glow" in text), "inherited root override re-applied under the live name")
	var inh := _fresh(OUT + "/fixture_inherited.tscn")
	if _check(inh != null, "inherited scene loads"):
		_check(is_equal_approx(float(inh.get("energy")), 6.0), "inherited root override wins")
		_check(str(inh.get("lit_version")) == ver, "inherited root follows its stamped base")
		var own := inh.get_node("OwnLamp")
		_check(str(own.get("lit_version")) == ver and is_equal_approx(float(own.get("energy")), 0.4),
				"inherited scene's own Lit node stamped")
		inh.free()
	var outer_text := FileAccess.get_file_as_string(OUT + "/fixture_outer.tscn")
	_check("spot_angle = 60.0" in outer_text and not ("old_cone" in outer_text),
			"override two instance levels deep re-applied under the live name")
	var outer := _fresh(OUT + "/fixture_outer.tscn")
	if _check(outer != null, "outer scene loads"):
		_check(is_equal_approx(float(outer.get_node("Inner/Level/Spot").get("spot_angle")), 60.0),
				"nested override wins")
		outer.free()
	var stale_text := FileAccess.get_file_as_string(OUT + "/fixture_stale.tscn")
	_check("energy = 7.0" in stale_text and not ("legacy_glow" in stale_text),
			"override on an already-current instanced node still re-applied under the live name")
	var stale := _fresh(OUT + "/fixture_stale.tscn")
	if _check(stale != null, "stale-override scene loads"):
		_check(is_equal_approx(float(stale.get_node("Cur/Lamp").get("energy")), 7.0), "stale override wins")
		stale.free()
	var plain := _fresh(OUT + "/fixture_plain.tscn")
	if _check(plain != null, "plain scene loads"):
		_check(str(plain.get_node("Lamp").get("lit_version")) == ver
				and is_equal_approx(float(plain.get_node("Lamp").get("energy")), 0.3), "plain Lit node stamped, data kept")
		plain.free()


func _gate_untouched(label: String, files: Array) -> void:
	print("[gate 5] never changes scripts, node types or files it has no business in (%s)" % label)
	for f in files:
		_unchanged(f, label)
	for f in _rows_before:
		var after := _rows(OUT + "/" + f)
		var before: Dictionary = _rows_before[f]
		_check(after.size() == before.size(), "%s keeps its %d rows %s, got %d" % [f, before.size(), label, after.size()])
		for p in before:
			_check(after.get(p) == before[p], "%s row %s keeps type, script and instance %s (%s -> %s)"
					% [f, p, label, before[p], after.get(p)])


func _gate_run_result(scan1: Dictionary, run1: Dictionary) -> void:
	print("[gate 6] run summary + report")
	var changed: Array = run1["changed_scenes"]
	_check(changed.size() == 8, "eight scenes rewritten, got %d" % changed.size())
	for f in ["fixture_level.tscn", "fixture_parent.tscn", "fixture_lamp.tscn", "fixture_inherited.tscn",
			"fixture_stale.tscn", "fixture_outer.tscn", "fixture_plain.tscn", BIN_SCENE]:
		_check(changed.has(OUT + "/" + f), "%s rewritten" % f)
	_check(run1["updated"] == 16, "sixteen Lit nodes updated, got %d" % run1["updated"])
	var joined := "\n".join(run1["report"])
	for marker in ["MIGRATED Lamp: legacy_glow -> energy", "MIGRATED Spot: old_cone -> mid_cone",
			"MIGRATED Spot: mid_cone -> spot_angle", "MIGRATED Hero: legacy_emit 0.5 -> emissive_strength 0.25",
			"STAMPED 11 Lit nodes", "REMAPPED-OVERRIDE ./Level/Lamp: legacy_glow -> energy",
			"REMAPPED-OVERRIDE .: legacy_glow -> energy", "REMAPPED-OVERRIDE ./Ghost: legacy_glow -> energy",
			"REMAPPED-OVERRIDE ./Lantern: legacy_glow -> energy", "REMAPPED-OVERRIDE ./Cur/Lamp: legacy_glow -> energy",
			"REMAPPED-OVERRIDE ./Inner/Level/Spot: old_cone -> spot_angle",
			"REMAPPED-TRACK Anim/swing: legacy_glow -> energy", "REMAPPED-TRACK Anim/swing: old_cone -> spot_angle",
			"REMAPPED-TRACK Anim/walk: legacy_glow -> energy", "REMAPPED-TRACK Tree/tree_swing: legacy_glow -> energy",
			"MANUAL Anim/ext_swing: external animation drives `legacy_glow` on Lamp (now `energy`)",
			"SKIPPED ./Future: LitPointLight2D saved with Lit 9.9.9, newer than this plugin",
			"SKIPPED ./New/Future: stores `future_prop` = 1, which this plugin does not know",
			"SKIPPED scene left untouched: saving would drop the stored values above",
			"--- %s/fixture_newer.tscn\nSKIPPED" % OUT, "--- %s/fixture_stale.tscn\nREMAPPED-OVERRIDE" % OUT,
			"SAVED", "UNCHANGED"]:
		_check(marker in joined, "report mentions %s" % marker)
	_check(not ("--- %s/fixture_current.tscn" % OUT in joined), "already-current scene never processed")
	_check(not ("MIGRATED OldLamp" in joined), "older node inside the skipped scene never migrated")
	_check(not ("./Level/CoreLight" in joined), "core node override with a Lit-retired name is neither remapped nor flagged")
	var report_text := FileAccess.get_file_as_string(OUT + "/report.txt")
	_check(report_text.begins_with("Update Project to Lit %s - 11 scenes scanned, 16 Lit nodes updated in 8 scenes"
			% scan1["current"]), "report header names the tool and the counts, got: %s" % report_text.get_slice("\n", 0))
	_check("NEEDS YOUR ATTENTION - 4 items" in report_text, "attention section counts the flagged lines, got:\n%s"
			% report_text.substr(0, 400))
	_check(report_text.find("NEEDS YOUR ATTENTION") < report_text.find("--- "), "attention section sits above the log")
	_check("rename the track by hand  (%s/fixture_level.tscn)" % OUT in report_text, "flagged lines carry their scene")


func _gate_idempotency(migs: Array) -> void:
	print("[gate 7] second run is a no-op")
	var hashes := {}
	for f in FILES:
		hashes[f] = FileAccess.get_md5(OUT + "/" + f)
	hashes[BIN_SCENE] = FileAccess.get_md5(OUT + "/" + BIN_SCENE)
	var scan2: Dictionary = Tool.scan([OUT], migs)
	var c: Dictionary = scan2["counts"]
	_check(c["lit_nodes"] == 0 and c["track_rows"] == 0,
			"second scan finds no older nodes or tracks (%d / %d)" % [c["lit_nodes"], c["track_rows"]])
	_check(c["override_rows"] == 1, "only the refused scene's override is still pending, got %d" % c["override_rows"])
	_check(c["scenes_skipped"] == 1, "newer scene still reported on the second scan")
	var run2: Dictionary = Tool.run(scan2, OUT + "/report2.txt", migs)
	_check(run2["changed_scenes"].is_empty(), "no scenes rewritten on the second run: %s" % str(run2["changed_scenes"]))
	_check(run2["updated"] == 0, "nothing stamped on the second run")
	for f in hashes:
		_check(FileAccess.get_md5(OUT + "/" + f) == hashes[f], "%s byte-identical after the second run" % f)


func _gate_registered_chain() -> void:
	print("[gate 8] registered (empty) chain: stamps what it can, refuses scenes it would damage")
	_prepare()
	var scan: Dictionary = Tool.scan([OUT])
	var c: Dictionary = scan["counts"]
	_check(c["lit_nodes"] == 16 and c["override_rows"] == 0 and c["track_rows"] == 0,
			"no retired names without registered renames (%d / %d / %d)"
			% [c["lit_nodes"], c["override_rows"], c["track_rows"]])
	var run: Dictionary = Tool.run(scan, OUT + "/report8.txt")
	_check(run["updated"] == 1 and run["changed_scenes"] == [OUT + "/fixture_plain.tscn"],
			"only the scene without unknown stored values is stamped (%d / %s)" % [run["updated"], str(run["changed_scenes"])])
	var plain := _fresh(OUT + "/fixture_plain.tscn")
	if _check(plain != null, "plain scene loads after the registered-chain run"):
		_check(str(plain.get_node("Lamp").get("lit_version")) == Migrations.current_version(), "plain Lit node stamped")
		plain.free()
	var joined := "\n".join(run["report"])
	_check("SKIPPED ./Lamp: stores `legacy_glow` = 2.5, which this plugin does not know" in joined,
			"unknown stored value reported before the refusal")
	_check(joined.count("SKIPPED scene left untouched") == 5, "five scenes refused, got %d"
			% joined.count("SKIPPED scene left untouched"))
	var kept: Array = UNTOUCHED.duplicate()
	kept += ["fixture_level.tscn", "fixture_parent.tscn", "fixture_lamp.tscn", "fixture_inherited.tscn",
			"fixture_stale.tscn", "fixture_outer.tscn", BIN_SCENE]
	_gate_untouched("after the registered-chain run", kept)
