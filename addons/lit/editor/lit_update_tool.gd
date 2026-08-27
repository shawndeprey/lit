@tool
extends RefCounted

## Engine behind "Update Project to Lit" (Project > Tools). Idempotent, two jobs in
## one pass: convert core Godot nodes to their Lit equivalents project-wide (mapping
## property values into the right slots), and bring every Lit node up to the current
## plugin version through the lit_migrations.gd chain, stamping `lit_version`.
##
## scan() reads every scene through SceneState (no scene code runs) plus every project
## .gd file, and returns a model + counts for the confirmation dialog. run() executes:
## first the script pass (rebasing user scripts extending Sprite2D/TileMapLayer onto
## the Lit classes), then the scene pass, leaves-first so instance overrides in parent
## scenes can be remapped after their child scenes converted. Scenes are instantiated
## off-tree with GEN_EDIT_STATE_MAIN (delta preservation for sub-instances), mutated,
## packed, and saved back over themselves; untouched scenes are never re-saved.

const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const Maps := preload("res://addons/lit/editor/lit_conversion_maps.gd")
const Migrations := preload("res://addons/lit/editor/lit_migrations.gd")

const REPORT_PATH := "res://lit_update_report.txt"
# Core shadow_color semantics: shadowed light = mix(light, shadow_rgb, alpha), so the
# default transparent black means invisible shadows. Lit tints shadowed light by rgb
# (alpha unused), so the behavior-preserving map is mix(WHITE, rgb, alpha).
const CORE_SHADOW_DEFAULT := Color(0, 0, 0, 0)


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
		"scripts": _scan_scripts(roots),
		"lit_by_script": _lit_scripts_by_path(),
		"current": Migrations.current_version(),
		"core_names": _core_mapped_names(),
		"model": {},
		"custom_groups": {},
		"unlit_nodes": [] as Array[String],
		"counts": {"scenes": scene_paths.size(), "point_lights": 0, "directional_lights": 0,
			"modulates": 0, "sprites": 0, "tilemaps": 0, "skipped_scripted": 0,
			"lit_stamp": 0, "remap_rows": 0, "scenes_to_process": 0, "unlit_mats": 0,
			"custom_mats": 0, "menu_nodes": 0, "menu_core": 0},
	}


static func scan_scene(acc: Dictionary, scene_path: String) -> void:
	var counts: Dictionary = acc["counts"]
	var scripts: Dictionary = acc["scripts"]
	var lit_by_script: Dictionary = acc["lit_by_script"]
	var core_names: Dictionary = acc["core_names"]
	var current: String = acc["current"]
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("Lit: update scan could not load '%s'; skipped" % scene_path)
		return
	var state := packed.get_state()
	var rows: Array[Dictionary] = []
	var deps := {}
	var needs := false
	for i in state.get_node_count():
		var props := {}
		for p in state.get_node_property_count(i):
			props[String(state.get_node_property_name(i, p))] = state.get_node_property_value(i, p)
		var script_path := ""
		var script = props.get("script")
		if script is Script:
			script_path = (script as Script).resource_path
		var instance_path := ""
		var inst := state.get_node_instance(i)
		if inst != null:
			instance_path = inst.resource_path
		var row := {
			"path": state.get_node_path(i),
			"type": String(state.get_node_type(i)),
			"script": script_path,
			"instance": instance_path,
			"placeholder": state.is_node_instance_placeholder(i),
			"groups": state.get_node_groups(i),
			"props": props,
		}
		rows.append(row)
		if not instance_path.is_empty():
			deps[instance_path] = true

		if scripts["rebase_all"].has(script_path) or scripts["lit_based"].has(script_path):
			needs = true
		if lit_by_script.has(script_path) \
				and str(props.get("lit_version", "")) != current:
			counts["lit_stamp"] += 1
			needs = true
		if String(row["type"]).is_empty() and row["placeholder"] == false:
			for stored_name in props:
				if core_names.has(stored_name):
					counts["remap_rows"] += 1
					needs = true
					break
		if row["placeholder"]:
			for stored_name in props:
				if core_names.has(stored_name):
					needs = true
	acc["model"][scene_path] = {"rows": rows, "deps": deps.keys(), "needs": needs,
		"inherited": not rows.is_empty() and not String(rows[0]["instance"]).is_empty()}


static func scan_finish(acc: Dictionary) -> Dictionary:
	var counts: Dictionary = acc["counts"]
	var scripts: Dictionary = acc["scripts"]
	# Candidate classification runs here, after every scene is modeled, so UI ancestry
	# can resolve through instanced menu scenes.
	for scene_path in acc["model"]:
		var m: Dictionary = acc["model"][scene_path]
		var by_path := {}
		for row in m["rows"]:
			by_path[String(row["path"])] = row
		var needs: bool = m["needs"]
		for row in m["rows"]:
			var row_type := String(row["type"])
			if row_type.is_empty():
				continue
			var script_path := String(row["script"])
			if Maps.REPLACEMENTS.has(row_type):
				if _is_ui_row(acc, by_path, String(row["path"])):
					row["ui"] = true
					if script_path.is_empty():
						counts["menu_nodes"] += 1
						counts["menu_core"] += 1
						needs = true
				elif script_path.is_empty():
					needs = true
					match row_type:
						"PointLight2D": counts["point_lights"] += 1
						"DirectionalLight2D": counts["directional_lights"] += 1
						"CanvasModulate": counts["modulates"] += 1
				else:
					counts["skipped_scripted"] += 1
					needs = true
			elif Maps.SWAPS.has(row_type) and script_path.is_empty():
				if _is_ui_row(acc, by_path, String(row["path"])):
					row["ui"] = true
					counts["menu_nodes"] += 1
					needs = true
				else:
					var where := "%s %s" % [scene_path, row["path"]]
					var cls := _classify_material(row["props"].get("material"))
					match cls["kind"]:
						"unlit":
							counts["unlit_mats"] += 1
							acc["unlit_nodes"].append(where)
						"custom":
							counts["custom_mats"] += 1
							needs = true
							if not acc["custom_groups"].has(cls["shader"]):
								acc["custom_groups"][cls["shader"]] = []
							acc["custom_groups"][cls["shader"]].append(where)
						_:
							needs = true
							counts["sprites" if row_type == "Sprite2D" else "tilemaps"] += 1
		m["needs"] = needs
		if needs:
			counts["scenes_to_process"] += 1
	counts["rebase_roots"] = scripts["roots"].size()
	counts["rebase_scripts"] = scripts["rebase_all"].size()
	counts["rebase_skipped"] = scripts["skipped"].size()
	counts["retype_scripts"] = scripts["core_refs"].size()
	var tool_add := {}
	for p in scripts["rebase_all"]:
		if scripts["no_tool"].has(p):
			tool_add[p] = true
	for p in scripts["lit_tool_rooted"]:
		if scripts["no_tool"].has(p):
			tool_add[p] = true
	counts["tool_add"] = tool_add.size()
	var scene_paths: Array[String] = acc["scene_paths"]
	return {"order": _topo_order(scene_paths, acc["model"]), "model": acc["model"],
		"scripts": scripts, "counts": counts, "current": acc["current"],
		"custom_groups": acc["custom_groups"], "unlit_nodes": acc["unlit_nodes"]}


