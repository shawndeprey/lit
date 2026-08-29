@tool
extends RefCounted

## The scene pass of "Update Project to Lit": loads one scene off-tree, converts its
## candidate rows (node replacement for lights/modulates, in-place script swaps for
## receivers, fixups for rebased-script nodes, migrations + stamping for Lit nodes),
## remaps instance overrides and animation tracks, then packs and saves - only when
## something changed.

const Maps := preload("res://addons/lit/editor/lit_update_tool/conversion_maps.gd")
const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")
const RxMats := preload("res://addons/lit/editor/lit_update_tool/receiver_materials.gd")

# Core shadow_color semantics: shadowed light = mix(light, shadow_rgb, alpha), so the
# default transparent black means invisible shadows. Lit tints shadowed light by rgb
# (alpha unused), so the behavior-preserving map is mix(WHITE, rgb, alpha).
const CORE_SHADOW_DEFAULT := Color(0, 0, 0, 0)


static func process_scene(scene_path: String, m: Dictionary, scan_result: Dictionary,
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
	var lit_by_script := Migrations.lit_scripts_by_path()
	var core_names := Maps.core_mapped_names()
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

## Sprite2D/TileMapLayer conversion candidate. Returns true when the node changed.
static func _convert_receiver(node: Node, script_path: String, row: Dictionary,
		current: String, report: Array) -> bool:
	var core_class := node.get_class()
	var cls := RxMats.classify((node as CanvasItem).material)
	match cls["kind"]:
		"unlit", "custom":
			return false  # collected scan-side for the grouped material notes
		"default_canvas":
			node.set("material", null)
	var mask := (node as CanvasItem).light_mask
	node.set_script(load(script_path))
	if cls["kind"] == "receiver":
		RxMats.sync_exports(node)
		report.append("CONVERTED %s: %s -> Lit%s (kept its receiver material)"
				% [row["path"], core_class, core_class])
	else:
		node.set("receiver_mask", mask)
		report.append("CONVERTED %s: %s -> Lit%s (receiver_mask %d from light_mask%s)"
				% [row["path"], core_class, core_class, mask,
				"; default material dropped" if cls["kind"] == "default_canvas" else ""])
	RxMats.wrap_texture(node)
	node.set(&"lit_version", current)
	return true


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
	var cls := RxMats.classify(row["props"].get("material"))
	match cls["kind"]:
		"unlit":
			report.append("UNLIT %s: rebased-script node keeps its material (%s) and "
					% [row["path"], cls["why"]] + "composes over the lighting")
		"custom":
			_note_custom(ctx, cls["shader"], row["path"])
		"receiver":
			RxMats.sync_exports(node)
			if RxMats.wrap_texture(node):
				changed = true
		_:
			if cls["kind"] == "default_canvas" or (node as CanvasItem).material == null:
				node.set("material", RxMats.fresh_material(node))
				changed = true
			var mask := (node as CanvasItem).light_mask
			if int(node.get(&"receiver_mask")) != mask:
				node.set(&"receiver_mask", mask)
				changed = true
			if RxMats.wrap_texture(node):
				changed = true
	if str(node.get(&"lit_version")) != current:
		node.set(&"lit_version", current)
		changed = true
	if changed:
		report.append("CONVERTED %s: rebased-script node joined the Lit pipeline" % row["path"])
	return changed


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
