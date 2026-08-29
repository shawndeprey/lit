@tool
extends RefCounted

## Read-only analysis of every project .gd file for "Update Project to Lit":
## inheritance chains rooting in rebasable core classes (with member-collision
## checks against the Lit classes), core-class references for the retype pass,
## @tool presence, and scene-path string literals (code-usage evidence for the
## menu/UI classifier). Also owns the line-parsing primitives the rewriter reuses.

const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")


## User .gd files whose inheritance chain roots in a rebasable core class. Chain roots
## get their extends line rewritten; a member collision anywhere in a chain (against
## the Lit class's own members) skips the whole chain.
static func scan_scripts(roots: Array[String]) -> Dictionary:
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

	var core_ref_rx := core_class_rx()

	var info := {}
	var scene_strings := {}
	for path in paths:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var members := {}
		var extends_tok := ""
		var inner_extends := false
		var has_tool := false
		var refs := {}
		var string_ref := false
		for raw_line in f.get_as_text().split("\n"):
			var line := raw_line.rstrip("\r")
			var stripped := line.strip_edges()
			if stripped == "@tool" or stripped.begins_with("@tool ") or stripped.begins_with("@tool#"):
				has_tool = true
			var token := extends_token(line)
			if not token.is_empty():
				extends_tok = token
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
				var scan_refs := not is_extends_decl(stripped)
				for piece in line_pieces(line):
					var text: String = piece["text"]
					if piece["kind"] == "string" and (".tscn" in text or ".scn" in text):
						scene_strings[text] = true
					if not scan_refs:
						continue
					var m := core_ref_rx.search(text)
					if m == null:
						continue
					if piece["kind"] == "code":
						refs[m.get_string(1)] = true
					elif piece["kind"] == "string":
						string_ref = true
		info[path] = {"extends": extends_tok, "members": members, "inner": inner_extends,
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
		"no_tool": {}, "all_paths": paths, "scene_strings": scene_strings}
	for path in info:
		if not info[path]["refs"].is_empty():
			out["core_refs"][path] = info[path]["refs"]
		if info[path]["string_ref"]:
			out["string_refs"][path] = true
	for path in info:
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
static func extends_token(line: String) -> String:
	if line.begins_with("extends "):
		return line.trim_prefix("extends ").get_slice("#", 0).strip_edges()
	if line.begins_with("class_name ") and (" extends " in line):
		return line.get_slice(" extends ", 1).get_slice("#", 0).strip_edges()
	return ""


# Any extends declaration (top-level, one-line class_name form, or inner class); the
# core class named there is a deliberate base, never a retype candidate.
static func is_extends_decl(stripped: String) -> bool:
	if stripped.begins_with("extends "):
		return true
	if stripped.begins_with("class_name ") and (" extends " in stripped):
		return true
	return stripped.begins_with("class ") and (" extends " in stripped)


# Split one line into code / string-literal / comment pieces, in order. Concatenating
# the piece texts reproduces the line. Single-line quotes only; a line-spanning
# triple-quoted string degrades to "string to end of line", which only ever makes the
# retype pass more conservative.
static func line_pieces(line: String) -> Array:
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
static func core_class_rx() -> RegEx:
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