## User .gd files whose inheritance chain roots in a rebasable core class. Chain roots
## get their extends line rewritten; a member collision anywhere in a chain (against
## the Lit class's own members) skips the whole chain.
static func _scan_scripts(roots: Array[String]) -> Dictionary:
	var collected: Array[String] = []
	for root in roots:
		_collect_gd(root, collected)
	var paths: Array[String] = []
	for p in collected:
		if not p.begins_with("res://addons"):
			paths.append(p)

	var by_class := {}
	for entry in ProjectSettings.get_global_class_list():
		by_class[String(entry["class"])] = String(entry["path"])

	var core_ref_rx := _core_class_rx()

	var info := {}
	for path in paths:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var members := {}
		var extends_token := ""
		var inner_extends := false
		var has_tool := false
		var refs := {}
		var string_ref := false
		for raw_line in f.get_as_text().split("\n"):
			var line := raw_line.rstrip("\r")
			var stripped := line.strip_edges()
			if stripped == "@tool" or stripped.begins_with("@tool ") or stripped.begins_with("@tool#"):
				has_tool = true
			var token := _extends_token(line)
			if not token.is_empty():
				extends_token = token
			elif line.begins_with("class ") and (" extends " in line):
				var inner_token := line.get_slice(" extends ", 1).get_slice(":", 0).strip_edges()
				if Maps.REBASES.has(inner_token):
					inner_extends = true
			else:
				for kind in ["var", "const", "signal"]:
					if line.begins_with(kind + " "):
						members[line.trim_prefix(kind + " ").get_slice(":", 0)
								.get_slice("=", 0).get_slice(" ", 0)] = kind
				for prefix in ["func ", "static func "]:
					if line.begins_with(prefix):
						members[line.trim_prefix(prefix).get_slice("(", 0).strip_edges()] = "func"
				if not _is_extends_decl(stripped):
					for piece in _line_pieces(line):
						var m := core_ref_rx.search(piece["text"])
						if m == null:
							continue
						if piece["kind"] == "code":
							refs[m.get_string(1)] = true
						elif piece["kind"] == "string":
							string_ref = true
		info[path] = {"extends": extends_token, "members": members, "inner": inner_extends,
			"refs": refs.keys(), "has_tool": has_tool, "string_ref": string_ref}

	# Chain each script to its root; roots extending a rebasable core class collect
	# their subtree, then every member of the group is collision-checked. Chains whose
	# root ALREADY extends a Lit receiver class (a previous run's rebase, or hand
	# authoring) are tracked too: their nodes get the same receiver fixups every run.
	# Any chain rooting in a @tool Lit class needs @tool itself, or the editor gives
	# every instance a placeholder whose lifecycle never runs (and warns MISSING_TOOL).
	var lit_targets := {}
	for core in Maps.REBASES:
		lit_targets[String(Maps.REBASES[core]["lit_class"])] = true
	var tool_lit := _lit_tool_classes()
	var out := {"roots": [], "rebase_all": {}, "skipped": [], "inner": [], "chains": {},
		"core_refs": {}, "string_refs": {}, "lit_based": {}, "lit_tool_rooted": {},
		"no_tool": {}, "all_paths": paths}
	for path in info:
		if not info[path]["refs"].is_empty():
			out["core_refs"][path] = info[path]["refs"]
		if info[path]["string_ref"]:
			out["string_refs"][path] = true
		if not info[path]["has_tool"]:
			out["no_tool"][path] = true
	for path in info:
		var chain: Array[String] = [path]
		var token: String = info[path]["extends"]
		var guard := 0
		while guard < 64:
			guard += 1
			var parent := ""
			if token.begins_with("\"") and token.ends_with("\""):
				parent = token.substr(1, token.length() - 2)
			elif by_class.has(token):
				parent = by_class[token]
			if parent.is_empty() or not info.has(parent):
				break
			chain.append(parent)
			token = info[parent]["extends"]
		if lit_targets.has(token):
			for p in chain:
				out["lit_based"][p] = true
				out["lit_tool_rooted"][p] = true
		elif tool_lit.has(token):
			for p in chain:
				out["lit_tool_rooted"][p] = true
		elif Maps.REBASES.has(token):
			var root_path: String = chain[chain.size() - 1]
			if not out["chains"].has(root_path):
				out["chains"][root_path] = {"core": token, "scripts": {}}
			for p in chain:
				out["chains"][root_path]["scripts"][p] = true
	for path in info:
		if info[path]["inner"]:
			out["inner"].append(path)

	for root_path in out["chains"]:
		var core: String = out["chains"][root_path]["core"]
		var lit_members := _lit_class_members(Maps.REBASES[core]["script"])
		var collisions: Array[String] = []
		for p in out["chains"][root_path]["scripts"]:
			for member in info[p]["members"]:
				if member != "_init" and lit_members.has(member):
					collisions.append("%s declares `%s` (%s on %s)"
							% [p, member, info[p]["members"][member], Maps.REBASES[core]["lit_class"]])
		if collisions.is_empty():
			out["roots"].append(root_path)
			for p in out["chains"][root_path]["scripts"]:
				out["rebase_all"][p] = true
		else:
			out["skipped"].append({"root": root_path, "collisions": collisions})
	out["roots"].sort()
	return out


# The top-level base of a script line, covering both authoring forms:
# `extends X` on its own line and the one-line `class_name Y extends X`.
static func _extends_token(line: String) -> String:
	if line.begins_with("extends "):
		return line.trim_prefix("extends ").get_slice("#", 0).strip_edges()
	if line.begins_with("class_name ") and (" extends " in line):
		return line.get_slice(" extends ", 1).get_slice("#", 0).strip_edges()
	return ""


# Any extends declaration (top-level, one-line class_name form, or inner class); the
# core class named there is a deliberate base, never a retype candidate.
static func _is_extends_decl(stripped: String) -> bool:
	if stripped.begins_with("extends "):
		return true
	if stripped.begins_with("class_name ") and (" extends " in stripped):
		return true
	return stripped.begins_with("class ") and (" extends " in stripped)


