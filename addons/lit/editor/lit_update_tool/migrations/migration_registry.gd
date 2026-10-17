@tool
extends RefCounted

## Version framework for "Update Project to Lit".
##
## baseline_schema.gd locks the stored property surface of every Lit node class as
## of BASELINE_VERSION; it only advances through the migration files registered in
## MIGRATION_SCRIPTS (one file per breaking change - see migration.gd for the
## pattern). Test/gate_migration_schema.gd fails whenever a class's live schema
## drifts from the baseline advanced through the chain, so a PR that renames,
## removes, retypes, re-defaults, or adds a stored property on a Lit node must ship
## the matching migration file (or, pre-release, a baseline update) to go green.
##
## The update tool chains a node's migrations oldest-to-newest from its stamped
## `lit_version` (unstamped nodes are assumed BASELINE_VERSION). Every chain helper
## takes an optional `migs` list in place of the registered one (tests inject
## synthetic chains).

const Schema := preload("res://addons/lit/editor/lit_update_tool/migrations/baseline_schema.gd")

const BASELINE_VERSION := Schema.BASELINE_VERSION
const BASELINE_SCHEMA := Schema.BASELINE_SCHEMA

# One preload per breaking change, ascending by version:
#   preload("res://addons/lit/editor/lit_update_tool/migrations/1_2_0_migration.gd"),
const MIGRATION_SCRIPTS: Array[GDScript] = []


static func migrations() -> Array:
	var out := []
	for s in MIGRATION_SCRIPTS:
		out.append(s.new())
	return out


static func current_version() -> String:
	return LitShaderLibrary._get_version()


## -1, 0, or 1; missing components count as 0 ("1.2" == "1.2.0").
static func semver_cmp(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var na := int(pa[i]) if i < pa.size() else 0
		var nb := int(pb[i]) if i < pb.size() else 0
		if na != nb:
			return -1 if na < nb else 1
	return 0


## The version a node's saved data is shaped as: its stamp, a legacy meta stamp, or
## the baseline for unstamped nodes.
static func node_version(node: Node) -> String:
	var v: Variant = node.get(&"lit_version")
	if v is String and not (v as String).is_empty():
		return v
	if node.has_meta(&"lit_version"):
		return str(node.get_meta(&"lit_version"))
	return BASELINE_VERSION


## Migrations that still apply to a node of `klass` whose data is at `from_version`,
## oldest first.
static func chain_for(klass: StringName, from_version: String, migs: Variant = null) -> Array:
	var out := []
	for m in (migrations() if migs == null else migs):
		if m.target_class == klass and semver_cmp(from_version, m.to_version) < 0:
			out.append(m)
	return out


## Retired name -> live name after every rename in a node's remaining chain (a name
## renamed twice maps straight to its final name, as does the intermediate one); drives
## the instance-override and animation-track remaps.
static func rename_chain(klass: StringName, from_version: String, migs: Variant = null) -> Dictionary:
	var out := {}
	for m in chain_for(klass, from_version, migs):
		for old_name in m.renames:
			var new_name: StringName = m.renames[old_name]
			for k in out:
				if out[k] == old_name:
					out[k] = new_name
			out[String(old_name)] = new_name
	return out


## {class: {stored name: true}} for every name a rename retires.
static func retired_names(migs: Variant = null) -> Dictionary:
	var out := {}
	for m in (migrations() if migs == null else migs):
		for old_name in m.renames:
			if not out.has(m.target_class):
				out[m.target_class] = {}
			out[m.target_class][String(old_name)] = true
	return out


## Run a node's remaining chain against its live self plus its as-saved property
## capture; the capture is re-shaped step by step so later migrations read renamed
## data under its new name. Returns true when anything changed.
static func apply_chain(node: Node, klass: StringName, stored: Dictionary, report: Array,
		migs: Variant = null) -> bool:
	var data := stored.duplicate()
	var changed := false
	for m in chain_for(klass, node_version(node), migs):
		for old_name in m.renames:
			var key := String(old_name)
			if not data.has(key):
				continue
			var new_name: StringName = m.renames[old_name]
			node.set(new_name, data[key])
			data[String(new_name)] = data[key]
			data.erase(key)
			changed = true
			report.append("MIGRATED %s: %s -> %s (to v%s)"
					% [node.name, old_name, new_name, m.to_version])
		if m.apply(node, data, report):
			changed = true
	return changed


## BASELINE_SCHEMA advanced through the migration chain: what the live classes must
## look like.
static func expected_schema() -> Dictionary:
	var schema := {}
	for klass in BASELINE_SCHEMA:
		schema[klass] = {
			"script": BASELINE_SCHEMA[klass]["script"],
			"props": BASELINE_SCHEMA[klass]["props"].duplicate(true),
		}
	for m in migrations():
		var props: Dictionary = schema[m.target_class]["props"]
		for old_name in m.renames:
			props[m.renames[old_name]] = props[old_name]
			props.erase(old_name)
		for gone in m.removes:
			props.erase(gone)
		for added in m.adds:
			props[added] = m.adds[added]
		for retyped in m.retypes:
			props[retyped]["type"] = m.retypes[retyped]["type"]
		for redefaulted in m.redefaults:
			props[redefaulted]["default"] = m.redefaults[redefaulted]
	return schema


## Lit node script path -> class name, off the schema.
static func lit_scripts_by_path() -> Dictionary:
	var out := {}
	for klass in BASELINE_SCHEMA:
		out[String(BASELINE_SCHEMA[klass]["script"])] = klass
	return out
