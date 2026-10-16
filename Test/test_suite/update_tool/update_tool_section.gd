extends LitSuiteSection

## "Update Project to Lit" (Project > Tools): the fixtures under Test/.update_tool_bench
## are copied to a scratch folder and the update runs rooted there against the bench's
## synthetic migrations. Checks the safe-update contract: Lit nodes migrated through
## their chain and stamped, renamed properties re-applied from instance overrides and
## embedded animation tracks, external animations reported, scenes skipped whole when
## saving would lose data, every script byte-identical and every node type unchanged,
## the report file, byte-identical idempotency, and the registered chain refusing what
## it cannot account for.
##
## The same contracts are locked headlessly by Test/gate_update_tool.gd; this section
## keeps them in the one-window pass.

const Tool := preload("res://addons/lit/editor/lit_update_tool.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")

const SRC := "res://Test/.update_tool_bench"
const OUT := "res://Test/.update_tool_bench/.suite_out"
const FILES := ["fixture_level.tscn", "fixture_parent.tscn", "fixture_lamp.tscn",
	"fixture_inherited.tscn", "fixture_newer.tscn", "fixture_current.tscn", "fixture_stale.tscn",
	"fixture_outer.tscn", "fixture_newer_user.tscn", "fixture_plain.tscn",
	"fixture_anim_lib.tres", "fixture_user_light.gd", "fixture_user_light2.gd",
	"fixture_user_sprite.gd", "fixture_watcher.gd"]
const UNTOUCHED := ["fixture_user_light.gd", "fixture_user_light2.gd", "fixture_user_sprite.gd",
	"fixture_watcher.gd", "fixture_anim_lib.tres", "fixture_newer.tscn", "fixture_current.tscn",
	"fixture_newer_user.tscn"]
const MIGRATION_FILES := ["fixture_spot_a_migration.gd", "fixture_light_migration.gd",
	"fixture_sprite_migration.gd", "fixture_spot_b_migration.gd"]

var _lines: Array[String] = []
var _rows_before := {}
var _hashes := {}


func run() -> void:
	label("Update Project to Lit: fixtures updated in a scratch copy of Test/.update_tool_bench",
			Vector2(24, 74))
	if not DirAccess.dir_exists_absolute(SRC):
		check_true("update_tool", "fixture folder %s present" % SRC, false)
		return
	var migs := _migrations()
	_prepare()
	var scan1: Dictionary = Tool.scan([OUT], migs)
	_scan(scan1)
	var run1: Dictionary = Tool.run(scan1, OUT + "/report.txt", migs)
	_nodes()
	_overrides()
	_untouched("update_safety", UNTOUCHED)
	_report(scan1, run1)
	_idempotency(migs)
	_registered()
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


func _migrations() -> Array:
	var out := []
	for f in MIGRATION_FILES:
		out.append((load(SRC + "/" + f) as GDScript).new())
	return out


func _expected(f: String) -> String:
	return FileAccess.get_file_as_string(SRC + "/" + f).replace(SRC + "/", OUT + "/") \
			.replace("__CURRENT__", Migrations.current_version())


func _prepare() -> void:
	_cleanup()
	DirAccess.make_dir_recursive_absolute(OUT)
	for f in FILES:
		var w := FileAccess.open(OUT + "/" + f, FileAccess.WRITE)
		w.store_string(_expected(f))
	_rows_before.clear()
	_hashes.clear()
	for f in FILES:
		_hashes[f] = FileAccess.get_md5(OUT + "/" + f)
		if f.ends_with(".tscn"):
			_rows_before[f] = _rows(OUT + "/" + f)


func _cleanup() -> void:
	if not DirAccess.dir_exists_absolute(OUT):
		return
	for f in DirAccess.get_files_at(OUT):
		DirAccess.remove_absolute(OUT + "/" + f)
	DirAccess.remove_absolute(OUT)


func _fresh(path: String) -> Node:
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	return null if packed == null else packed.instantiate()


