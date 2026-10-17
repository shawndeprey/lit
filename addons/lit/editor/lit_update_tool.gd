@tool
extends RefCounted

## Engine behind "Update Project to Lit X.Y.Z" (Project > Tools): brings every Lit node
## in the project to the installed version through the migration chain under
## lit_update_tool/migrations/ and stamps `lit_version`. Lit node data only - scripts
## and node types are never touched. Core Godot nodes are counted so the dialog can
## point at "Port Project to Lit" (lit_port_tool.gd), the one-time conversion.
##
## scan() reads every scene through SceneState (no scene code runs). run() loads each
## scene that needs it off-tree, migrates and stamps its Lit nodes, re-applies renamed
## properties stored as instance overrides and embedded animation tracks, then packs
## and saves. A scene is skipped whole when saving it would lose data: it holds a node
## stamped newer than this plugin, or it stores a value no live property and no
## migration accounts for.

const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")

const REPORT_PATH := "res://lit_update_report.txt"
const PORT_CANDIDATES := ["PointLight2D", "DirectionalLight2D", "CanvasModulate",
	"Sprite2D", "AnimatedSprite2D", "TileMapLayer"]


# --- Scan ----------------------------------------------------------------------

## Read-only project model. `roots` narrows the walk; `migs` replaces the registered
## migrations (tests inject synthetic chains).
static func scan(roots: Array[String] = ["res://"], migs: Variant = null) -> Dictionary:
	var acc := scan_begin(roots, migs)
	for p in acc["scene_paths"]:
		scan_scene(acc, p)
	return scan_finish(acc)


static func scan_begin(roots: Array[String] = ["res://"], migs: Variant = null) -> Dictionary:
	var collected: Array[String] = []
	for root in roots:
		LitShaderPrecompilerScript._collect_scenes(root, collected)
	var scene_paths: Array[String] = []
	for p in collected:
		if not p.begins_with("res://addons"):
			scene_paths.append(p)
	var by_script := {}
	for klass in Migrations.BASELINE_SCHEMA:
		if Migrations.BASELINE_SCHEMA[klass]["props"].has(&"lit_version"):
			by_script[String(Migrations.BASELINE_SCHEMA[klass]["script"])] = klass
	return {
		"scene_paths": scene_paths,
		"lit_by_script": by_script,
		"current": Migrations.current_version(),
		"retired": Migrations.retired_names(migs),
		"class_cache": {},
		"model": {},
		"counts": {"scenes": scene_paths.size(), "lit_nodes": 0, "lit_current": 0, "newer": 0,
			"override_rows": 0, "track_rows": 0, "core_nodes": 0,
			"scenes_to_process": 0, "scenes_skipped": 0},
	}


static func scan_scene(acc: Dictionary, scene_path: String) -> void:
	var counts: Dictionary = acc["counts"]
	var current: String = acc["current"]
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("Lit: update scan could not load '%s'; skipped" % scene_path)
		return
	var state := packed.get_state()
	var rows: Array[Dictionary] = []
	var deps := {}
	var needs := false
	var newer := false
	var older := 0
	for i in state.get_node_count():
		var props := {}
		for p in state.get_node_property_count(i):
			props[String(state.get_node_property_name(i, p))] = state.get_node_property_value(i, p)
		var script = props.get("script")
		var script_path := (script as Script).resource_path if script is Script else ""
		var instance_path := ""
		var inst := state.get_node_instance(i)
		if inst != null:
			instance_path = inst.resource_path
		elif state.is_node_instance_placeholder(i):
			instance_path = state.get_node_instance_placeholder(i)
		var row := {
			"path": state.get_node_path(i),
			"type": String(state.get_node_type(i)),
			"script": script_path,
			"instance": instance_path,
			"placeholder": state.is_node_instance_placeholder(i),
			"props": props,
			"klass": lit_class_of(acc, script_path),
		}
		rows.append(row)
		if not instance_path.is_empty():
			deps[instance_path] = true
		if row["klass"] != &"":
			var cmp := Migrations.semver_cmp(stored_version(props), current)
			if cmp < 0:
				older += 1
				needs = true
			elif cmp > 0:
				counts["newer"] += 1
				newer = true
			else:
				counts["lit_current"] += 1
		elif script_path.is_empty() and PORT_CANDIDATES.has(row["type"]):
			counts["core_nodes"] += 1
	acc["model"][scene_path] = {"rows": rows, "deps": deps.keys(), "needs": needs, "newer": newer,
		"older": older}


