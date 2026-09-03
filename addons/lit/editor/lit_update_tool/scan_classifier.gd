@tool
extends RefCounted

## Candidate classification for "Update Project to Lit", run after every scene is
## modeled so UI ancestry can resolve through instanced menu scenes: splits candidates
## into world converts vs menu/UI exclusions (in-scene Control/CanvasLayer ancestry,
## plus usage - a scene or script used only from menus classifies as UI unless code
## references it), classifies material slots, finalizes counts, and assembles the
## scan result.

const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")
const RxMats := preload("res://addons/lit/editor/lit_update_tool/receiver_materials.gd")
const SceneScan := preload("res://addons/lit/editor/lit_update_tool/scene_scan.gd")


static func finish(acc: Dictionary) -> Dictionary:
	var counts: Dictionary = acc["counts"]
	var scripts: Dictionary = acc["scripts"]
	var by_path_all := {}
	for scene_path in acc["model"]:
		var by_path := {}
		for row in acc["model"][scene_path]["rows"]:
			by_path[String(row["path"])] = row
		by_path_all[scene_path] = by_path
	var sites := _instance_sites(acc, by_path_all)
	# A scene loaded from code runs in unknown context (players and mobs spawn from code
	# yet preview inside menus), so a code-referenced scene never classifies as menu-only.
	var code_used := {}
	var scene_strings: Dictionary = scripts.get("scene_strings", {})
	for scene_path in acc["model"]:
		var fname := String(scene_path).get_file()
		for lit in scene_strings:
			if fname in String(lit):
				code_used[scene_path] = true
				break
	var ui_used := _ui_only_scenes(sites, code_used)
	for scene_path in acc["model"]:
		var m: Dictionary = acc["model"][scene_path]
		var by_path: Dictionary = by_path_all[scene_path]
		var scene_ui := ui_used.has(scene_path)
		var needs: bool = m["needs"]
		for row in m["rows"]:
			var row_type := String(row["type"])
			if row_type.is_empty():
				continue
			var script_path := String(row["script"])
			if Maps.REPLACEMENTS.has(row_type):
				if scene_ui or _is_ui_row(acc, by_path, String(row["path"])):
					row["ui"] = true
					if script_path.is_empty():
						counts["menu_nodes"] += 1
						counts["menu_core"] += 1
						needs = true
				elif script_path.is_empty():
					needs = true
					row["converts"] = true
					match row_type:
						"PointLight2D": counts["point_lights"] += 1
						"DirectionalLight2D": counts["directional_lights"] += 1
						"CanvasModulate": counts["modulates"] += 1
				else:
					counts["skipped_scripted"] += 1
					needs = true
			elif Maps.SWAPS.has(row_type):
				if scene_ui or _is_ui_row(acc, by_path, String(row["path"])):
					row["ui"] = true
					counts["menu_nodes"] += 1
					needs = true
				elif script_path.is_empty():
					var where := "%s %s" % [scene_path, row["path"]]
					var cls := RxMats.classify(row["props"].get("material"))
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
							row["converts"] = true
							counts["sprites" if row_type == "Sprite2D" else "tilemaps"] += 1
		m["needs"] = needs
		if needs:
			counts["scenes_to_process"] += 1
	# Scripts attached only to menu/UI nodes stay out of the script passes by default:
	# rebasing a shared icon-style script would light every menu instance, and retyping
	# any UI-only script's self-references would break against nodes that stayed native.
	var member_root := {}
	for root_path in scripts["roots"]:
		for p in scripts["chains"][root_path]["scripts"]:
			member_root[p] = root_path
	var user_scripts := {}
	for p in scripts["all_paths"]:
		user_scripts[p] = true
	var script_sites := {}
	for scene_path in acc["model"]:
		for row in acc["model"][scene_path]["rows"]:
			var sp := String(row["script"])
			if sp.is_empty() or not user_scripts.has(sp):
				continue
			if not script_sites.has(sp):
				script_sites[sp] = {"ui": [], "world": []}
			var is_ui: bool = row.get("ui", false) or ui_used.has(scene_path) \
					or _is_ui_row(acc, by_path_all[scene_path], String(row["path"]))
			script_sites[sp]["ui" if is_ui else "world"].append(
					"%s %s" % [scene_path, row["path"]])
	scripts["ui_roots"] = {}
	scripts["ui_scripts"] = {}
	var mixed_scripts := {}
	for root_path in scripts["roots"]:
		var ui_atts := []
		var world_atts := []
		for p in scripts["chains"][root_path]["scripts"]:
			if script_sites.has(p):
				ui_atts += script_sites[p]["ui"]
				world_atts += script_sites[p]["world"]
		if ui_atts.is_empty():
			continue
		if world_atts.is_empty():
			scripts["ui_roots"][root_path] = true
			for p in scripts["chains"][root_path]["scripts"]:
				scripts["ui_scripts"][p] = true
		else:
			mixed_scripts[root_path] = ui_atts
	for sp in script_sites:
		if member_root.has(sp):
			continue
		if script_sites[sp]["world"].is_empty() and not script_sites[sp]["ui"].is_empty():
			scripts["ui_scripts"][sp] = true
	var mixed_scenes := {}
	for inst in sites:
		if ui_used.has(inst) or not acc["model"].has(inst):
			continue
		var ui_sites := []
		for site in sites[inst]:
			if site["ui"] or ui_used.has(site["scene"]):
				ui_sites.append("%s %s" % [site["scene"], site["path"]])
		if ui_sites.is_empty():
			continue
		for row in acc["model"][inst]["rows"]:
			var sp := String(row["script"])
			if row.get("converts", false) \
					or (member_root.has(sp) and not scripts["ui_scripts"].has(sp)):
				mixed_scenes[inst] = ui_sites
				break
	var ui_chain_members := 0
	for rp in scripts["ui_roots"]:
		ui_chain_members += scripts["chains"][rp]["scripts"].size()
	counts["rebase_roots"] = scripts["roots"].size() - scripts["ui_roots"].size()
	counts["rebase_scripts"] = scripts["rebase_all"].size() - ui_chain_members
	counts["rebase_skipped"] = scripts["skipped"].size()
	counts["menu_scripts"] = scripts["ui_scripts"].size()
	var retype_count := 0
	for p in scripts["core_refs"]:
		if not scripts["ui_scripts"].has(p):
			retype_count += 1
	counts["retype_scripts"] = retype_count
	var tool_add := {}
	for p in scripts["rebase_all"]:
		if scripts["no_tool"].has(p) and not scripts["ui_scripts"].has(p):
			tool_add[p] = true
	for p in scripts["lit_tool_rooted"]:
		if scripts["no_tool"].has(p):
			tool_add[p] = true
	counts["tool_add"] = tool_add.size()
	var ui_scenes: Array = []
	for scene_path in acc["model"]:
		if not ui_used.has(scene_path):
			continue
		for row in acc["model"][scene_path]["rows"]:
			if row.get("ui", false):
				ui_scenes.append(scene_path)
				break
	ui_scenes.sort()
	var scene_paths: Array[String] = acc["scene_paths"]
	return {"order": SceneScan.topo_order(scene_paths, acc["model"]), "model": acc["model"],
		"scripts": scripts, "counts": counts, "current": acc["current"],
		"custom_groups": acc["custom_groups"], "unlit_nodes": acc["unlit_nodes"],
		"mixed_ui_scenes": mixed_scenes, "mixed_ui_scripts": mixed_scripts,
		"ui_scenes": ui_scenes}


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


