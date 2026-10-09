@tool
extends RefCounted

## Per-scene model building for "Project Migration Tool": one row per SceneState node
## (type, script, instance edge, stored props), plus the leaves-first processing
## order over the instance graph. Read-only; no scene code runs.


static func scan_scene(acc: Dictionary, scene_path: String) -> void:
	var counts: Dictionary = acc["counts"]
	var scripts: Dictionary = acc["scripts"]
	var lit_by_script: Dictionary = acc["lit_by_script"]
	var core_names: Dictionary = acc["core_names"]
	var current: String = acc["current"]
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("Lit: migration scan could not load '%s'; skipped" % scene_path)
		return
	var state := packed.get_state()
	var rows: Array[Dictionary] = []
	var deps := {}
	var needs := false
	# Rows this scene owns outright; empty-type rows are instance-provided overrides whose
	# node may convert in the child scene, so a reference to one still leaves the scene.
	var own := {}
	for i in state.get_node_count():
		if i == 0 or not String(state.get_node_type(i)).is_empty():
			own[String(state.get_node_path(i)).trim_prefix(".").trim_prefix("/")] = true
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
		elif state.is_node_instance_placeholder(i):
			instance_path = state.get_node_instance_placeholder(i)
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
		if not row["placeholder"] and not script_path.is_empty() \
				and _refs_leave_scene(script_path, props, String(row["path"]), own):
			needs = true
	acc["model"][scene_path] = {"rows": rows, "deps": deps.keys(), "needs": needs,
		"inherited": not rows.is_empty() and not String(rows[0]["instance"]).is_empty()}


## Exported node references (alone or inside arrays / dictionaries) whose stored path
## leaves this scene's own rows point into an instanced child. Such a scene may have
## nothing of its own to convert, yet the child's node may convert and the annotation
## may refuse it, so the scene must still go through the reference pass.
static func _refs_leave_scene(script_path: String, props: Dictionary, row_path: String,
		own: Dictionary) -> bool:
	var script := load(script_path) as Script
	if script == null:
		return false
	var prefix := "%d/%d:" % [TYPE_OBJECT, PROPERTY_HINT_NODE_TYPE]
	for info in script.get_script_property_list():
		var name := String(info["name"])
		if not props.has(name):
			continue
		var hint := String(info["hint_string"])
		var node_ref := (int(info["type"]) == TYPE_OBJECT and int(info["hint"]) == PROPERTY_HINT_NODE_TYPE) \
				or (int(info["type"]) == TYPE_ARRAY and hint.begins_with(prefix)) \
				or (int(info["type"]) == TYPE_DICTIONARY and prefix in hint)
		if not node_ref:
			continue
		for p in _node_paths_in(props[name]):
			var target := _resolve_in_scene(row_path, p)
			if target == null or not own.has(target):
				return true
	return false


static func _node_paths_in(value: Variant) -> Array:
	var out := []
	if value is NodePath:
		if not (value as NodePath).is_empty():
			out.append(value)
	elif value is Array:
		for e in value:
			if e is NodePath and not (e as NodePath).is_empty():
				out.append(e)
	elif value is Dictionary:
		for k in value:
			if k is NodePath and not (k as NodePath).is_empty():
				out.append(k)
			if value[k] is NodePath and not (value[k] as NodePath).is_empty():
				out.append(value[k])
	return out


## Scene-relative row path for `rel` taken from `row_path`; null when it cannot be
## resolved statically (absolute, unique-name, or climbing above the root).
static func _resolve_in_scene(row_path: String, rel: NodePath) -> Variant:
	if rel.is_absolute():
		return null
	var segs := Array(row_path.trim_prefix(".").trim_prefix("/").split("/", false))
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
	return "/".join(segs)


## Leaves-first over the instance graph, so child scenes convert before the parents
## that store overrides on them.
static func topo_order(scene_paths: Array[String], model: Dictionary) -> Array[String]:
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