## Retired names on instance overrides and animation tracks resolve against the
## complete model, so they are classified here rather than per scene.
static func scan_finish(acc: Dictionary) -> Dictionary:
	var counts: Dictionary = acc["counts"]
	var model: Dictionary = acc["model"]
	var retired: Dictionary = acc["retired"]
	for scene_path in model:
		var m: Dictionary = model[scene_path]
		for row in m["rows"]:
			if String(row["type"]).is_empty():
				var src := _source_row(m["rows"], model, _rel(row["path"]))
				var klass: Variant = src["klass"] if not src.is_empty() else null
				if not _retired_on(row["props"], klass, retired).is_empty():
					counts["override_rows"] += 1
					m["needs"] = true
			elif ClassDB.is_parent_class(row["type"], "AnimationMixer") \
					and _tracks_retired(m["rows"], model, row, retired):
				counts["track_rows"] += 1
				m["needs"] = true
	for scene_path in model:
		var m: Dictionary = model[scene_path]
		if m["newer"]:
			counts["scenes_skipped"] += 1
		elif m["needs"]:
			counts["scenes_to_process"] += 1
			counts["lit_nodes"] += m["older"]
	return {"order": _topo_order(acc["scene_paths"], model), "model": model,
		"counts": counts, "current": acc["current"], "retired": retired,
		"lit_by_script": acc["lit_by_script"], "class_cache": acc["class_cache"]}


## The versioned Lit class a script gives its node, through user subclasses; &"" when none.
static func lit_class_of(acc: Dictionary, script_path: String) -> StringName:
	if script_path.is_empty():
		return &""
	var cache: Dictionary = acc["class_cache"]
	if cache.has(script_path):
		return cache[script_path]
	var lit_by_script: Dictionary = acc["lit_by_script"]
	var klass: StringName = &""
	var script := load(script_path) as Script
	while script != null:
		if lit_by_script.has(script.resource_path):
			klass = lit_by_script[script.resource_path]
			break
		script = script.get_base_script()
	cache[script_path] = klass
	return klass


## Version a node's saved data is shaped as, off its SceneState capture.
static func stored_version(props: Dictionary) -> String:
	var v := str(props.get("lit_version", ""))
	if v.is_empty():
		v = str(props.get("metadata/lit_version", ""))
	return Migrations.BASELINE_VERSION if v.is_empty() else v


