extends SceneTree

## Schema-lock gate: the stored property surface of every Lit node class must equal
## BASELINE_SCHEMA (lit_migrations.gd) advanced through MIGRATIONS. Any drift without
## a matching migration entry fails, printing the paste-ready block. Also validates
## the MIGRATIONS list itself and that every scene node class carries `lit_version`.
## Run:  godot --headless --path . --script res://Test/gate_migration_schema.gd
## Dump: godot --headless --path . --script res://Test/gate_migration_schema.gd -- --dump

const Migrations := preload("res://addons/lit/editor/lit_migrations.gd")

const NODES_DIR := "res://addons/lit/nodes/"
# Code-built only, never saved in scenes; exempt from the lit_version requirement.
const STAMP_EXEMPT: Array[StringName] = [&"LitPrecompileOverlay"]

const TYPE_NAMES := {
	TYPE_NIL: "TYPE_NIL", TYPE_BOOL: "TYPE_BOOL", TYPE_INT: "TYPE_INT",
	TYPE_FLOAT: "TYPE_FLOAT", TYPE_STRING: "TYPE_STRING", TYPE_VECTOR2: "TYPE_VECTOR2",
	TYPE_VECTOR2I: "TYPE_VECTOR2I", TYPE_RECT2: "TYPE_RECT2", TYPE_COLOR: "TYPE_COLOR",
	TYPE_STRING_NAME: "TYPE_STRING_NAME", TYPE_NODE_PATH: "TYPE_NODE_PATH",
	TYPE_OBJECT: "TYPE_OBJECT", TYPE_DICTIONARY: "TYPE_DICTIONARY", TYPE_ARRAY: "TYPE_ARRAY",
}

var _fails := 0


func _initialize() -> void:
	var live := _live_schema()
	if "--dump" in OS.get_cmdline_user_args():
		print(_format_schema(live))
		quit(0)
		return
	_gate_migrations_list()
	_gate_stamp_wiring(live)
	_gate_schema(live)
	print("GATE RESULT: " + ("PASS" if _fails == 0 else "FAIL (%d failures)" % _fails))
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, label: String) -> bool:
	if not ok:
		_fails += 1
		print("  FAIL: " + label)
	return ok


## {class_name: {script, props: {name: {type, default}}}} for every global class under
## the nodes dir, read off a fresh off-tree instance. Object defaults are normalized to
## their resource_path so the schema stays a literal.
func _live_schema() -> Dictionary:
	var out := {}
	for entry in ProjectSettings.get_global_class_list():
		var path := String(entry["path"])
		if not path.begins_with(NODES_DIR):
			continue
		var script := load(path) as GDScript
		if script == null:
			_check(false, "could not load %s" % path)
			continue
		var obj: Object = script.new()
		var props := {}
		for p in obj.get_property_list():
			if p.usage & PROPERTY_USAGE_STORAGE == 0 \
					or p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			props[StringName(p.name)] = {"type": p.type, "default": _norm(obj.get(p.name))}
		out[StringName(entry["class"])] = {"script": path, "props": props}
		if obj is Node:
			(obj as Node).free()
	return out


func _norm(value: Variant) -> Variant:
	if value is Resource:
		return (value as Resource).resource_path
	return value


func _defaults_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_FLOAT:
			return is_equal_approx(a, b)
		TYPE_COLOR:
			return (a as Color).is_equal_approx(b)
		TYPE_VECTOR2:
			return (a as Vector2).is_equal_approx(b)
		_:
			return a == b


