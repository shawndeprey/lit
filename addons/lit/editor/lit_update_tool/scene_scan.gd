@tool
extends RefCounted

## Per-scene model building for "Update Project to Lit": one row per SceneState node
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
	acc["model"][scene_path] = {"rows": rows, "deps": deps.keys(), "needs": needs,
		"inherited": not rows.is_empty() and not String(rows[0]["instance"]).is_empty()}


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