## Stored names `klass` retires; every class when the class is unknown (null).
static func _retired_on(props: Dictionary, klass: Variant, retired: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var classes: Array = retired.keys() if klass == null else ([klass] if retired.has(klass) else [])
	for k in classes:
		for name in retired[k]:
			if props.has(name) and not out.has(name):
				out.append(name)
	return out


static func _tracks_retired(rows: Array, model: Dictionary, player: Dictionary,
		retired: Dictionary) -> bool:
	var libraries: Variant = player["props"].get("libraries")
	if not (libraries is Dictionary):
		return false
	var base: Variant = _walk(_rel(player["path"]), player["props"].get("root_node", NodePath("..")))
	for lib_name in libraries:
		var lib := libraries[lib_name] as AnimationLibrary
		if lib == null:
			continue
		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			for t in anim.get_track_count():
				var tp := anim.track_get_path(t)
				if tp.get_subname_count() == 0:
					continue
				var klass: Variant = null
				if base != null:
					var target: Variant = _walk(base, NodePath(tp.get_concatenated_names()))
					if target != null:
						klass = _class_at(rows, model, target)
				if not _retired_on({String(tp.get_subname(0)): true}, klass, retired).is_empty():
					return true
	return false


## Lit class of the node at a scene-relative path, through instance rows; null when unknown.
static func _class_at(rows: Array, model: Dictionary, target: String) -> Variant:
	for r in rows:
		if _rel(r["path"]) == target and not String(r["type"]).is_empty():
			return r["klass"]
	var src := _source_row(rows, model, target)
	return src["klass"] if not src.is_empty() else null


## Scene-relative path of `rel` taken from `base`; null when it cannot be resolved
## statically (absolute, unique-name, or climbing above the root).
static func _walk(base: String, rel: NodePath) -> Variant:
	if rel.is_absolute():
		return null
	var segs: Array = [] if base == "." else Array(base.split("/", false))
	for i in rel.get_name_count():
		var n := String(rel.get_name(i))
		if n == ".":
			continue
		if n == "..":
			if segs.is_empty():
				return null
			segs.pop_back()
		elif n.begins_with("%"):
			return null
		else:
			segs.append(n)
	return "." if segs.is_empty() else "/".join(segs)


static func _rel(path: NodePath) -> String:
	return String(path).trim_prefix("./")


## Leaves-first over the instance graph, so a child scene updates before the parents
## that store overrides on its nodes.
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

static func run(scan_result: Dictionary, report_path: String = REPORT_PATH,
		migs: Variant = null) -> Dictionary:
	var rctx := run_begin(scan_result, report_path, migs)
	for scene_path in rctx["scenes"]:
		run_scene(rctx, scene_path)
	return run_finish(rctx)


## run() split into begin / per-scene / finish so the editor can drive the scene pass
## behind a progress dialog.
static func run_begin(scan_result: Dictionary, report_path: String = REPORT_PATH,
		migs: Variant = null) -> Dictionary:
	var scenes: Array[String] = []
	for scene_path in scan_result["order"]:
		var m: Dictionary = scan_result["model"][scene_path]
		if m["needs"] or m["newer"]:
			scenes.append(scene_path)
	return {"scan": scan_result, "migs": migs, "report": [] as Array[String], "scenes": scenes,
		"changed_scenes": [] as Array[String], "updated": 0, "report_path": report_path}


static func run_scene(rctx: Dictionary, scene_path: String) -> void:
	var report: Array = rctx["report"]
	var scan: Dictionary = rctx["scan"]
	var m: Dictionary = scan["model"][scene_path]
	report.append("--- %s" % scene_path)
	if m["newer"]:
		for row in m["rows"]:
			if row["klass"] == &"":
				continue
			var v := stored_version(row["props"])
			if Migrations.semver_cmp(v, scan["current"]) > 0:
				report.append("SKIPPED %s: %s saved with Lit %s, newer than this plugin (%s); scene "
						% [row["path"], row["klass"], v, scan["current"]]
						+ "left untouched so no data is lost - update the plugin instead")
		report.append("UNCHANGED")
		return
	var result := _process_scene(scene_path, m, scan, rctx["migs"], report)
	rctx["updated"] += result["updated"]
	if result["saved"]:
		rctx["changed_scenes"].append(scene_path)
		report.append("SAVED")
	else:
		report.append("UNCHANGED")


static func run_finish(rctx: Dictionary) -> Dictionary:
	var saved := _write_report(rctx["report"], rctx["scan"], rctx["changed_scenes"],
			rctx["updated"], rctx["report_path"])
	return {"changed_scenes": rctx["changed_scenes"], "report": rctx["report"],
		"report_saved": saved, "updated": rctx["updated"]}


# --- Scene pass ----------------------------------------------------------------

static func _process_scene(scene_path: String, m: Dictionary, scan: Dictionary, migs: Variant,
		report: Array) -> Dictionary:
	var out := {"saved": false, "updated": 0}
	var packed := ResourceLoader.load(scene_path, "PackedScene",
			ResourceLoader.CACHE_MODE_REPLACE_DEEP) as PackedScene
	if packed == null:
		report.append("ERROR could not load scene")
		return out
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root == null:
		report.append("ERROR could not instantiate scene")
		return out
	var current: String = scan["current"]
	var changed := false
	for ph in root.find_children("*", "InstancePlaceholder", true, false):
		_materialize_placeholder(ph as InstancePlaceholder)
	for row in m["rows"]:
		var node := root.get_node_or_null(row["path"])
		if node == null or row["klass"] == &"":
			continue
		if Migrations.apply_chain(node, row["klass"], row["props"], report, migs):
			changed = true
		if str(node.get(&"lit_version")) != current:
			node.set(&"lit_version", current)
			out["updated"] += 1
			changed = true
	for row in m["rows"]:
		if not String(row["type"]).is_empty():
			continue
		var node := root.get_node_or_null(row["path"])
		if node != null and _remap_override(node, row, m["rows"], scan, migs, report):
			changed = true
	if _remap_tracks(root, scene_path, scan, migs, report):
		changed = true
	if changed:
		var lost := _unknown_stored(root, m, scan, migs)
		if lost.is_empty():
			if out["updated"] > 0:
				report.append("STAMPED %d Lit nodes at v%s" % [out["updated"], current])
			var packed_out := PackedScene.new()
			if packed_out.pack(root) != OK:
				report.append("ERROR pack failed; scene not saved")
			elif ResourceSaver.save(packed_out, scene_path) != OK:
				report.append("ERROR save failed")
			else:
				out["saved"] = true
		else:
			out["updated"] = 0
			for line in lost:
				report.append("SKIPPED %s" % line)
			report.append("SKIPPED scene left untouched: saving would drop the stored values above; "
					+ "re-save the scene in the editor once they are accounted for, then run again")
	root.free()
	return out


# Outside the editor, placeholder rows (this scene's and its instanced children's)
# load as InstancePlaceholder objects, which pack() cannot serialize back; swap in a
# real instance flagged as a load placeholder, as the editor itself produces.
static func _materialize_placeholder(ph: InstancePlaceholder) -> void:
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
	var owner := ph.owner
	var stored: Dictionary = ph.get_stored_values()
	parent.remove_child(ph)
	real.name = ph_name
	parent.add_child(real)
	parent.move_child(real, index)
	real.owner = owner
	for k in stored:
		real.set(k, stored[k])
	ph.free()


## Instance-provided row (editable instance, inherited root, placeholder) storing a
## name its node's class retires: Godot dropped the value at load, so it is re-applied
## under the live name from the scan capture. The retired name is evidence enough on
## its own: a save would drop it, and the framework never reuses one.
static func _remap_override(node: Node, row: Dictionary, rows: Array, scan: Dictionary,
		migs: Variant, report: Array) -> bool:
	var stored: Dictionary = row["props"]
	var any := _retired_on(stored, null, scan["retired"])
	if any.is_empty():
		return false
	var src := _source_row(rows, scan["model"], _rel(row["path"]))
	if src.is_empty():
		report.append("MANUAL %s: override stores `%s` but the instanced node could not be "
				% [row["path"], "`, `".join(PackedStringArray(any))] + "resolved; re-author it by hand")
		return false
	var klass: StringName = src["klass"]
	var renames := Migrations.rename_chain(klass, Migrations.BASELINE_VERSION, migs)
	var changed := false
	for old_name in _retired_on(stored, klass, scan["retired"]):
		if not renames.has(old_name):
			continue
		node.set(renames[old_name], stored[old_name])
		changed = true
		report.append("REMAPPED-OVERRIDE %s: %s -> %s" % [row["path"], old_name, renames[old_name]])
	return changed


## Typed scan row of the node an instance-provided row overrides (the instance row
## itself stands for the instanced scene's root), read from that scene's model;
## nested instances recurse; empty when unknown.
static func _source_row(rows: Array, model: Dictionary, path: String) -> Dictionary:
	var best := ""
	var inst := ""
	for r in rows:
		var rp := _rel(r["path"])
		if String(r["instance"]).is_empty():
			continue
		if (rp == "." or rp == path or path.begins_with(rp + "/")) and rp.length() >= best.length():
			best = rp
			inst = r["instance"]
	if inst.is_empty() or not model.has(inst):
		return {}
	var rel := "." if best == path else (path if best == "." else path.trim_prefix(best + "/"))
	for r in model[inst]["rows"]:
		if _rel(r["path"]) == rel and not String(r["type"]).is_empty():
			return r
	return _source_row(model[inst]["rows"], model, rel)


## Animation tracks embedded in this scene that drive a renamed property on a Lit node
## follow the rename; animations living in other files are reported, never rewritten.
static func _remap_tracks(root: Node, scene_path: String, scan: Dictionary, migs: Variant,
		report: Array) -> bool:
	var changed := false
	var players: Array[Node] = []
	for p in root.find_children("*", "AnimationMixer", true, false):
		if p.owner == root:
			players.append(p)
	if root is AnimationMixer:
		players.append(root)
	for player in players:
		var base := player.get_node_or_null((player as AnimationMixer).root_node)
		if base == null:
			continue
		for lib_name in (player as AnimationMixer).get_animation_library_list():
			var lib := (player as AnimationMixer).get_animation_library(lib_name)
			for anim_name in lib.get_animation_list():
				var anim := lib.get_animation(anim_name)
				var external := _external(lib, scene_path) or _external(anim, scene_path)
				for t in anim.get_track_count():
					var tp := anim.track_get_path(t)
					if tp.get_subname_count() == 0:
						continue
					var target := base.get_node_or_null(NodePath(tp.get_concatenated_names()))
					if target == null or target.get_script() == null:
						continue
					var klass := lit_class_of(scan, (target.get_script() as Script).resource_path)
					if klass == &"":
						continue
					var renames := Migrations.rename_chain(klass, Migrations.BASELINE_VERSION, migs)
					var first := String(tp.get_subname(0))
					if not renames.has(first):
						continue
					if external:
						report.append("MANUAL %s/%s: external animation drives `%s` on %s (now `%s`); "
								% [player.name, anim_name, first, root.get_path_to(target), renames[first]]
								+ "rename the track by hand")
						continue
					var subs := PackedStringArray([String(renames[first])])
					for si in range(1, tp.get_subname_count()):
						subs.append(tp.get_subname(si))
					anim.track_set_path(t, NodePath("%s:%s" % [tp.get_concatenated_names(), ":".join(subs)]))
					changed = true
					report.append("REMAPPED-TRACK %s/%s: %s -> %s" % [player.name, anim_name, first, renames[first]])
	return changed


static func _external(res: Resource, scene_path: String) -> bool:
	return not res.resource_path.is_empty() and res.resource_path.get_slice("::", 0) != scene_path


## Stored values the save would drop: names no live property carries and no migration
## of the node's class renames or removes. A name is carried when it is listed, when
## get() answers it, or when it heads a listed group (a legacy aggregate such as
## `libraries = {}` re-saves as `libraries/<name>` entries).
static func _unknown_stored(root: Node, m: Dictionary, scan: Dictionary, migs: Variant) -> Array[String]:
	var out: Array[String] = []
	for row in m["rows"]:
		var node := root.get_node_or_null(row["path"])
		if node == null:
			continue
		var klass: StringName = row["klass"]
		if String(row["type"]).is_empty():
			var src := _source_row(m["rows"], scan["model"], _rel(row["path"]))
			klass = src["klass"] if not src.is_empty() else &""
		var explained := _explained(klass, migs)
		var have := {}
		var groups := {}
		for info in node.get_property_list():
			var n := String(info["name"])
			have[n] = true
			if "/" in n:
				groups[n.get_slice("/", 0) + "/"] = true
		for name in row["props"]:
			if have.has(name) or groups.has(name + "/") or explained.has(name) or node.get(name) != null:
				continue
			out.append("%s: stores `%s` = %s, which this plugin does not know"
					% [row["path"], name, row["props"][name]])
	return out


static func _explained(klass: StringName, migs: Variant) -> Dictionary:
	var out := {}
	if klass == &"":
		return out
	for name in Migrations.rename_chain(klass, Migrations.BASELINE_VERSION, migs):
		out[name] = true
	for mig in Migrations.chain_for(klass, Migrations.BASELINE_VERSION, migs):
		for gone in mig.removes:
			out[String(gone)] = true
	return out


# --- Report --------------------------------------------------------------------

## Everything that needs a hand (SKIPPED / MANUAL / ERROR) leads the file, fenced for
## copy/paste; the chronological per-scene log follows.
static func _write_report(report: Array, scan: Dictionary, changed_scenes: Array, updated: int,
		report_path: String) -> bool:
	var f := FileAccess.open(report_path, FileAccess.WRITE)
	if f == null:
		push_warning("Lit: could not write '%s'" % report_path)
		return false
	var attention: Array[String] = []
	var log: Array[String] = []
	var scene := ""
	for line in report:
		var s := String(line)
		if s.begins_with("--- "):
			scene = s.trim_prefix("--- ")
		if s.begins_with("MANUAL") or s.begins_with("SKIPPED") or s.begins_with("ERROR"):
			attention.append("%s  (%s)" % [s, scene])
		else:
			log.append(s)
	var c: Dictionary = scan["counts"]
	f.store_line("Update Project to Lit %s - %d scenes scanned, %d Lit nodes updated in %d scenes"
			% [scan["current"], c["scenes"], updated, changed_scenes.size()])
	f.store_line("")
	if not attention.is_empty():
		f.store_line("")
		f.store_line("=".repeat(72))
		f.store_line("NEEDS YOUR ATTENTION - %d items" % attention.size())
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