func _gate_migrations_list() -> void:
	print("[gate 1] MIGRATIONS list integrity (%d entries)" % Migrations.MIGRATIONS.size())
	var method_names := {}
	var migrations_script: Script = Migrations
	for m in migrations_script.get_script_method_list():
		method_names[m.name] = true
	var seen := {}
	var last_to := ""
	# Replays the schema advance so every rename/remove/retype target is validated
	# before expected_schema() would hit it.
	var props_by_class := {}
	for klass in Migrations.BASELINE_SCHEMA:
		props_by_class[klass] = Migrations.BASELINE_SCHEMA[klass]["props"].duplicate(true)
	for m in Migrations.MIGRATIONS:
		var tag := "%s@%s" % [m.get("class"), m.get("to")]
		_check(m.has("to") and m.has("class"), "entry %s has to+class" % tag)
		_check(Migrations.semver_cmp(Migrations.BASELINE_VERSION, m["to"]) < 0,
				"%s is past the baseline" % tag)
		_check(last_to.is_empty() or Migrations.semver_cmp(last_to, m["to"]) <= 0,
				"%s in ascending version order" % tag)
		last_to = m["to"]
		_check(not seen.has(tag), "%s unique" % tag)
		seen[tag] = true
		if not _check(props_by_class.has(m["class"]), "%s targets a known class" % tag):
			continue
		var props: Dictionary = props_by_class[m["class"]]
		var renames: Dictionary = m.get("renames", {})
		for old_name in renames:
			if _check(props.has(old_name), "%s renames existing prop %s" % [tag, old_name]):
				props[renames[old_name]] = props[old_name]
				props.erase(old_name)
		for gone in m.get("removes", []):
			if _check(props.has(gone), "%s removes existing prop %s" % [tag, gone]):
				props.erase(gone)
		for added in m.get("adds", {}):
			_check(not props.has(added), "%s adds new prop %s" % [tag, added])
			props[added] = m["adds"][added]
		for retyped in m.get("retypes", {}):
			_check(props.has(retyped), "%s retypes existing prop %s" % [tag, retyped])
		for redefaulted in m.get("redefaults", {}):
			_check(props.has(redefaulted), "%s redefaults existing prop %s" % [tag, redefaulted])
		if m.has("apply"):
			_check(method_names.has(String(m["apply"])), "%s apply func exists" % tag)


func _gate_stamp_wiring(live: Dictionary) -> void:
	print("[gate 2] lit_version stamp on every scene node class")
	for klass in live:
		if klass in STAMP_EXEMPT:
			continue
		var props: Dictionary = live[klass]["props"]
		_check(props.has(&"lit_version") and props[&"lit_version"]["type"] == TYPE_STRING \
				and props[&"lit_version"]["default"] == "",
				"%s has the lit_version storage property" % klass)


func _gate_schema(live: Dictionary) -> void:
	var expected: Dictionary = Migrations.expected_schema()
	print("[gate 3] schema lock: %d live classes vs %d expected" % [live.size(), expected.size()])
	for klass in expected:
		if not _check(live.has(klass), "expected class %s exists (removed? add a migration " % klass
				+ "or, for a deliberate class removal, a schema change with rationale)"):
			continue
		var drift := PackedStringArray()
		var lp: Dictionary = live[klass]["props"]
		var xp: Dictionary = expected[klass]["props"]
		for prop_name in xp:
			if not lp.has(prop_name):
				drift.append("missing stored prop %s" % prop_name)
			elif lp[prop_name]["type"] != xp[prop_name]["type"]:
				drift.append("prop %s type %s != expected %s"
						% [prop_name, lp[prop_name]["type"], xp[prop_name]["type"]])
			elif not _defaults_equal(lp[prop_name]["default"], xp[prop_name]["default"]):
				drift.append("prop %s default %s != expected %s" % [prop_name,
						var_to_str(lp[prop_name]["default"]), var_to_str(xp[prop_name]["default"])])
		for prop_name in lp:
			if not xp.has(prop_name):
				drift.append("new stored prop %s" % prop_name)
		if not _check(drift.is_empty(), "%s matches the locked schema" % klass):
			for d in drift:
				print("        " + d)
			print("    Add a MIGRATIONS entry describing the change; current live block:")
			print(_format_class(klass, live[klass], "    "))
	for klass in live:
		_check(expected.has(klass), ("new Lit node class %s: add its BASELINE_SCHEMA entry " +
				"(new classes need no migrations); live block:\n%s")
				% [klass, _format_class(klass, live[klass], "    ")])


func _format_schema(schema: Dictionary) -> String:
	var names: Array = schema.keys().map(func(k: StringName) -> String: return String(k))
	names.sort()
	var lines := ["const BASELINE_SCHEMA := {"]
	for klass in names:
		lines.append(_format_class(klass, schema[StringName(klass)], "\t"))
	lines.append("}")
	return "\n".join(lines)


func _format_class(klass: StringName, entry: Dictionary, indent: String) -> String:
	var lines := ['%s&"%s": {' % [indent, klass]]
	lines.append('%s\t"script": "%s",' % [indent, entry["script"]])
	lines.append('%s\t"props": {' % indent)
	var prop_names: Array = entry["props"].keys().map(func(k: StringName) -> String: return String(k))
	prop_names.sort()
	for prop_name in prop_names:
		var p: Dictionary = entry["props"][StringName(prop_name)]
		var type_repr: String = TYPE_NAMES.get(p["type"], str(p["type"]))
		lines.append('%s\t\t&"%s": {"type": %s, "default": %s},'
				% [indent, prop_name, type_repr, var_to_str(p["default"])])
	lines.append("%s\t}," % indent)
	lines.append("%s}," % indent)
	return "\n".join(lines)
