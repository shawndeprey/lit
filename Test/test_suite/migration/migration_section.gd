extends LitSuiteSection

## Schema lock and migrations: every migration file is well formed and in order, every
## scene node class carries the lit_version stamp, and the stored property surface of
## every Lit node class equals the locked baseline advanced through the registered
## migrations (a drift without a migration file is a failure that prints the live
## block to paste).

const Migrations := preload("res://addons/lit/editor/lit_update_tool/migrations/migration_registry.gd")
const NODES_DIR := "res://addons/lit/nodes/"
const STAMP_EXEMPT: Array[StringName] = [&"LitPrecompileOverlay"]


func run() -> void:
	label("schema lock: stored properties of every Lit node class vs the locked baseline + migrations",
			Vector2(24, 74))
	var live := _live_schema()
	_migrations_list()
	_stamp_wiring(live)
	_schema(live)
	_version_helpers()
	var y := 110.0
	for klass in live:
		label("%s: %d stored props" % [klass, live[klass]["props"].size()], Vector2(30, y), 12)
		y += 18.0


func _live_schema() -> Dictionary:
	var out := {}
	for entry in ProjectSettings.get_global_class_list():
		var path := String(entry["path"])
		if not path.begins_with(NODES_DIR):
			continue
		var script := load(path) as GDScript
		if script == null:
			check_true("schema_lock", "could load %s" % path, false)
			continue
		var obj: Object = script.new()
		var props := {}
		for p in obj.get_property_list():
			if p.usage & PROPERTY_USAGE_STORAGE == 0 or p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
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


func _migrations_list() -> void:
	var case_name := "migration_files"
	var migs: Array = Migrations.migrations()
	check(case_name, "migration registry lists every MIGRATION_SCRIPTS entry (%d)" % migs.size(),
			Migrations.MIGRATION_SCRIPTS.size(), migs.size())
	var seen := {}
	var last_to := ""
	var props_by_class := {}
	for klass in Migrations.BASELINE_SCHEMA:
		props_by_class[klass] = Migrations.BASELINE_SCHEMA[klass]["props"].duplicate(true)
	for m in migs:
		var tag := "%s@%s" % [m.target_class, m.to_version]
		check_true(case_name, "entry %s has to_version+target_class" % tag, not String(m.to_version).is_empty() and m.target_class != &"")
		var want_file: String = m.to_version.replace(".", "_") + "_migration.gd"
		check(case_name, "%s file name" % tag, want_file, (m.get_script() as Script).resource_path.get_file())
		check_true(case_name, "%s is past the baseline" % tag, Migrations.semver_cmp(Migrations.BASELINE_VERSION, m.to_version) < 0)
		check_true(case_name, "%s in ascending order" % tag, last_to.is_empty() or Migrations.semver_cmp(last_to, m.to_version) <= 0)
		last_to = m.to_version
		check_true(case_name, "%s unique" % tag, not seen.has(tag))
		seen[tag] = true
		if not check_true(case_name, "%s targets a known class" % tag, props_by_class.has(m.target_class)):
			continue
		var props: Dictionary = props_by_class[m.target_class]
		for old_name in m.renames:
			if check_true(case_name, "%s renames existing prop %s" % [tag, old_name], props.has(old_name)):
				props[m.renames[old_name]] = props[old_name]
				props.erase(old_name)
		for gone in m.removes:
			if check_true(case_name, "%s removes existing prop %s" % [tag, gone], props.has(gone)):
				props.erase(gone)
		for added in m.adds:
			check_true(case_name, "%s adds new prop %s" % [tag, added], not props.has(added))
			props[added] = m.adds[added]
		for retyped in m.retypes:
			check_true(case_name, "%s retypes existing prop %s" % [tag, retyped], props.has(retyped))
		for redefaulted in m.redefaults:
			check_true(case_name, "%s redefaults existing prop %s" % [tag, redefaulted], props.has(redefaulted))


func _stamp_wiring(live: Dictionary) -> void:
	var case_name := "version_stamp"
	for klass in live:
		if klass in STAMP_EXEMPT:
			continue
		var props: Dictionary = live[klass]["props"]
		check_true(case_name, "%s has the lit_version storage property" % klass,
				props.has(&"lit_version") and props[&"lit_version"]["type"] == TYPE_STRING and props[&"lit_version"]["default"] == "")


func _schema(live: Dictionary) -> void:
	var case_name := "schema_lock"
	var expected: Dictionary = Migrations.expected_schema()
	check(case_name, "live class count equals the locked schema", expected.size(), live.size())
	for klass in expected:
		if not check_true(case_name, "expected class %s exists" % klass, live.has(klass)):
			continue
		var drift := PackedStringArray()
		var lp: Dictionary = live[klass]["props"]
		var xp: Dictionary = expected[klass]["props"]
		for prop_name in xp:
			if not lp.has(prop_name):
				drift.append("missing stored prop %s" % prop_name)
			elif lp[prop_name]["type"] != xp[prop_name]["type"]:
				drift.append("prop %s type %s != expected %s" % [prop_name, lp[prop_name]["type"], xp[prop_name]["type"]])
			elif not _defaults_equal(lp[prop_name]["default"], xp[prop_name]["default"]):
				drift.append("prop %s default %s != expected %s" % [prop_name, var_to_str(lp[prop_name]["default"]), var_to_str(xp[prop_name]["default"])])
		for prop_name in lp:
			if not xp.has(prop_name):
				drift.append("new stored prop %s" % prop_name)
		if not check(case_name, "%s matches the locked schema" % klass, "no drift", "no drift" if drift.is_empty() else "; ".join(drift)):
			say("SUITE   %s: add a MIGRATIONS entry describing the change (see docs/release_cut.md)" % klass)
	for klass in live:
		check_true(case_name, "%s has a BASELINE_SCHEMA entry" % klass, expected.has(klass))


func _version_helpers() -> void:
	var case_name := "version_helpers"
	check(case_name, "semver_cmp equal", 0, Migrations.semver_cmp("1.2", "1.2.0"))
	check(case_name, "semver_cmp less", -1, Migrations.semver_cmp("1.1.9", "1.2.0"))
	check(case_name, "semver_cmp greater", 1, Migrations.semver_cmp("2.0.0", "1.9.9"))
	check(case_name, "current_version is the plugin.cfg version", lit_version, Migrations.current_version())
	var n := LitPointLight2D.new()
	check(case_name, "unstamped node reports the baseline version", Migrations.BASELINE_VERSION, Migrations.node_version(n))
	n.lit_version = "9.9.9"
	check(case_name, "stamped node reports its stamp", "9.9.9", Migrations.node_version(n))
	n.free()
	check_true(case_name, "lit_scripts_by_path maps the sprite script to its class",
			Migrations.lit_scripts_by_path().get("res://addons/lit/nodes/lit_sprite_2d.gd") == &"LitSprite2D")