# Split one line into code / string-literal / comment pieces, in order. Concatenating
# the piece texts reproduces the line. Single-line quotes only; a line-spanning
# triple-quoted string degrades to "string to end of line", which only ever makes the
# retype pass more conservative.
static func _line_pieces(line: String) -> Array:
	var pieces := []
	var start := 0
	var i := 0
	var n := line.length()
	while i < n:
		var ch := line[i]
		if ch == "#":
			if i > start:
				pieces.append({"text": line.substr(start, i - start), "kind": "code"})
			pieces.append({"text": line.substr(i), "kind": "comment"})
			return pieces
		if ch == "\"" or ch == "'":
			if i > start:
				pieces.append({"text": line.substr(start, i - start), "kind": "code"})
			var j := i + 1
			while j < n and line[j] != ch:
				j += 2 if line[j] == "\\" else 1
			j = mini(j, n - 1)
			pieces.append({"text": line.substr(i, j - i + 1), "kind": "string"})
			start = j + 1
			i = start
			continue
		i += 1
	if start < n:
		pieces.append({"text": line.substr(start), "kind": "code"})
	return pieces


# Matches a replaced core class used AS a class. The lookbehind rejects node-path and
# member tokens ($PointLight2D, %PointLight2D, Props/PointLight2D, x.PointLight2D):
# node NAMES often default to the class name, and conversion preserves names, so a
# path token must never be retyped.
static func _core_class_rx() -> RegEx:
	var rx := RegEx.new()
	rx.compile("(?<![$%%/.])\\b(%s)\\b" % "|".join(Maps.REPLACEMENTS.keys().map(
			func(k: StringName) -> String: return String(k))))
	return rx


# Lit global classes that are @tool scripts (all node classes; not LitSplashScreen).
static func _lit_tool_classes() -> Dictionary:
	var out := {}
	for entry in ProjectSettings.get_global_class_list():
		var epath := String(entry["path"])
		if epath.begins_with("res://addons/lit/") \
				and FileAccess.get_file_as_string(epath).begins_with("@tool"):
			out[String(entry["class"])] = true
	return out


