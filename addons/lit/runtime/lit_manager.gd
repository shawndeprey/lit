extends Node

## Runtime gather driver, added as an autoload by lit_plugin.gd.
##
## Autoloads don't run in the editor, so this drives the per-frame gather/cull/pack
## only while the game is running; editor-live preview is handled by the EditorPlugin.
##
## The cost here is the pack, not the per-pixel lighting, so a full repack every frame
## is fine. Dirty-tracking would be a later optimization.

const LitLightRegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")

var _registry: LitLightRegistry


func _ready() -> void:
	_registry = LitLightRegistryScript.new()
	# Run after gameplay scripts have moved their lights this frame.
	process_priority = 1000


func _process(_delta: float) -> void:
	_registry.refresh(get_tree(), get_viewport())