func _rows(path: String) -> Dictionary:
	var out := {}
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if packed == null:
		return out
	var state := packed.get_state()
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


func _script_path(node: Node) -> String:
	var s := node.get_script() as Script
	return "" if s == null else s.resource_path


func _scan(scan: Dictionary) -> void:
	var c := "update_scan"
	var cnt: Dictionary = scan["counts"]
	check(c, "scenes scanned", 10, cnt["scenes"])
	check(c, "Lit nodes on older versions (skipped scene excluded)", 15, cnt["lit_nodes"])
	check(c, "Lit nodes already current", 2, cnt["lit_current"])
	check(c, "nodes stamped newer than the plugin", 1, cnt["newer"])
	check(c, "unscripted core nodes counted for the port hint", 2, cnt["core_nodes"])
	check(c, "instance overrides storing names their Lit class retires", 7, cnt["override_rows"])
	check(c, "animation mixers driving retired names on Lit nodes", 3, cnt["track_rows"])
	check(c, "scenes to process", 8, cnt["scenes_to_process"])
	check(c, "scenes skipped for newer data", 1, cnt["scenes_skipped"])
	check(c, "user script two levels below a Lit class resolves to that class", &"LitPointLight2D",
			Tool.lit_class_of(scan, OUT + "/fixture_user_light2.gd"))
	check(c, "user script extending a core class resolves to none", &"",
			Tool.lit_class_of(scan, OUT + "/fixture_user_sprite.gd"))
	check(c, "an unversioned Lit class is not an update target", &"",
			Tool.lit_class_of(scan, "res://addons/lit/nodes/lit_precompile_overlay.gd"))
	_note("scan: 10 scenes, 15 older Lit nodes, 1 newer, 7 overrides, 3 mixers")