# Every place each scene is instanced (or inherited), with whether that site sits
# under UI ancestry in the instancing scene.
static func _instance_sites(acc: Dictionary, by_path_all: Dictionary) -> Dictionary:
	var sites := {}
	for scene_path in acc["model"]:
		for row in acc["model"][scene_path]["rows"]:
			var inst := String(row["instance"])
			if inst.is_empty():
				continue
			if not sites.has(inst):
				sites[inst] = []
			sites[inst].append({"scene": scene_path, "path": String(row["path"]),
				"ui": _is_ui_row(acc, by_path_all[scene_path], String(row["path"]))})
	return sites


# Shared scenes (icons, widgets) carry no Control ancestry of their own, so a scene
# whose every instance site is UI classifies as UI too. The fixed point resolves
# chains like icon-inside-wrapper-inside-menu. Scenes referenced from code are
# exempt: their runtime context is unknowable, so world usage is assumed.
static func _ui_only_scenes(sites: Dictionary, code_used: Dictionary) -> Dictionary:
	var out := {}
	var grew := true
	while grew:
		grew = false
		for inst in sites:
			if out.has(inst) or code_used.has(inst):
				continue
			var all_ui := true
			for site in sites[inst]:
				if not (site["ui"] or out.has(site["scene"])):
					all_ui = false
					break
			if all_ui:
				out[inst] = true
				grew = true
	return out
