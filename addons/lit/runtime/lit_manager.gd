extends Node

## LitManager — runtime gather driver (plan §8, autoload added by lit_plugin.gd).
##
## Autoloads do not run in the editor, so this drives the per-frame
## gather/cull/pack only while the game is running. Editor-live preview is
## handled separately by the EditorPlugin (Phase 4).
##
## The work here is the pack, not the per-pixel lighting; a full per-frame
## repack is fine for v1. Dirty-tracking is a post-v1 optimization (plan §13).

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")

var _registry: LitLightRegistry


func _ready() -> void:
	_registry = LitLightRegistryScript.new()
	# Run after gameplay scripts have moved their lights this frame.
	process_priority = 1000


func _process(_delta: float) -> void:
	_registry.refresh(get_tree(), get_viewport())