func _nodes() -> void:
	var c := "update_nodes"
	var ver := Migrations.current_version()
	var text := FileAccess.get_file_as_string(OUT + "/fixture_level.tscn")
	var leftover: Array[String] = []
	for retired in ["legacy_glow", "legacy_mask", "legacy_emit", "old_cone", "mid_cone"]:
		if retired in text:
			leftover.append(retired)
	check(c, "retired names gone from the level file", "none", "none" if leftover.is_empty() else ", ".join(leftover))
	var root := _fresh(OUT + "/fixture_level.tscn")
	if not check_true(c, "level scene loads", root != null):
		return
	var lamp := root.get_node("Lamp")
	check_true(c, "legacy_glow -> energy on the point light, stamped, authored data kept",
			is_equal_approx(float(lamp.get("energy")), 2.5) and str(lamp.get("lit_version")) == ver
			and lamp.unique_name_in_owner and lamp.is_in_group("torches") and int(lamp.get("range_z_max")) == 7)
	check_true(c, "directional light stamped from 1.1.3 with its data kept",
			str(root.get_node("Sun").get("lit_version")) == ver and is_equal_approx(float(root.get_node("Sun").get("energy")), 0.8))
	check_true(c, "two-step rename old_cone -> mid_cone -> spot_angle lands on spot_angle",
			is_equal_approx(float(root.get_node("Spot").get("spot_angle")), 45.0) and str(root.get_node("Spot").get("lit_version")) == ver)
	check_true(c, "1.1.4 spot light only runs the second rename",
			is_equal_approx(float(root.get_node("Spot2").get("spot_angle")), 50.0))
	var hero := root.get_node("Hero")
	check_true(c, "LitSprite2D keeps node type and script, legacy_mask -> receiver_mask, apply() fills emissive_strength, stamped",
			hero.get_class() == "Sprite2D" and _script_path(hero) == "res://addons/lit/nodes/lit_sprite_2d.gd"
			and int(hero.get("receiver_mask")) == 4 and is_equal_approx(float(hero.get("emissive_strength")), 0.25)
			and str(hero.get("lit_version")) == ver)
	check_true(c, "tilemap (legacy metadata stamp), animated sprite, post host and effect stamped",
			str(root.get_node("Tiles").get("lit_version")) == ver and str(root.get_node("Walker").get("lit_version")) == ver
			and str(root.get_node("Post").get("lit_version")) == ver and str(root.get_node("Post/Vignette").get("lit_version")) == ver)
	check_true(c, "unversioned overlay left alone", root.get_node("Overlay").get("lit_version") == null)
	var scripted := root.get_node("Scripted")
	check_true(c, "user script extending a Lit class stays attached, its node migrated and stamped, export kept",
			_script_path(scripted).ends_with("fixture_user_light.gd") and is_equal_approx(float(scripted.get("energy")), 3.5)
			and is_equal_approx(float(scripted.get("intensity")), 2.0) and str(scripted.get("lit_version")) == ver)
	check_true(c, "two-level user subclass migrated and stamped",
			is_equal_approx(float(root.get_node("Scripted2").get("energy")), 4.5) and str(root.get_node("Scripted2").get("lit_version")) == ver)
	var legacy := root.get_node("Legacy")
	check_true(c, "core-extending user script node left exactly as authored",
			legacy.get_class() == "Sprite2D" and _script_path(legacy).ends_with("fixture_user_sprite.gd")
			and is_equal_approx(float(legacy.get("speed")), 3.0) and legacy.get("lit_version") == null)
	var core_light := root.get_node("CoreLight")
	check_true(c, "core light and sprite left native", core_light.get_class() == "PointLight2D" and core_light.get_script() == null
			and root.get_node("CoreSprite").get_class() == "Sprite2D" and root.get_node("CoreSprite").get_script() == null)
	check_true(c, "occluder, exported core reference and persisted connection survive",
			root.get_node("Occluder") is LightOccluder2D and root.get_node("Watcher").get("lamp") == core_light
			and (root.get_node("Blocker") as Timer).timeout.is_connected(Callable(lamp, "hide")))
	var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("swing")
	check_true(c, "embedded tracks follow renames (two-step included), live and core tracks untouched",
			anim != null and anim.track_get_path(0) == NodePath("Lamp:energy") and anim.track_get_path(1) == NodePath("Lamp:color")
			and anim.track_get_path(2) == NodePath("Hero:receiver_mask") and anim.track_get_path(3) == NodePath("CoreLight:energy")
			and anim.track_get_path(4) == NodePath("Spot:spot_angle"))
	var ext := (root.get_node("Anim") as AnimationPlayer).get_animation("ext/ext_swing")
	check_true(c, "external animation track left as authored", ext != null and ext.track_get_path(0) == NodePath("Lamp:legacy_glow"))
	var tree := (root.get_node("Tree") as AnimationTree).get_animation("tree_swing")
	check_true(c, "AnimationTree track follows the rename", tree != null and tree.track_get_path(0) == NodePath("Lamp:energy"))
	root.free()
	var lamp_root := _fresh(OUT + "/fixture_lamp.tscn")
	if check_true(c, "light-rooted scene loads", lamp_root != null):
		check_true(c, "scene root migrated and stamped", is_equal_approx(float(lamp_root.get("energy")), 1.5)
				and str(lamp_root.get("lit_version")) == ver)
		lamp_root.free()
	_note("nodes: chain + stamp on every Lit class, user subclasses included; core nodes untouched")


