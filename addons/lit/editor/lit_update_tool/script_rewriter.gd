@tool
extends RefCounted

## The script pass of "Update Project to Lit": rebases user chains onto the Lit
## classes, adds @tool where the Lit base requires it, retypes core-class references,
## and force-reloads everything it rewrote. UI-only scripts are skipped by the
## caller's ui_roots/ui_scripts sets when menus are excluded.

const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")
const ScriptScan := preload("res://addons/lit/editor/lit_update_tool/script_scan.gd")


## Rewrite the extends line of each collision-free chain root, then force-reload the
## whole chain so the scene pass compiles against the Lit base. Returns every script
## path whose chain now roots in a Lit class.
static func rebase_user_scripts(scripts: Dictionary, ui_roots: Dictionary,
		report: Array) -> Dictionary:
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
		if ui_roots.has(root_path):
			report.append("MENU-SCRIPT %s: attached only to menu/UI nodes; left native "
					% root_path + "(check the menus option to convert menu art)")
			continue
		var core: String = scripts["chains"][root_path]["core"]
		var f := FileAccess.open(root_path, FileAccess.READ)
		if f == null:
			report.append("ERROR could not read %s" % root_path)
			continue
		var lines := f.get_as_text().split("\n")
		f = null
		for i in lines.size():
			if ScriptScan.extends_token(String(lines[i]).rstrip("\r")) == core:
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
		if ui_roots.has(root_path):
			continue
		for p in scripts["chains"][root_path]["scripts"]:
			out[p] = true
	return out


## Prepend @tool to every script whose chain roots in a @tool Lit class: without it the
## editor gives instances a placeholder script whose lifecycle never runs, and every
## load warns MISSING_TOOL.
static func add_tool_annotations(scripts: Dictionary, ui_scripts: Dictionary,
		report: Array) -> Array:
	var targets := {}
	for p in scripts["rebase_all"]:
		if not ui_scripts.has(p):
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
static func retype_references(scripts: Dictionary, ui_scripts: Dictionary,
		report: Array) -> Array:
	var targets := {}
	for path in scripts["core_refs"]:
		if not ui_scripts.has(path):
			targets[path] = true
	for path in scripts["string_refs"]:
		if not ui_scripts.has(path):
			targets[path] = true
	var rx := ScriptScan.core_class_rx()
	var paths: Array = targets.keys()
	paths.sort()
	var changed: Array = []
	for path in paths:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		var count := 0
		var string_lines: Array[String] = []
		for li in lines.size():
			var line := String(lines[li])
			if ScriptScan.is_extends_decl(line.strip_edges()):
				continue
			var rebuilt := ""
			var line_hit := false
			for piece in ScriptScan.line_pieces(line):
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
static func reload_scripts(paths: Array) -> void:
	paths.sort()
	for p in paths:
		var s := load(p) as GDScript
		if s != null:
			s.source_code = FileAccess.get_file_as_string(p)
			s.reload()
