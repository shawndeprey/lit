@tool
extends RefCounted
class_name LitVersionStamp

## Stamps a Lit node's `lit_version` storage property with the plugin version it was
## created under. Called from each Lit node's _enter_tree; assigns only in the editor
## and only when the stamp is empty, so loaded stamps are never overwritten and the
## value rides along on the next scene save.

static func stamp(node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	if String(node.get(&"lit_version")).is_empty():
		node.set(&"lit_version", LitShaderLibrary._get_version())
