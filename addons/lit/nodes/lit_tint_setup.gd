@tool
extends Node

## One-shot wiring for the stained-glass tint effect in Props.tscn (or any gem scene).
##
## Run this from the editor to inject the whole subsystem without hand-editing the .tscn:
##   1. Add this node anywhere in the scene (e.g. as a child of the Props root).
##   2. In the inspector, tick `run_setup`. It wires everything, then unticks itself.
##   3. Delete this node (the wiring it created is saved with the scene).
##
## What it does:
##   • Adds one LitTintBuffer (the screen-space tint buffer) if none exists.
##   • Adds one LitTintBeams pass (visible coloured shafts) if none exists.
##   • Adds a LitTintModifier under every gem (any LitSprite2D with transmission_strength > 0,
##     or every node whose name starts with "Gem"), set to auto-pull the gem's transmission
##     colour × modulate. Gems become tint WRITERS.
##   • Turns tint_enabled on for the wall/floor receivers so light landing on them takes the
##     gem colours (and shadows inherit them). Gems are left as writers; flip
##     `tint_receivers_too` if you also want gem-on-gem tinting.
##
## Re-running is safe: it skips anything already present.

@export var run_setup: bool = false:
	set(value):
		run_setup = false
		if value and Engine.is_editor_hint():
			_run()

## Also enable tint_enabled on the gems themselves (gem-on-gem tinting). Off by default:
## gems are primarily writers here, and self/again-tinting can muddy the hero stones.
@export var tint_receivers_too: bool = false

## Wall receivers to tint. Empty = auto-find the "Walls" node and tint all its sprites.
@export var walls_root_name: String = "Walls"


func _run() -> void:
	var scene_root := get_tree().edited_scene_root
	if scene_root == null:
		push_warning("LitTintSetup: no edited scene.")
		return

	_ensure_buffer(scene_root)
	_ensure_beams(scene_root)
	var gem_count := _wire_gems(scene_root)
	var wall_count := _enable_wall_receivers(scene_root)

	print("LitTintSetup: buffer+beams ensured, %d gems wired as writers, %d wall receivers tinted." % [gem_count, wall_count])


# --- buffer + beams -----------------------------------------------------------

func _ensure_buffer(root: Node) -> void:
	if _find_type(root, "LitTintBuffer") != null:
		return
	var buf := LitTintBuffer.new()
	buf.name = "LitTintBuffer"
	root.add_child(buf)
	buf.owner = root


func _ensure_beams(root: Node) -> void:
	if _find_type(root, "LitTintBeams") != null:
		return
	var beams := LitTintBeams.new()
	beams.name = "LitTintBeams"
	# Sit above receivers, below UI. The scene's LitPostProcess is a CanvasLayer at its own
	# layer; put beams just below it so the post chain grades the beams too. Default layer 0
	# is fine for the gem scene; adjust if your UI overlaps.
	beams.layer = 1
	beams.intensity = 0.7
	beams.steps = 32
	root.add_child(beams)
	beams.owner = root


# --- gems as writers ----------------------------------------------------------

func _wire_gems(root: Node) -> int:
	var count := 0
	for node in _all_nodes(root):
		if not _is_gem(node):
			continue
		# Skip if it already has a LitTintModifier child.
		if _child_of_type(node, "LitTintModifier") != null:
			continue
		var mod := LitTintModifier.new()
		mod.name = "LitTintModifier"
		mod.source = node
		mod.auto_from_source = true     # pull transmission_color × modulate + transmission_map
		mod.density = 1.0
		node.add_child(mod)
		mod.owner = root
		count += 1

		if tint_receivers_too:
			_set_tint_enabled(node, true)
	return count


func _is_gem(node: Node) -> bool:
	# A gem here is a LitSprite2D with transmission turned on, or any node named like a gem.
	if node is Sprite2D and node.name.begins_with("Gem"):
		return true
	if "transmission_strength" in node and float(node.get("transmission_strength")) > 0.0:
		return true
	return false


# --- wall/floor receivers -----------------------------------------------------

func _enable_wall_receivers(root: Node) -> int:
	var walls := root.find_child(walls_root_name, true, false)
	var targets: Array = []
	if walls != null:
		targets = _all_nodes(walls)
	else:
		# Fallback: every receiver-material sprite that isn't a gem.
		for n in _all_nodes(root):
			if n is Sprite2D and not _is_gem(n):
				targets.append(n)

	var count := 0
	for n in targets:
		if n is CanvasItem and n.material is ShaderMaterial:
			_set_tint_enabled(n, true)
			count += 1
	return count


func _set_tint_enabled(node: Node, on: bool) -> void:
	if node.material is ShaderMaterial:
		(node.material as ShaderMaterial).set_shader_parameter("tint_enabled", on)
		(node.material as ShaderMaterial).set_shader_parameter("tint_samples", 12)


# --- helpers ------------------------------------------------------------------

func _all_nodes(root: Node) -> Array:
	var out: Array = [root]
	for c in root.get_children():
		out.append_array(_all_nodes(c))
	return out


func _find_type(root: Node, cls: String) -> Node:
	for n in _all_nodes(root):
		if _is_named_type(n, cls):
			return n
	return null


func _child_of_type(parent: Node, cls: String) -> Node:
	for c in parent.get_children():
		if _is_named_type(c, cls):
			return c
	return null


## Reliable type test for our addon's class_name nodes. `is` checks work because the
## classes are registered globals in this same addon; fall back to a script-path match for
## anything exotic.
func _is_named_type(n: Node, cls: String) -> bool:
	match cls:
		"LitTintBuffer":
			return n is LitTintBuffer
		"LitTintBeams":
			return n is LitTintBeams
		"LitTintModifier":
			return n is LitTintModifier
		_:
			var s := n.get_script()
			return s != null and s.resource_path.get_file().get_basename() == _snake(cls)


## CamelCase class name -> snake_case file stem (LitTintBuffer -> lit_tint_buffer).
func _snake(name: String) -> String:
	var out := ""
	for i in name.length():
		var ch := name[i]
		if ch == ch.to_upper() and ch != ch.to_lower() and i > 0:
			out += "_"
		out += ch.to_lower()
	return out
