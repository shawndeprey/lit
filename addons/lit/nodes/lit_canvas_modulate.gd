@tool
@icon("res://addons/lit/icons/lit_canvas_modulate.svg")
extends Node2D
class_name LitCanvasModulate

## Ambient / darkness source.
##
## Feeds ambient color and energy to receivers through the `lit_ambient_color` and
## `lit_ambient_energy` global shader uniforms. Lights resolve together with ambient
## inside the receiver, so they always punch through the darkness.[br][br]
##
## This replaces the native CanvasModulate rather than accompanying it. A live native
## CanvasModulate would multiply our already-correct output and double-darken, so we
## warn at edit time and runtime if one is present.[br][br]
##
## Only one active LitCanvasModulate is expected; if several exist, the last one to
## enter the tree wins (each writes the globals on enter and on change). The globals
## are not scoped per CanvasLayer the way a native CanvasModulate is.

const GROUP := "lit_canvas_modulate"

# Plugin version this node's saved data was authored under; see LitVersionStamp.
@export_storage var lit_version := ""

@export var color: Color = Color("#1a1a1a"):
	set(value):
		color = value
		_apply()

@export var ambient_energy: float = 1.0:
	set(value):
		ambient_energy = value
		_apply()


func _enter_tree() -> void:
	add_to_group(GROUP)
	LitVersionStamp.stamp(self)
	_apply()
	var tree := get_tree()
	# The scene dock only re-queries this node's warnings when this node asks.
	if _refreshes_warnings() and not tree.node_added.is_connected(_on_tree_node_changed):
		tree.node_added.connect(_on_tree_node_changed)
		tree.node_removed.connect(_on_tree_node_changed)
	# Checked a frame later: level streaming legitimately overlaps the outgoing and
	# incoming modulates within a swap frame, and only true coexistence should warn.
	if not Engine.is_editor_hint() \
			and not tree.process_frame.is_connected(_warn_if_conflicting):
		tree.process_frame.connect(_warn_if_conflicting, CONNECT_ONE_SHOT)
	update_configuration_warnings()


func _exit_tree() -> void:
	remove_from_group(GROUP)
	var tree := get_tree()
	if tree.node_added.is_connected(_on_tree_node_changed):
		tree.node_added.disconnect(_on_tree_node_changed)
		tree.node_removed.disconnect(_on_tree_node_changed)


## Publish ambient to the global shader uniforms. Works at edit time too, tinting the
## editor viewport for a live darkness preview.
func _apply() -> void:
	RenderingServer.global_shader_parameter_set("lit_ambient_color", color)
	RenderingServer.global_shader_parameter_set("lit_ambient_energy", ambient_energy)


func _refreshes_warnings() -> bool:
	return Engine.is_editor_hint()


# Deferred: node_removed fires while the node is still in the tree and its groups.
func _on_tree_node_changed(node: Node) -> void:
	if node != self and (node is CanvasModulate or node is LitCanvasModulate):
		update_configuration_warnings.call_deferred()


# Runtime warns only for a native CanvasModulate (always a real double-darken bug).
# Multiple Lit modulates are the normal level-streaming pattern - each level carries
# its ambient and the last to enter wins - so only the editor configuration warning
# mentions them, where a genuine authoring mistake is diagnosable.
func _warn_if_conflicting() -> void:
	if not is_inside_tree():
		return
	var natives := _native_canvas_modulates()
	if not natives.is_empty():
		push_warning("LitCanvasModulate: native CanvasModulate at %s will double-darken Lit output. Remove it." % _paths(natives))


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if not is_inside_tree():
		return warnings
	var natives := _native_canvas_modulates()
	if not natives.is_empty():
		warnings.append("Native CanvasModulate at %s will multiply Lit's output and double-darken the scene. Remove it and let LitCanvasModulate own ambient/darkness." % _paths(natives))
	var others := _other_lit_modulates()
	if not others.is_empty():
		warnings.append("Other LitCanvasModulate nodes in this scene: %s. Ambient is global, not scoped per CanvasLayer like a native CanvasModulate, so the last one to enter the tree wins everywhere. Keep one unless the extras are swapped in by level streaming." % _paths(others))
	return warnings


func _scene_root() -> Node:
	return get_tree().get_edited_scene_root() if Engine.is_editor_hint() else get_tree().get_root()


func _native_canvas_modulates() -> Array[Node]:
	var found: Array[Node] = []
	var root := _scene_root()
	if root == null:
		return found
	if root is CanvasModulate:
		found.append(root)
	found.append_array(root.find_children("*", "CanvasModulate", true, false))
	return found


func _other_lit_modulates() -> Array[Node]:
	var found: Array[Node] = []
	var root := _scene_root()
	if root == null:
		return found
	for m in get_tree().get_nodes_in_group(GROUP):
		if m != self and (m == root or root.is_ancestor_of(m)):
			found.append(m)
	return found


func _paths(nodes: Array[Node]) -> String:
	var root := _scene_root()
	var out := PackedStringArray()
	for n in nodes:
		out.append(String(root.get_path_to(n)))
	return ", ".join(out)
