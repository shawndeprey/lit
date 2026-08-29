@tool
extends RefCounted

## Report output for "Update Project to Lit": the grouped material notes appended at
## the end of a run, and the report file itself.


static func material_notes(scan_result: Dictionary, ctx: Dictionary,
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


## The report leads with everything that was NOT auto-migratable, fenced and padded
## so it can be copy/pasted straight into a task list; the chronological per-scene
## log follows. Flagged lines pulled out of a scene block get the scene appended so
## they stay self-contained.
static func write(report: Array, scan_result: Dictionary,
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