func _overrides() -> void:
	var c := "update_overrides"
	var ver := Migrations.current_version()
	var text := FileAccess.get_file_as_string(OUT + "/fixture_parent.tscn")
	check_true(c, "editable override re-applied under the live name, native override kept",
			"[editable path=\"Level\"]" in text and "energy = 4.0" in text and not ("legacy_glow = 4.0" in text)
			and "color = Color(0, 0, 1, 1)" in text)
	check_true(c, "placeholder and instance-root overrides re-applied, placeholder stays one", "energy = 9.0" in text
			and "energy = 5.5" in text and not ("legacy_glow" in text)
			and "instance_placeholder=\"%s/fixture_lamp.tscn\"" % OUT in text)
	check_true(c, "core node override keeps a name only a Lit class retires", "shadow_filter = 2" in text)
	check_true(c, "instanced scene's nodes not baked into the parent", not ("Hero" in text))
	var root := _fresh(OUT + "/fixture_parent.tscn")
	if check_true(c, "parent scene loads", root != null):
		var lamp := root.get_node("Level/Lamp")
		check_true(c, "override wins over the child's migrated value, same-name override and user-added node survive",
				is_equal_approx(float(lamp.get("energy")), 4.0) and (lamp.get("color") as Color).is_equal_approx(Color(0, 0, 1, 1))
				and is_equal_approx(float(root.get_node("Level/Sun").get("energy")), 0.3) and root.get_node_or_null("Level/Extra") != null)
		check_true(c, "parent's own Lit node stamped, instance-root override wins",
				str(root.get_node("Torch").get("lit_version")) == ver and is_equal_approx(float(root.get_node("Lantern").get("energy")), 5.5))
		var anim := (root.get_node("Anim") as AnimationPlayer).get_animation("walk")
		check_true(c, "parent track through a non-root root_node follows the rename",
				anim != null and anim.track_get_path(0) == NodePath("Lamp:energy"))
		root.free()
	var inh_text := FileAccess.get_file_as_string(OUT + "/fixture_inherited.tscn")
	check_true(c, "inherited scene still inherits, root override re-applied", "instance=ExtResource" in inh_text
			and "energy = 6.0" in inh_text and not ("legacy_glow" in inh_text))
	var inh := _fresh(OUT + "/fixture_inherited.tscn")
	if check_true(c, "inherited scene loads", inh != null):
		check_true(c, "inherited root override wins, own node stamped", is_equal_approx(float(inh.get("energy")), 6.0)
				and str(inh.get_node("OwnLamp").get("lit_version")) == ver)
		inh.free()
	var outer := FileAccess.get_file_as_string(OUT + "/fixture_outer.tscn")
	check_true(c, "override two instance levels deep re-applied", "spot_angle = 60.0" in outer and not ("old_cone" in outer))
	var stale := FileAccess.get_file_as_string(OUT + "/fixture_stale.tscn")
	check_true(c, "override on an already-current instanced node re-applied", "energy = 7.0" in stale and not ("legacy_glow" in stale))
	_note("overrides: editable, placeholder, instance root, inherited root, nested and stale overrides follow renames")


func _untouched(c: String, files: Array) -> void:
	for f in files:
		check_true(c, "%s byte-identical" % f, FileAccess.get_md5(OUT + "/" + f) == _hashes[f])
	var drift: Array[String] = []
	for f in _rows_before:
		var after := _rows(OUT + "/" + f)
		var before: Dictionary = _rows_before[f]
		if after.size() != before.size():
			drift.append("%s rows %d -> %d" % [f, before.size(), after.size()])
		for p in before:
			if after.get(p) != before[p]:
				drift.append("%s %s: %s -> %s" % [f, p, before[p], after.get(p)])
	check(c, "every row keeps its type, script and instance in every scene", "no drift",
			"no drift" if drift.is_empty() else "; ".join(drift))