static func _collect_gd(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_collect_gd(dir.path_join(d), out)


static func _lit_class_members(script_path: String) -> Dictionary:
	var script := load(script_path) as GDScript
	var out := {}
	if script == null:
		return out
	for m in script.get_script_method_list():
		out[String(m.name)] = true
	for p in script.get_script_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE != 0:
			out[String(p.name)] = true
	for s in script.get_script_signal_list():
		out[String(s.name)] = true
	for c in script.get_script_constant_map():
		out[String(c)] = true
	return out


static func _lit_scripts_by_path() -> Dictionary:
	var out := {}
	for klass in Migrations.BASELINE_SCHEMA:
		out[String(Migrations.BASELINE_SCHEMA[klass]["script"])] = klass
	return out


# Stored names on instance-provided nodes that would need remapping after the node's
# class converted: renamed sources and semantics-changed specials, not same-name
# direct copies (those keep applying natively).
static func _core_mapped_names() -> Dictionary:
	var out := {"light_mask": true}
	for core_class in Maps.REPLACEMENTS:
		var copy: Dictionary = Maps.REPLACEMENTS[core_class]["copy"]
		for src in copy:
			if src != copy[src]:
				out[String(src)] = true
		for src in Maps.REPLACEMENTS[core_class]["special"]:
			out[String(src)] = true
	return out


# UI ancestry: any ancestor typed as (or instancing a scene rooted in) Control or
# CanvasLayer marks a candidate as a menu/HUD node. Menu art must not join the world
# lighting uninvited, so these convert only when the menus checkbox opts in.
static func _is_ui_row(acc: Dictionary, by_path: Dictionary, path: String) -> bool:
	var cur := path
	var guard := 0
	while cur != "." and guard < 64:
		guard += 1
		cur = cur.get_base_dir()
		if cur.is_empty():
			break
		var row = by_path.get(cur)
		if row == null:
			continue
		var t := String(row["type"])
		if not t.is_empty():
			if _type_is_ui(t):
				return true
		elif not String(row["instance"]).is_empty() \
				and _scene_root_is_ui(acc, String(row["instance"])):
			return true
	return false


static func _type_is_ui(t: String) -> bool:
	return ClassDB.is_parent_class(t, "Control") or ClassDB.is_parent_class(t, "CanvasLayer")


static func _scene_root_is_ui(acc: Dictionary, scene_path: String, depth: int = 0) -> bool:
	if depth > 8 or not acc["model"].has(scene_path):
		return false
	var rows: Array = acc["model"][scene_path]["rows"]
	if rows.is_empty():
		return false
	var t := String(rows[0]["type"])
	if not t.is_empty():
		return _type_is_ui(t)
	if not String(rows[0]["instance"]).is_empty():
		return _scene_root_is_ui(acc, String(rows[0]["instance"]), depth + 1)
	return false


## Leaves-first over the instance graph, so child scenes convert before the parents
## that store overrides on them.
static func _topo_order(scene_paths: Array[String], model: Dictionary) -> Array[String]:
	var order: Array[String] = []
	var done := {}
	var visiting := {}
	var visit := func(path: String, self_ref: Callable) -> void:
		if done.has(path) or not model.has(path):
			return
		if visiting.has(path):
			push_warning("Lit: scene instance cycle at '%s'; processing in path order" % path)
			return
		visiting[path] = true
		for dep in model[path]["deps"]:
			self_ref.call(dep, self_ref)
		visiting.erase(path)
		done[path] = true
		order.append(path)
	for path in scene_paths:
		visit.call(path, visit)
	return order


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
	if kinds.get("scripts", true):
		rebased = _rebase_user_scripts(scripts, report)
		tooled = _add_tool_annotations(scripts, report)
		retyped = _retype_references(scripts, report)
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
		_reload_scripts(touched.keys())
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
	if _process_scene(scene_path, m, rctx["scan"], rctx["kinds"], rctx["rebased"],
			report, rctx["ctx"]):
		rctx["changed_scenes"].append(scene_path)
		report.append("SAVED")
	else:
		report.append("UNCHANGED")


static func run_finish(rctx: Dictionary) -> Dictionary:
	var report: Array = rctx["report"]
	_report_material_notes(rctx["scan"], rctx["ctx"], report)
	var saved := _write_report(report, rctx["scan"], rctx["changed_scenes"],
			rctx["report_path"])
	return {"changed_scenes": rctx["changed_scenes"], "report": report, "report_saved": saved,
		"rebased_scripts": rctx["rewritten"], "tooled_scripts": rctx["tooled"],
		"retyped_scripts": rctx["retyped"]}


static func _uses_rebased(m: Dictionary, rebased: Dictionary) -> bool:
	for row in m["rows"]:
		if rebased.has(row["script"]):
			return true
	return false


static func _report_material_notes(scan_result: Dictionary, ctx: Dictionary,
		report: Array) -> void:
	var unlit: Array = scan_result["unlit_nodes"]
	if not unlit.is_empty():
		report.append("--- deliberately unlit materials (already Lit-native; left as-is)")
		report.append("UNLIT %d nodes keep unshaded/blend materials and compose over the lighting:"
				% unlit.size())
		for i in mini(unlit.size(), 8):
			report.append("    " + unlit[i])
		if unlit.size() > 8:
			report.append("    ... and %d more" % (unlit.size() - 8))
	if not ctx["custom"].is_empty():
		var shader_paths: Array = ctx["custom"].keys()
		shader_paths.sort()
		for sp in shader_paths:
			var nodes: Array = ctx["custom"][sp]
			report.append("MANUAL custom material %s: %d nodes kept as-is; pick a pattern "
					% [sp, nodes.size()] + "from the Custom Shaders docs page (post-light "
					+ "CanvasGroup, albedo pre-pass, unlit overlay child, or receiver emissive)")
			for node_where in nodes:
				report.append("    " + node_where)


## Rewrite the extends line of each collision-free chain root, then force-reload the
## whole chain so the scene pass compiles against the Lit base. Returns every script
## path whose chain now roots in a Lit class.
static func _rebase_user_scripts(scripts: Dictionary, report: Array) -> Dictionary:
	for skipped in scripts["skipped"]:
		report.append("SKIPPED-COLLISION %s: member names collide with the Lit class; "
				% skipped["root"] + "rebase manually (rename the members, and have "
				+ "_process call super._process(delta)):")
		for line in skipped["collisions"]:
			report.append("    " + line)
	for path in scripts["inner"]:
		report.append("MANUAL %s: an inner class extends a rebasable core class; "
				% path + "inner classes are left untouched")
	for root_path in scripts["roots"]:
		var core: String = scripts["chains"][root_path]["core"]
		var f := FileAccess.open(root_path, FileAccess.READ)
		if f == null:
			report.append("ERROR could not read %s" % root_path)
			continue
		var lines := f.get_as_text().split("\n")
		f = null
		for i in lines.size():
			if _extends_token(String(lines[i]).rstrip("\r")) == core:
				lines[i] = String(lines[i]).replace("extends " + core,
						"extends " + Maps.REBASES[core]["lit_class"])
				break
		var w := FileAccess.open(root_path, FileAccess.WRITE)
		if w == null:
			report.append("ERROR could not write %s" % root_path)
			continue
		w.store_string("\n".join(lines))
		w = null
		report.append("REBASED %s: extends %s -> extends %s"
				% [root_path, core, Maps.REBASES[core]["lit_class"]])
	var out := {}
	for root_path in scripts["roots"]:
		for p in scripts["chains"][root_path]["scripts"]:
			out[p] = true
	return out


## Prepend @tool to every script whose chain roots in a @tool Lit class: without it the
## editor gives instances a placeholder script whose lifecycle never runs, and every
## load warns MISSING_TOOL.
static func _add_tool_annotations(scripts: Dictionary, report: Array) -> Array:
	var targets := {}
	for p in scripts["rebase_all"]:
		targets[p] = true
	for p in scripts["lit_tool_rooted"]:
		targets[p] = true
	var paths: Array = targets.keys()
	paths.sort()
	var changed: Array = []
	for path in paths:
		if not scripts["no_tool"].has(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		var w := FileAccess.open(path, FileAccess.WRITE)
		if w == null:
			report.append("ERROR could not write %s" % path)
			continue
		w.store_string("@tool" + ("\r\n" if "\r\n" in text else "\n") + text)
		w = null
		changed.append(path)
		report.append("TOOLED %s: @tool added so the script runs in the editor like its "
				% path + "Lit base; guard editor-unsafe logic with Engine.is_editor_hint()")
	return changed


## Rewrite references to replaced core classes (annotations, casts, `is` checks, .new()
## calls) to the Lit classes. Extends declarations stay core (a script deliberately
## extending a core light was skipped node-side), and string literals are only reported:
## class-name lookups against converted nodes stop matching either way.
static func _retype_references(scripts: Dictionary, report: Array) -> Array:
	var targets := {}
	for path in scripts["core_refs"]:
		targets[path] = true
	for path in scripts["string_refs"]:
		targets[path] = true
	var rx := _core_class_rx()
	var paths: Array = targets.keys()
	paths.sort()
	var changed: Array = []
	for path in paths:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		var count := 0
		var string_lines: Array[String] = []
		for li in lines.size():
			var line := String(lines[li])
			if _is_extends_decl(line.strip_edges()):
				continue
			var rebuilt := ""
			var line_hit := false
			for piece in _line_pieces(line):
				var text: String = piece["text"]
				if piece["kind"] == "code" and rx.search(text) != null:
					count += rx.search_all(text).size()
					rebuilt += rx.sub(text, "Lit$1", true)
					line_hit = true
				else:
					if piece["kind"] == "string" and rx.search(text) != null:
						string_lines.append(str(li + 1))
					rebuilt += text
			if line_hit:
				lines[li] = rebuilt
		if count > 0:
			var w := FileAccess.open(path, FileAccess.WRITE)
			if w == null:
				report.append("ERROR could not write %s" % path)
				continue
			w.store_string("\n".join(lines))
			w = null
			changed.append(path)
			report.append("RETYPED %s: %d core-type references now use the Lit classes"
					% [path, count])
		if not string_lines.is_empty():
			report.append("MANUAL %s: string literals name core classes (line %s); "
					% [path, ", ".join(string_lines)]
					+ "node-name paths (get_node) still resolve since names are preserved, but "
					+ "class-name lookups (find_children/is_class) no longer match converted nodes")
	return changed


# reload() recompiles the in-memory source, which a cache replace does not refresh;
# re-source from disk explicitly so the rewritten text takes.
static func _reload_scripts(paths: Array) -> void:
	paths.sort()
	for p in paths:
		var s := load(p) as GDScript
		if s != null:
			s.source_code = FileAccess.get_file_as_string(p)
			s.reload()


static func _process_scene(scene_path: String, m: Dictionary, scan_result: Dictionary,
		kinds: Dictionary, rebased: Dictionary, report: Array, ctx: Dictionary) -> bool:
	var packed := ResourceLoader.load(scene_path, "PackedScene",
			ResourceLoader.CACHE_MODE_REPLACE_DEEP) as PackedScene
	if packed == null:
		report.append("ERROR could not load scene")
		return false
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root == null:
		report.append("ERROR could not instantiate scene")
		return false

	var changed := false
	var lit_by_script := _lit_scripts_by_path()
	var core_names := _core_mapped_names()
	var current: String = scan_result["current"]
	var converted_paths: Array[NodePath] = []
	var stamped := 0

	for row in m["rows"]:
		if row["placeholder"]:
			var ph := root.get_node_or_null(row["path"])
			if ph is InstancePlaceholder:
				_materialize_placeholder(root, ph as InstancePlaceholder)
			for stored_name in row["props"]:
				if core_names.has(stored_name):
					report.append("MANUAL %s: instance placeholder stores `%s`; load and "
							% [row["path"], stored_name] + "re-save it after its scene converts")
			continue
		var node := root.get_node_or_null(row["path"])
		if node == null:
			continue
		var row_type := String(row["type"])
		var row_script := String(row["script"])

		if row.get("ui", false) and not kinds.get("menus", false):
			continue
		if not row_type.is_empty() and Maps.REPLACEMENTS.has(row_type):
			if not row_script.is_empty():
				report.append("SKIPPED %s: %s has a custom script; convert manually"
						% [row["path"], row_type])
			elif _kind_on(kinds, row_type):
				if node == root and m["inherited"]:
					report.append("SKIPPED %s: inherited-scene root; convert in the base scene"
							% row["path"])
				else:
					var was_root := node == root
					var new_node := _convert_replacing(root, node, row, current, report)
					if new_node != null:
						converted_paths.append(row["path"])
						changed = true
						if was_root:
							root = new_node
		elif not row_type.is_empty() and Maps.SWAPS.has(row_type) and row_script.is_empty() \
				and _kind_on(kinds, row_type):
			if _convert_receiver(node, Maps.SWAPS[row_type], row, current, report):
				converted_paths.append(row["path"])
				changed = true
		elif rebased.has(row_script):
			if _receiver_fixups(node, row, current, report, ctx):
				changed = true
			converted_paths.append(row["path"])
		elif lit_by_script.has(row_script):
			if Migrations.apply_chain(node, lit_by_script[row_script], row["props"], report):
				changed = true
			if str(node.get(&"lit_version")) != current:
				node.set(&"lit_version", current)
				stamped += 1
				changed = true

	for row in m["rows"]:
		if not String(row["type"]).is_empty() or row["placeholder"]:
			continue
		var node := root.get_node_or_null(row["path"])
		if node == null:
			continue
		if _remap_overrides(node, row, report):
			changed = true

	if _remap_animation_tracks(root, report):
		changed = true

	if stamped > 0:
		report.append("STAMPED %d Lit nodes at v%s" % [stamped, current])

	var ok := true
	if changed:
		var out := PackedScene.new()
		if out.pack(root) != OK:
			report.append("ERROR pack failed; scene not saved")
			ok = false
		else:
			var out_paths := {}
			var out_state := out.get_state()
			for i in out_state.get_node_count():
				out_paths[out_state.get_node_path(i)] = true
			for p in converted_paths:
				if not out_paths.has(p):
					report.append("ERROR converted node %s missing after pack; scene not saved" % p)
					ok = false
			if ok and ResourceSaver.save(out, scene_path) != OK:
				report.append("ERROR save failed")
				ok = false
	root.free()
	return changed and ok


# Outside the editor, placeholder rows instantiate as InstancePlaceholder objects,
# which pack() cannot serialize back. Swap in a real instance flagged as a load
# placeholder (what the editor itself produces) so the scene round-trips.
static func _materialize_placeholder(root: Node, ph: InstancePlaceholder) -> void:
	var packed := load(ph.get_instance_path()) as PackedScene
	if packed == null:
		return
	var real := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if real == null:
		return
	real.set_scene_instance_load_placeholder(true)
	var parent := ph.get_parent()
	var index := ph.get_index()
	var ph_name := ph.name
	var stored: Dictionary = ph.get_stored_values()
	parent.remove_child(ph)
	real.name = ph_name
	parent.add_child(real)
	parent.move_child(real, index)
	real.owner = root
	for k in stored:
		real.set(k, stored[k])
	ph.free()


static func _kind_on(kinds: Dictionary, core_type: String) -> bool:
	match core_type:
		"PointLight2D", "DirectionalLight2D":
			return kinds.get("lights", true)
		"CanvasModulate":
			return kinds.get("modulates", true)
		"Sprite2D":
			return kinds.get("sprites", true)
		"TileMapLayer":
			return kinds.get("tilemaps", true)
	return false


# --- Node replacement ----------------------------------------------------------

static func _convert_replacing(root: Node, old: Node, row: Dictionary, current: String,
		report: Array) -> Node:
	var core_class := String(row["type"])
	var spec: Dictionary = Maps.REPLACEMENTS[core_class]
	var stored: Dictionary = row["props"]

	var old_name := old.name
	var parent := old.get_parent()
	var index := old.get_index()
	var unique := old.unique_name_in_owner
	# Release the owner's unique-name slot while old is still owned, or the
	# replacement's acquisition conflicts with the detached node's registration.
	old.unique_name_in_owner = false
	var incoming := _persisted_incoming(old)
	var outgoing := _persisted_outgoing(old)
	var children := old.get_children()
	var desc_state := {}
	for d in old.find_children("*", "", true, false):
		desc_state[d] = {"owner": d.owner, "unique": d.unique_name_in_owner,
			"editable": d.owner == root and not String(d.scene_file_path).is_empty() \
					and root.is_editable_instance(d)}

	var new_node := Node2D.new()
	new_node.set_script(load(spec["script"]))

	if parent != null:
		parent.remove_child(old)
		new_node.name = old_name
		parent.add_child(new_node)
		parent.move_child(new_node, index)
		new_node.owner = root
		new_node.unique_name_in_owner = unique
	else:
		new_node.name = old_name

	for p in Maps.COPY_LIVE:
		new_node.set(p, old.get(p))
	for src in spec["copy"]:
		new_node.set(spec["copy"][src], old.get(src))
	_apply_specials(core_class, new_node, old, stored, row["path"], report)
	_report_dropped(core_class, spec, stored, row["path"], report)

	for g in row["groups"]:
		new_node.add_to_group(g, true)
	for meta_name in old.get_meta_list():
		new_node.set_meta(meta_name, old.get_meta(meta_name))

	var effective_root := new_node if parent == null else root
	for c in children:
		old.remove_child(c)
		c.owner = null
		new_node.add_child(c)
	for d in desc_state:
		var owner_was: Node = desc_state[d]["owner"]
		d.owner = effective_root if (owner_was == old or owner_was == root) else owner_was
		if desc_state[d]["unique"]:
			d.unique_name_in_owner = true
		if desc_state[d]["editable"]:
			effective_root.set_editable_instance(d, true)

	_rewire_connections(old, new_node, incoming, outgoing, row["path"], report)
	old.free()
	new_node.set(&"lit_version", current)
	report.append("CONVERTED %s: %s -> %s" % [row["path"], core_class, spec["lit_class"]])
	return new_node


static func _persisted_incoming(old: Node) -> Array:
	var out := []
	for c in old.get_incoming_connections():
		if c["flags"] & Object.CONNECT_PERSIST != 0:
			out.append(c)
	return out


static func _persisted_outgoing(old: Node) -> Array:
	var out := []
	for s in old.get_signal_list():
		for c in old.get_signal_connection_list(s.name):
			if c["flags"] & Object.CONNECT_PERSIST != 0:
				out.append(c)
	return out


static func _rewire_connections(old: Node, new_node: Node, incoming: Array, outgoing: Array,
		path: NodePath, report: Array) -> void:
	for c in incoming:
		var sig: Signal = c["signal"]
		var cal: Callable = c["callable"]
		sig.disconnect(cal)
		if new_node.has_method(cal.get_method()):
			var to := Callable(new_node, cal.get_method())
			var bound := cal.get_bound_arguments()
			if not bound.is_empty():
				to = to.bindv(bound)
			sig.connect(to, c["flags"])
		else:
			report.append("DROPPED-CONNECTION %s: -> %s.%s (method not on the Lit node)"
					% [path, new_node.name, cal.get_method()])
	for c in outgoing:
		var sig: Signal = c["signal"]
		var cal: Callable = c["callable"]
		if new_node.has_signal(sig.get_name()):
			var out_sig := Signal(new_node, sig.get_name())
			if not out_sig.is_connected(cal):
				out_sig.connect(cal, c["flags"])
		else:
			report.append("DROPPED-CONNECTION %s: %s -> %s (signal not on the Lit node)"
					% [path, sig.get_name(), cal.get_method()])


static func _apply_specials(core_class: String, new_node: Node, old: Node,
		stored: Dictionary, path: NodePath, report: Array) -> void:
	var spec: Dictionary = Maps.REPLACEMENTS[core_class]
	if spec["special"].has(&"blend_mode"):
		var blend := int(old.get("blend_mode"))
		if blend > 1:
			report.append("CLAMPED %s: blend_mode MIX has no Lit equivalent; using ADD" % path)
			blend = 0
		new_node.set("blend_mode", blend)
	if spec["special"].has(&"shadow_color") and bool(old.get("shadow_enabled")):
		var sc: Color = old.get("shadow_color")
		var mapped := _map_shadow_color(sc)
		new_node.set("shadow_color", mapped)
		if sc != CORE_SHADOW_DEFAULT:
			report.append("APPROX %s: shadow_color %s mapped to Lit tint %s" % [path, sc, mapped])
		else:
			report.append("APPROX %s: core shadows were invisible (alpha 0); kept invisible "
					% path + "via a white tint - set shadow_color black in Lit for visible shadows")
	if spec["special"].has(&"height") and stored.has("height"):
		report.append("KEPT-DEFAULT %s: core height %.2f (0..1 factor) has no Lit "
				% [path, float(stored["height"])] + "equivalent; Lit height stays at its default")
	if spec["special"].has(&"range"):
		var tex := old.get("texture") as Texture2D
		if tex != null:
			var tex_range := maxf(tex.get_size().x, tex.get_size().y) * 0.5 \
					* float(old.get("texture_scale"))
			new_node.set("range", tex_range)
			new_node.set("falloff", 0.0)
			report.append("HEURISTIC %s: range %.0f from the cookie footprint, falloff 0 "
					% [path, tex_range] + "so the cookie alone shapes the light (core behavior)")
		else:
			report.append("HEURISTIC %s: no texture (the core light rendered nothing); "
					% path + "Lit renders analytically at the default range")


## Behavior-preserving shadow_color: core mixes shadowed light toward rgb by alpha,
## Lit tints shadowed light by rgb.
static func _map_shadow_color(sc: Color) -> Color:
	return Color(1.0 - sc.a + sc.r * sc.a, 1.0 - sc.a + sc.g * sc.a,
			1.0 - sc.a + sc.b * sc.a, 1.0)


static func _report_dropped(core_class: String, spec: Dictionary, stored: Dictionary,
		path: NodePath, report: Array) -> void:
	for stored_name in stored:
		if stored_name == "script" or stored_name == "unique_name_in_owner" \
				or String(stored_name).begins_with("metadata/"):
			continue
		if spec["copy"].has(stored_name) or spec["special"].has(StringName(stored_name)):
			continue
		if Maps.COPY_LIVE.has(StringName(stored_name)) \
				or Maps.CONSUMED_ALIASES.has(StringName(stored_name)):
			continue
		report.append("DROPPED %s: %s.%s = %s (no Lit equivalent)"
				% [path, core_class, stored_name, stored[stored_name]])


# --- In-place receiver conversion ----------------------------------------------

## What sits in the material slot decides the conversion path:
##  none            - convert; the Lit _init supplies the receiver material.
##  receiver        - already carries a Lit receiver ShaderMaterial ("Make Selected
##                    Nodes Lit" output); convert keeping it, syncing exports from it.
##  default_canvas  - a CanvasItemMaterial with default behavior; drop it and convert.
##  unlit           - deliberately unlit (unshaded/blend CanvasItemMaterial, or a
##                    shader declaring render_mode unshaded): already Lit-native as an
##                    overlay that composes above the lighting; left as-is.
##  custom          - a custom shader; can't be fused automatically, grouped in the
##                    report with the Custom Shaders pattern menu.
static func _classify_material(mat: Material) -> Dictionary:
	if mat == null:
		return {"kind": "none"}
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if LitShaderLibrary.flags_of(sh) >= 0:
			return {"kind": "receiver"}
		if sh != null:
			var rx := RegEx.new()
			rx.compile("(?m)^\\s*render_mode[^;]*\\bunshaded\\b")
			if rx.search(sh.code) != null:
				return {"kind": "unlit", "why": "shader declares render_mode unshaded"}
		var shader_path := "<embedded shader>"
		if sh != null and not sh.resource_path.is_empty():
			shader_path = sh.resource_path
		elif not mat.resource_path.is_empty():
			shader_path = mat.resource_path
		return {"kind": "custom", "shader": shader_path}
	if mat is CanvasItemMaterial:
		var cm := mat as CanvasItemMaterial
		if cm.blend_mode == CanvasItemMaterial.BLEND_MODE_MIX \
				and cm.light_mode == CanvasItemMaterial.LIGHT_MODE_NORMAL \
				and not cm.particles_animation:
			return {"kind": "default_canvas"}
		return {"kind": "unlit", "why": "unshaded/blended CanvasItemMaterial"}
	return {"kind": "custom", "shader": mat.get_class()}


## Sprite2D/TileMapLayer conversion candidate. Returns true when the node changed.
static func _convert_receiver(node: Node, script_path: String, row: Dictionary,
		current: String, report: Array) -> bool:
	var core_class := node.get_class()
	var cls := _classify_material((node as CanvasItem).material)
	match cls["kind"]:
		"unlit", "custom":
			return false  # collected scan-side for the grouped material notes
		"default_canvas":
			node.set("material", null)
	var mask := (node as CanvasItem).light_mask
	node.set_script(load(script_path))
	if cls["kind"] == "receiver":
		_sync_exports_from_material(node)
		report.append("CONVERTED %s: %s -> Lit%s (kept its receiver material)"
				% [row["path"], core_class, core_class])
	else:
		node.set("receiver_mask", mask)
		report.append("CONVERTED %s: %s -> Lit%s (receiver_mask %d from light_mask%s)"
				% [row["path"], core_class, core_class, mask,
				"; default material dropped" if cls["kind"] == "default_canvas" else ""])
	_wrap_texture(node)
	node.set(&"lit_version", current)
	return true


## A pre-existing receiver material is authoritative: land its per-node params on the
## new Lit exports (the setters write the same values straight back).
static func _sync_exports_from_material(node: Node) -> void:
	var mat := (node as CanvasItem).material as ShaderMaterial
	for pair in [["receiver_mask", &"receiver_mask"], ["emissive_strength", &"emissive_strength"],
			["self_shadow", &"self_shadow"], ["rx_mask", &"shadow_ignore_mask"]]:
		var v: Variant = mat.get_shader_parameter(pair[0])
		if v != null:
			node.set(pair[1], v)


static func _note_custom(ctx: Dictionary, shader_path: String, path: NodePath) -> void:
	if not ctx["custom"].has(shader_path):
		ctx["custom"][shader_path] = []
	ctx["custom"][shader_path].append("%s %s" % [ctx["scene"], path])


## Node whose user script chain roots in a Lit base (rebased this run, or already
## Lit-based from an earlier one). Never relies on the Lit _init having run: in the
## editor, non-@tool user scripts get placeholder script instances whose lifecycle
## callbacks never fire, so the receiver material must land explicitly.
static func _receiver_fixups(node: Node, row: Dictionary, current: String,
		report: Array, ctx: Dictionary) -> bool:
	if node.get(&"receiver_mask") == null:
		report.append("ERROR %s: rebased script not yet compiled against the Lit base; "
				% row["path"] + "restart the editor and run the update again")
		return false
	var changed := false
	var cls := _classify_material(row["props"].get("material"))
	match cls["kind"]:
		"unlit":
			report.append("UNLIT %s: rebased-script node keeps its material (%s) and "
					% [row["path"], cls["why"]] + "composes over the lighting")
		"custom":
			_note_custom(ctx, cls["shader"], row["path"])
		"receiver":
			_sync_exports_from_material(node)
			if _wrap_texture(node):
				changed = true
		_:
			if cls["kind"] == "default_canvas" or (node as CanvasItem).material == null:
				node.set("material", _fresh_receiver_material(node))
				changed = true
			var mask := (node as CanvasItem).light_mask
			if int(node.get(&"receiver_mask")) != mask:
				node.set(&"receiver_mask", mask)
				changed = true
			if _wrap_texture(node):
				changed = true
	if str(node.get(&"lit_version")) != current:
		node.set(&"lit_version", current)
		changed = true
	if changed:
		report.append("CONVERTED %s: rebased-script node joined the Lit pipeline" % row["path"])
	return changed


## Mirrors the receiver material the Lit _init would have created had the slot been
## empty at load.
static func _fresh_receiver_material(node: Node) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
	for pair in [["emissive_strength", &"emissive_strength"],
			["receiver_mask", &"receiver_mask"], ["self_shadow", &"self_shadow"]]:
		mat.set_shader_parameter(pair[0], node.get(pair[1]))
	return mat


static func _wrap_texture(node: Node) -> bool:
	var tex = node.get("texture")
	if tex is Texture2D and not (tex is CanvasTexture):
		var ct := CanvasTexture.new()
		ct.diffuse_texture = tex
		node.set("texture", ct)
		return true
	return false


# --- Instance-override remap ----------------------------------------------------

## Stored overrides on instance-provided nodes whose class converted (this run or a
## prior one): renamed properties are re-applied under their new names, same-name
## properties with changed semantics are corrected. Godot already dropped the stale
## stored values while loading, so everything is re-derived from the scan capture.
static func _remap_overrides(node: Node, row: Dictionary, report: Array) -> bool:
	var script := node.get_script() as Script
	var script_path := "" if script == null else script.resource_path
	var stored: Dictionary = row["props"]
	var changed := false

	var core_class := _replacement_core_for(script_path)
	if not core_class.is_empty():
		var spec: Dictionary = Maps.REPLACEMENTS[core_class]
		for src in spec["copy"]:
			var dst: StringName = spec["copy"][src]
			if src != dst and stored.has(String(src)) \
					and _set_changed(node, dst, stored[String(src)]):
				changed = true
				report.append("REMAPPED-OVERRIDE %s: %s -> %s" % [row["path"], src, dst])
		if stored.has("light_mask") and not stored.has("range_item_cull_mask") \
				and _set_changed(node, "light_mask", 1):
			changed = true
			report.append("DROPPED %s: light_mask override had no core meaning on a light; reset" % row["path"])
		if stored.has("range_item_cull_mask") \
				and _set_changed(node, "light_mask", stored["range_item_cull_mask"]):
			changed = true
			report.append("REMAPPED-OVERRIDE %s: range_item_cull_mask -> light_mask" % row["path"])
		if spec["special"].has(&"blend_mode") and stored.has("blend_mode") \
				and int(stored["blend_mode"]) > 1 and _set_changed(node, "blend_mode", 0):
			changed = true
			report.append("CLAMPED %s: blend_mode MIX override; using ADD" % row["path"])
		if spec["special"].has(&"shadow_color") and stored.has("shadow_color") \
				and _set_changed(node, "shadow_color", _map_shadow_color(stored["shadow_color"])):
			changed = true
			report.append("APPROX %s: shadow_color override mapped to a Lit tint" % row["path"])
		if spec["special"].has(&"height") and stored.has("height") and _set_changed(node,
				"height", Migrations.BASELINE_SCHEMA[spec["lit_class"]]["props"][&"height"]["default"]):
			changed = true
			report.append("KEPT-DEFAULT %s: core height override has no Lit equivalent; reset" % row["path"])
	elif _is_receiver_script(script_path) and stored.has("light_mask"):
		if _set_changed(node, &"receiver_mask", stored["light_mask"]):
			changed = true
			report.append("REMAPPED-OVERRIDE %s: light_mask -> receiver_mask" % row["path"])
	return changed


static func _set_changed(node: Node, prop: StringName, value: Variant) -> bool:
	if node.get(prop) == value:
		return false
	node.set(prop, value)
	return true


static func _replacement_core_for(script_path: String) -> String:
	for core_class in Maps.REPLACEMENTS:
		if String(Maps.REPLACEMENTS[core_class]["script"]) == script_path:
			return String(core_class)
	return ""


static func _is_receiver_script(script_path: String) -> bool:
	if script_path.is_empty():
		return false
	if Maps.SWAPS.values().has(script_path):
		return true
	var script := load(script_path) as Script
	while script != null:
		if Maps.SWAPS.values().has(script.resource_path):
			return true
		script = script.get_base_script()
	return false


# --- Animation track remap ------------------------------------------------------

## Rename embedded animation tracks that drive renamed properties on converted nodes
## (e.g. "Light:offset" -> "Light:texture_offset"). External animation resources are
## reported for manual fixing, never rewritten.
static func _remap_animation_tracks(root: Node, report: Array) -> bool:
	var changed := false
	var players: Array[Node] = []
	for p in root.find_children("*", "AnimationPlayer", true, false):
		# Instance-provided players are handled in their own scene; walking them here
		# would duplicate their notes on every parent.
		if p.owner == root:
			players.append(p)
	if root is AnimationPlayer:
		players.append(root)
	for player in players:
		var base := player.get_node_or_null((player as AnimationPlayer).root_node)
		if base == null:
			continue
		for lib_name in (player as AnimationPlayer).get_animation_library_list():
			var lib := (player as AnimationPlayer).get_animation_library(lib_name)
			var lib_external := not lib.resource_path.is_empty() \
					and not ("::" in lib.resource_path)
			for anim_name in lib.get_animation_list():
				var anim := lib.get_animation(anim_name)
				var anim_external := lib_external or (not anim.resource_path.is_empty() \
						and not ("::" in anim.resource_path))
				for t in anim.get_track_count():
					var track_path := anim.track_get_path(t)
					if track_path.get_subname_count() == 0:
						continue
					var target := base.get_node_or_null(
							NodePath(track_path.get_concatenated_names()))
					if target == null:
						continue
					if target.get_script() == null:
						continue
					var core_class := _replacement_core_for(
							(target.get_script() as Script).resource_path)
					if core_class.is_empty():
						continue
					var renames := {}
					var spec: Dictionary = Maps.REPLACEMENTS[core_class]
					for src in spec["copy"]:
						if src != spec["copy"][src]:
							renames[String(src)] = String(spec["copy"][src])
					var first := String(track_path.get_subname(0))
					if renames.has(first):
						if anim_external:
							report.append("MANUAL %s/%s: external animation drives `%s` on a "
									% [player.name, anim_name, first]
									+ "converted node; rename the track by hand")
							continue
						var subs := PackedStringArray()
						subs.append(renames[first])
						for si in range(1, track_path.get_subname_count()):
							subs.append(track_path.get_subname(si))
						anim.track_set_path(t, NodePath("%s:%s"
								% [track_path.get_concatenated_names(), ":".join(subs)]))
						changed = true
						report.append("REMAPPED-TRACK %s/%s: %s -> %s"
								% [player.name, anim_name, first, renames[first]])
					elif first == "height" and spec["special"].has(&"height"):
						report.append("MANUAL %s/%s: animation drives core `height` on a "
								% [player.name, anim_name] + "converted node (units differ in Lit)")
	return changed


# --- Report ---------------------------------------------------------------------

## The report leads with everything that was NOT auto-migratable, fenced and padded
## so it can be copy/pasted straight into a task list; the chronological per-scene
## log follows. Flagged lines pulled out of a scene block get the scene appended so
## they stay self-contained.
static func _write_report(report: Array, scan_result: Dictionary,
		changed_scenes: Array, report_path: String) -> bool:
	var f := FileAccess.open(report_path, FileAccess.WRITE)
	if f == null:
		push_warning("Lit: could not write '%s'" % report_path)
		return false
	var attention: Array[String] = []
	var log: Array[String] = []
	var scene := ""
	var i := 0
	while i < report.size():
		var line := String(report[i])
		if line.begins_with("--- "):
			var head := line.trim_prefix("--- ")
			scene = head if head.ends_with(".tscn") or head.ends_with(".scn") else ""
		if _is_flagged(line):
			attention.append(line if scene.is_empty() else "%s  (%s)" % [line, scene])
			var j := i + 1
			while j < report.size() and String(report[j]).begins_with("    "):
				attention.append(report[j])
				j += 1
			i = j
			continue
		log.append(line)
		i += 1
	var c: Dictionary = scan_result["counts"]
	f.store_line("Update Project to Lit %s - %d scenes scanned, %d rewritten"
			% [scan_result["current"], c["scenes"], changed_scenes.size()])
	f.store_line("")
	if not attention.is_empty():
		var items := 0
		for line in attention:
			if not line.begins_with("    "):
				items += 1
		f.store_line("")
		f.store_line("=".repeat(72))
		f.store_line("NEEDS YOUR ATTENTION - %d items were not auto-migratable" % items)
		f.store_line("=".repeat(72))
		f.store_line("")
		for line in attention:
			f.store_line(line)
		f.store_line("")
		f.store_line("=".repeat(72))
		f.store_line("")
		f.store_line("")
	for line in log:
		f.store_line(line)
	return true


static func _is_flagged(line: String) -> bool:
	return line.begins_with("MANUAL") or line.begins_with("SKIPPED") \
			or line.begins_with("CAUTION") or line.begins_with("ERROR") \
			or line.begins_with("DROPPED-CONNECTION")
