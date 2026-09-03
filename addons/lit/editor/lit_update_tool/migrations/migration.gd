@tool
extends RefCounted

## One breaking Lit change = one file in this folder, named for the version that
## ships it: `1_2_0_migration.gd` migrates node data authored before Lit 1.2.0.
##
## To add a migration for a breaking change to what a Lit node stores:
##  1. Create migrations/X_Y_Z_migration.gd extending this script; fill the fields
##     in _init, and override apply() only when data must move in ways the field
##     tables cannot express.
##  2. Append its preload to MIGRATION_SCRIPTS in migration_registry.gd.
##  3. Run the schema gate; it validates the file (naming, ordering, field targets)
##     and the baseline advanced through it:
##       godot --headless --path . --script res://Test/gate_migration_schema.gd
##
## Godot drops stored values for renamed/removed script properties at load, so
## apply() reads old values from `stored` (the update tool's SceneState capture of
## the node's saved properties), never off the live node. apply() must be
## idempotent: guard on the old stored name or the node's stamped version.

## Version whose release ships this change; nodes stamped older get migrated.
var to_version := ""
## The one Lit class this migration touches (one file per class per version).
var target_class: StringName = &""
## {&"old_name": &"new_name"} - re-applied automatically from stored data; also
## drives the instance-override remap in parent scenes.
var renames := {}
## {&"prop": {"type": TYPE_FLOAT, "default": 1.0}} - new stored properties.
var adds := {}
## [&"gone"] - stored properties that no longer exist.
var removes: Array = []
## {&"prop": {"type": TYPE_INT}} - properties whose Variant type changed.
var retypes := {}
## {&"prop": 2.0} - properties whose default changed.
var redefaults := {}


## Move data the field tables can't express. Returns true when the node changed.
func apply(_node: Node, _stored: Dictionary, _report: Array) -> bool:
	return false