func _report(scan1: Dictionary, run1: Dictionary) -> void:
	var c := "update_report"
	check(c, "scenes rewritten", 7, run1["changed_scenes"].size())
	check(c, "Lit nodes updated", 15, run1["updated"])
	var joined := "\n".join(run1["report"])
	var missing: Array[String] = []
	for tag in ["MIGRATED Lamp: legacy_glow -> energy", "MIGRATED Spot: mid_cone -> spot_angle",
			"MIGRATED Hero: legacy_emit 0.5 -> emissive_strength 0.25", "STAMPED 11 Lit nodes",
			"REMAPPED-OVERRIDE ./Level/Lamp: legacy_glow -> energy", "REMAPPED-OVERRIDE ./Ghost: legacy_glow -> energy",
			"REMAPPED-OVERRIDE ./Inner/Level/Spot: old_cone -> spot_angle",
			"REMAPPED-TRACK Anim/swing: old_cone -> spot_angle", "REMAPPED-TRACK Anim/walk: legacy_glow -> energy",
			"REMAPPED-TRACK Tree/tree_swing: legacy_glow -> energy",
			"MANUAL Anim/ext_swing: external animation drives `legacy_glow`",
			"SKIPPED ./Future: LitPointLight2D saved with Lit 9.9.9, newer than this plugin",
			"SKIPPED ./New/Future: stores `future_prop` = 1, which this plugin does not know",
			"SKIPPED scene left untouched: saving would drop the stored values above", "SAVED", "UNCHANGED"]:
		if not (tag in joined):
			missing.append(tag)
	check(c, "report mentions every tag", "all present", "all present" if missing.is_empty() else "missing: " + ", ".join(missing))
	check_true(c, "core node override with a Lit-retired name is neither remapped nor flagged", not ("./Level/CoreLight" in joined))
	var report_text := FileAccess.get_file_as_string(OUT + "/report.txt")
	check_true(c, "report file names the tool, leads with a fenced attention section above the log",
			report_text.begins_with("Update Project to Lit %s - 10 scenes scanned, 15 Lit nodes updated in 7 scenes" % scan1["current"])
			and "NEEDS YOUR ATTENTION - 4 items" in report_text and report_text.find("NEEDS YOUR ATTENTION") < report_text.find("--- "))
	_note("report: %d scenes rewritten, attention section written" % run1["changed_scenes"].size())


func _idempotency(migs: Array) -> void:
	var c := "update_idempotency"
	var hashes := {}
	for f in FILES:
		hashes[f] = FileAccess.get_md5(OUT + "/" + f)
	var scan2: Dictionary = Tool.scan([OUT], migs)
	var cnt: Dictionary = scan2["counts"]
	check_true(c, "second scan finds no older nodes or tracks, only the refused scene's override",
			cnt["lit_nodes"] == 0 and cnt["track_rows"] == 0 and cnt["override_rows"] == 1)
	var run2: Dictionary = Tool.run(scan2, OUT + "/report2.txt", migs)
	check_true(c, "second run rewrites and stamps nothing", run2["changed_scenes"].is_empty() and run2["updated"] == 0)
	var same := true
	for f in FILES:
		same = same and FileAccess.get_md5(OUT + "/" + f) == hashes[f]
	check_true(c, "every file byte-identical after the second run", same)
	_note("idempotency: second run is a no-op")


func _registered() -> void:
	var c := "update_registered"
	_prepare()
	var scan: Dictionary = Tool.scan([OUT])
	var cnt: Dictionary = scan["counts"]
	check_true(c, "no retired names without registered renames", cnt["override_rows"] == 0 and cnt["track_rows"] == 0)
	var run: Dictionary = Tool.run(scan, OUT + "/report8.txt")
	check(c, "only the scene without unknown stored values is rewritten", [OUT + "/fixture_plain.tscn"], run["changed_scenes"])
	check(c, "one Lit node stamped", 1, run["updated"])
	var joined := "\n".join(run["report"])
	check_true(c, "unknown stored values reported before each refusal",
			"SKIPPED ./Lamp: stores `legacy_glow` = 2.5, which this plugin does not know" in joined
			and joined.count("SKIPPED scene left untouched") == 4)
	var kept: Array = UNTOUCHED.duplicate()
	kept += ["fixture_level.tscn", "fixture_parent.tscn", "fixture_lamp.tscn", "fixture_inherited.tscn",
			"fixture_stale.tscn", "fixture_outer.tscn"]
	_untouched(c, kept)
	_note("registered chain: stamps the plain scene, refuses the five it would damage")
