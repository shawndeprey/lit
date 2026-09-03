@tool
extends RefCounted

## Engine behind "Update Project to Lit" (Project > Tools). Idempotent, two jobs in
## one pass: convert core Godot nodes to their Lit equivalents project-wide (mapping
## property values into the right slots), and bring every Lit node up to the current
## plugin version through the migration chain, stamping `lit_version`.
##
## This file is the orchestrator; each stage owns its piece under lit_update_tool/:
##   script_scan.gd        - .gd analysis (chains, refs, @tool, code-usage evidence)
##   scene_scan.gd         - per-scene SceneState model + leaves-first order
##   scan_classifier.gd    - world vs menu/UI classification, materials, counts
##   script_rewriter.gd    - rebase / @tool / retype / reload pass
##   scene_converter.gd    - node replacement, receiver swaps, remaps, save
##   receiver_materials.gd - material-slot classification and receiver materials
##   report_writer.gd      - attention-section report file
##   conversion_maps.gd    - class and property mapping tables
##   migrations/           - version framework (one file per breaking change)
##
## scan() reads every scene through SceneState (no scene code runs) plus every project
## .gd file, and returns a model + counts for the confirmation dialog. run() executes:
## first the script pass (rebasing user scripts extending Sprite2D/TileMapLayer onto
## the Lit classes), then the scene pass, leaves-first so instance overrides in parent
## scenes can be remapped after their child scenes converted. Scenes are instantiated
## off-tree with GEN_EDIT_STATE_MAIN (delta preservation for sub-instances), mutated,
## packed, and saved back over themselves; untouched scenes are never re-saved.

const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")
const ScriptScan := preload("res://addons/lit/editor/lit_update_tool/script_scan.gd")
const SceneScan := preload("res://addons/lit/editor/lit_update_tool/scene_scan.gd")
const Classifier := preload("res://addons/lit/editor/lit_update_tool/scan_classifier.gd")
const Rewriter := preload("res://addons/lit/editor/lit_update_tool/script_rewriter.gd")
const Converter := preload("res://addons/lit/editor/lit_update_tool/scene_converter.gd")
const Reporter := preload("res://addons/lit/editor/lit_update_tool/report_writer.gd")

const REPORT_PATH := "res://lit_update_report.txt"


# --- Scan ----------------------------------------------------------------------

## Read-only project model. `roots` narrows the walk (the gate points it at fixtures).
static func scan(roots: Array[String] = ["res://"]) -> Dictionary:
	var acc := scan_begin(roots)
	for p in acc["scene_paths"]:
		scan_scene(acc, p)
	return scan_finish(acc)


## scan() split into begin / per-scene / finish so the editor can drive it a scene at a
## time behind a progress dialog instead of freezing the main thread.
static func scan_begin(roots: Array[String] = ["res://"]) -> Dictionary:
	var collected: Array[String] = []
	for root in roots:
		LitShaderPrecompilerScript._collect_scenes(root, collected)
	var scene_paths: Array[String] = []
	for p in collected:
		if not p.begins_with("res://addons"):
			scene_paths.append(p)
	return {
		"scene_paths": scene_paths,
		"scripts": ScriptScan.scan_scripts(roots),
		"lit_by_script": Migrations.lit_scripts_by_path(),
		"current": Migrations.current_version(),
		"core_names": Maps.core_mapped_names(),
		"model": {},
		"custom_groups": {},
		"unlit_nodes": [] as Array[String],
		"counts": {"scenes": scene_paths.size(), "point_lights": 0, "directional_lights": 0,
			"modulates": 0, "sprites": 0, "tilemaps": 0, "skipped_scripted": 0,
			"lit_stamp": 0, "remap_rows": 0, "scenes_to_process": 0, "unlit_mats": 0,
			"custom_mats": 0, "menu_nodes": 0, "menu_core": 0},
	}


static func scan_scene(acc: Dictionary, scene_path: String) -> void:
	SceneScan.scan_scene(acc, scene_path)


static func scan_finish(acc: Dictionary) -> Dictionary:
	return Classifier.finish(acc)


# --- Run -----------------------------------------------------------------------

## Execute the update. `kinds` gates conversions only ({lights, modulates, sprites,
## tilemaps, scripts}); version stamping, migrations, and override remaps always run.
static func run(scan_result: Dictionary, kinds: Dictionary,
		report_path: String = REPORT_PATH) -> Dictionary:
	var rctx := run_begin(scan_result, kinds, report_path)
	for scene_path in rctx["scenes"]:
		run_scene(rctx, scene_path)
	return run_finish(rctx)


## run() split into begin / per-scene / finish so the editor can drive the scene pass
## behind a progress dialog. begin executes the whole script pass (rebase, @tool,
## reference retype, one reload) and returns the ordered scene work list.
static func run_begin(scan_result: Dictionary, kinds: Dictionary,
		report_path: String = REPORT_PATH) -> Dictionary:
	var report: Array[String] = []
	var scripts: Dictionary = scan_result["scripts"]
	var rebased := {}
	var tooled: Array = []
	var retyped: Array = []
	# Menus unchecked leaves UI-only chains byte-identical: no rebase, no @tool, no retype.
	var ui_roots: Dictionary = {}
	var ui_scripts: Dictionary = {}
	if not kinds.get("menus", false):
		ui_roots = scripts.get("ui_roots", {})
		ui_scripts = scripts.get("ui_scripts", {})
		for sp in scan_result.get("ui_scenes", []):
			report.append("MENU-SCENE %s: every instance sits under menus/UI; left native "
					% sp + "(check the menus option to convert)")
		var mixed_scenes: Dictionary = scan_result.get("mixed_ui_scenes", {})
		var mkeys: Array = mixed_scenes.keys()
		mkeys.sort()
		for sp in mkeys:
			report.append("CAUTION %s converts for world use but is also instanced under "
					% sp + "menus/UI; those instances will receive world lighting:")
			for site in mixed_scenes[sp]:
				report.append("    " + site)
		var mixed_scripts: Dictionary = scan_result.get("mixed_ui_scripts", {})
		mkeys = mixed_scripts.keys()
		mkeys.sort()
		for sp in mkeys:
			report.append("CAUTION script %s rebases for world use but is also attached to "
					% sp + "menu/UI nodes; those nodes become lit receivers:")
			for site in mixed_scripts[sp]:
				report.append("    " + site)
	if kinds.get("scripts", true):
		rebased = Rewriter.rebase_user_scripts(scripts, ui_roots, report)
		tooled = Rewriter.add_tool_annotations(scripts, ui_scripts, report)
		retyped = Rewriter.retype_references(scripts, ui_scripts, report)
		if not retyped.is_empty() and int(scan_result["counts"]["skipped_scripted"]) > 0:
			report.append("CAUTION: %d core nodes keep custom scripts and stay core types; "
					% scan_result["counts"]["skipped_scripted"]
					+ "references to those specific nodes should keep their core annotations")
		if not retyped.is_empty() and not kinds.get("menus", false) \
				and int(scan_result["counts"].get("menu_core", 0)) > 0:
			report.append("CAUTION: %d menu/UI core lights or modulates stay native "
					% scan_result["counts"]["menu_core"]
					+ "(menus unchecked); references to those specific nodes should keep "
					+ "their core annotations")
		var touched := {}
		for p in rebased:
			touched[p] = true
		for p in tooled:
			touched[p] = true
		for p in retyped:
			touched[p] = true
		Rewriter.reload_scripts(touched.keys())
	var rewritten: Array = rebased.keys()
	# Scripts already rooted in a Lit class get the same node fixups every run, so a
	# later run converges anything a previous one missed (or that was added since).
	rebased.merge(scripts["lit_based"])
	var ctx := {"custom": scan_result["custom_groups"].duplicate(true), "scene": ""}
	var scenes: Array[String] = []
	for scene_path in scan_result["order"]:
		var m: Dictionary = scan_result["model"][scene_path]
		if m["needs"] or _uses_rebased(m, rebased):
			scenes.append(scene_path)
	return {"scan": scan_result, "kinds": kinds, "report": report, "rebased": rebased,
		"rewritten": rewritten, "tooled": tooled, "retyped": retyped, "ctx": ctx,
		"scenes": scenes, "changed_scenes": [] as Array[String], "report_path": report_path}


static func run_scene(rctx: Dictionary, scene_path: String) -> void:
	var report: Array = rctx["report"]
	var m: Dictionary = rctx["scan"]["model"][scene_path]
	report.append("--- %s" % scene_path)
	rctx["ctx"]["scene"] = scene_path
	if Converter.process_scene(scene_path, m, rctx["scan"], rctx["kinds"], rctx["rebased"],
			report, rctx["ctx"]):
		rctx["changed_scenes"].append(scene_path)
		report.append("SAVED")
	else:
		report.append("UNCHANGED")


static func run_finish(rctx: Dictionary) -> Dictionary:
	var report: Array = rctx["report"]
	Reporter.material_notes(rctx["scan"], rctx["ctx"], report)
	var saved := Reporter.write(report, rctx["scan"], rctx["changed_scenes"],
			rctx["report_path"])
	return {"changed_scenes": rctx["changed_scenes"], "report": report, "report_saved": saved,
		"rebased_scripts": rctx["rewritten"], "tooled_scripts": rctx["tooled"],
		"retyped_scripts": rctx["retyped"]}


static func _uses_rebased(m: Dictionary, rebased: Dictionary) -> bool:
	for row in m["rows"]:
		if rebased.has(row["script"]):
			return true
	return false
