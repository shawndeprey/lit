extends SceneTree

## Library gates, derived entirely from LitShaderLibrary.AXES so a new axis extends
## them automatically: matrix integrity, selection closure, interaction rules, entry files.
## Run: godot --headless --path . --script res://Test/gate_shader_library.gd

const Lib := preload("res://addons/lit/runtime/lit_shader_library.gd")
const Pre := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const SHADER_DIR := "res://addons/lit/shaders/"

var _fails := 0


func _initialize() -> void:
	_gate_matrix()
	_gate_selection_closure()
	_gate_interaction_rules()
	_gate_entry_equivalence()
	_gate_config_parse()
	_gate_default_build()
	print("GATE RESULT: " + ("PASS" if _fails == 0 else "FAIL (%d failures)" % _fails))
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, label: String) -> bool:
	if not ok:
		_fails += 1
		print("  FAIL: " + label)
	return ok


func _gate_matrix() -> void:
	var all: Array = Lib.all_variant_flags()
	print("[gate 1] variant matrix: %d variants from %d axes" % [all.size(), Lib.AXES.size()])
	_check(not all.is_empty(), "matrix non-empty")
	_check(all.size() == 80, "matrix holds 80 variants")
	var names := {}
	var inv := 0
	var src_ok := 0
	for fl in all:
		var f: String = Lib.variant_name(fl) + ".gdshader"
		_check(Lib._prune(fl) == fl, "prune fixed point for flags %d" % fl)
		_check(fl & Lib.F_LINE == 0 or fl & Lib.F_STOCH != 0, "line member carries stoch: %d" % fl)
		_check(fl & (Lib.F_CONE | Lib.F_STOCH) != Lib.F_CONE | Lib.F_STOCH, "no cone+stoch member: %d" % fl)
		_check(not names.has(f), "name unique: %s" % f)
		names[f] = true
		if _check(Lib.flags_from_path(SHADER_DIR + f) == fl, "name<->flags inverse for %s" % f):
			inv += 1
		var p := _parse(Lib.source_for(fl))
		var want := {}
		for axis in Lib.AXES:
			if fl & axis.flag != 0:
				want[axis.define] = true
		var ok: bool = p.defines == want and p.includes.size() == 1 \
				and p.shader_type != "" and p.render_mode != ""
		if _check(ok, "source structure for %s" % f):
			src_ok += 1
	for tier in Lib.ENTRY_PATHS:
		_check(all.has(tier), "entry tier %d is a matrix member" % tier)
	print("  name<->flags inverse: %d/%d; source structure (defines from axes): %d/%d"
			% [inv, all.size(), src_ok, all.size()])


func _gate_selection_closure() -> void:
	print("[gate 2] selection closure (resolve() over every legal input)")
	var node_axes: Array[int] = []
	var act_axes: Array[int] = []
	var tier_mask := 0
	for axis in Lib.AXES:
		match axis.scope:
			"node": node_axes.append(axis.flag)
			"activity": act_axes.append(axis.flag)
			"tier": tier_mask |= axis.flag
	_check(tier_mask == Lib.TIER_MASK, "TIER_MASK equals the tier-scope axes")
	var members := {}
	for fl in Lib.all_variant_flags():
		members[fl] = true
	var ok := 0
	var total := 0
	for tier in Lib.ENTRY_PATHS:
		for nc in 1 << node_axes.size():
			var node := _fold(node_axes, nc)
			for ac in 1 << act_axes.size():
				var act := _fold(act_axes, ac)
				total += 1
				var got: int = Lib.resolve(tier, node, act)
				if _check(members.has(got) and (got & tier_mask) == tier,
						"closure tier=%d node=%d act=%d -> %d" % [tier, node, act, got]):
					ok += 1
	print("  every result is a matrix member with its tier preserved: %d/%d" % [ok, total])


func _fold(flags_list: Array[int], combo: int) -> int:
	var out := 0
	for i in flags_list.size():
		if combo & (1 << i) != 0:
			out |= flags_list[i]
	return out


func _gate_interaction_rules() -> void:
	print("[gate 3] interaction rules (add a row per new axis interaction)")
	var rules := [
		[Lib.F_YSORT, Lib.F_SELF_EXCL, 0, "ysort implies self-exclusion"],
		[Lib.F_LINE, Lib.F_LINE | Lib.F_STOCH, Lib.F_CONE, "line implies stoch"],
		[Lib.F_CONE | Lib.F_STOCH, Lib.F_STOCH, Lib.F_CONE, "stoch folds cone"],
		[Lib.F_CONE | Lib.F_LINE, Lib.F_STOCH | Lib.F_LINE, Lib.F_CONE, "line folds cone into stoch"],
		[Lib.F_MASKS | Lib.F_GX, Lib.F_MASKS, Lib.F_GX, "masks folds gx"],
		[Lib.F_RX | Lib.F_GX, Lib.F_RX, Lib.F_GX, "rx folds gx"],
		[Lib.F_MASKS | Lib.F_RX | Lib.F_GX, Lib.F_MASKS | Lib.F_RX, Lib.F_GX, "masks+rx folds gx"],
	]
	var ok := 0
	for r in rules:
		var got: int = Lib._prune(r[0])
		if _check(got & r[1] == r[1] and got & r[2] == 0, r[3]):
			ok += 1
	print("  rules hold under prune: %d/%d" % [ok, rules.size()])


func _gate_entry_equivalence() -> void:
	print("[gate 4] entry-file equivalence (on-disk tier files vs source_for)")
	var matched := 0
	for tier in Lib.ENTRY_PATHS:
		var path: String = Lib.ENTRY_PATHS[tier]
		var a := _parse(FileAccess.get_file_as_string(path))
		var b := _parse(Lib.source_for(tier))
		var ok: bool = a.shader_type == b.shader_type and a.render_mode == b.render_mode \
				and a.defines == b.defines and a.includes == b.includes
		if _check(ok, "source diff clean for %s" % path.get_file()):
			matched += 1
		else:
			print("    file: %s\n    gen:  %s" % [a, b])
	print("  entry files match generated source: %d/%d" % [matched, Lib.ENTRY_PATHS.size()])


func _gate_config_parse() -> void:
	print("[gate 5] config parse (stale and unknown names rejected, members kept; two Lit warnings expected)")
	var before := _fails
	var was = ProjectSettings.get_setting("lit/render/y_sorting", false)
	ProjectSettings.set_setting("lit/render/y_sorting", false)
	var members := {}
	for fl in Lib.all_variant_flags():
		members[fl] = true
	var cfg := ConfigFile.new()
	cfg.set_value("lit", "shaders", PackedStringArray([]))
	cfg.set_value("lit", "variants", PackedStringArray(["lit_receiver_cone_stoch", "lit_receiver_bogus", "lit_receiver_stoch_line_fast", "lit_receiver_cone"]))
	var work = Pre.parse_config(cfg)
	var clean := work is Array
	for item in (work if work is Array else []):
		clean = clean and members.has(item)
	_check(work is Array and work == [Lib.F_STOCH | Lib.F_LINE, Lib.F_CONE | Lib.F_SELF_EXCL],
			"stale and unknown names skipped, current names kept in order")
	_check(clean, "the work list holds matrix members only")
	cfg.set_value("lit", "variants", PackedStringArray(["lit_receiver_cone_stoch"]))
	_check(Pre.parse_config(cfg) == null, "a config naming only stale variants means the full build")
	cfg.set_value("lit", "variants", PackedStringArray([]))
	var empty = Pre.parse_config(cfg)
	_check(empty is Array and empty.is_empty(), "an empty variant list stays an empty build")
	ProjectSettings.set_setting("lit/render/y_sorting", was)
	print("  rejection and fallback rules hold: %d/4" % (4 - (_fails - before)))


func _gate_default_build() -> void:
	print("[gate 6] default build (the y-sort tier follows lit/render/y_sorting; never saved)")
	var before := _fails
	var was = ProjectSettings.get_setting("lit/render/y_sorting", false)
	ProjectSettings.set_setting("lit/render/y_sorting", false)
	var off: Array[int] = Pre.default_variant_flags()
	var ys := 0
	for fl in off:
		if fl & Lib.F_YSORT != 0:
			ys += 1
	_check(off.size() == 60 and ys == 0, "setting off: 60 variants, none on the y-sort tier (got %d, %d)" % [off.size(), ys])
	ProjectSettings.set_setting("lit/render/y_sorting", true)
	var on: Array[int] = Pre.default_variant_flags()
	_check(on.size() == 80, "setting on: 80 variants (got %d)" % on.size())
	var cfg := ConfigFile.new()
	cfg.set_value("lit", "shaders", PackedStringArray([]))
	var sixty := PackedStringArray()
	for fl in off:
		sixty.append(Lib.variant_name(fl))
	cfg.set_value("lit", "variants", sixty)
	var grown = Pre.parse_config(cfg)
	var grown_ok: bool = grown is Array and grown.size() == 80
	var gseen := {}
	for fl in (grown if grown is Array else []):
		grown_ok = grown_ok and members_of(on).has(fl) and not gseen.has(fl)
		gseen[fl] = true
	_check(grown_ok, "setting on: the 60 non-ysort names grow their 20 y-sort counterparts, deduped (got %d)" % (grown.size() if grown is Array else -1))
	ProjectSettings.set_setting("lit/render/y_sorting", false)
	var same = Pre.parse_config(cfg)
	_check(same is Array and same.size() == 60, "setting off: the same 60 stay 60")
	cfg.set_value("lit", "variants", PackedStringArray(["lit_receiver_stoch_line_ysort"]))
	var dropped = Pre.parse_config(cfg)
	_check(dropped is Array and dropped.is_empty(), "setting off: a listed y-sort variant is left out, not stale (empty, not null)")
	ProjectSettings.set_setting("lit/render/y_sorting", true)
	_check(Pre.parse_config(cfg) == [Lib.F_SELF_EXCL | Lib.F_YSORT | Lib.F_STOCH | Lib.F_LINE], "setting on: it is kept")
	cfg.set_value("lit", "variants", PackedStringArray(["lit_receiver_cone_fast_ramp"]))
	_check(Pre.parse_config(cfg) == [Lib.F_CONE | Lib.F_RAMP, Lib.F_SELF_EXCL | Lib.F_YSORT | Lib.F_CONE],
			"setting on: one fast variant yields itself then its y-sort counterpart only")
	ProjectSettings.set_setting("lit/render/y_sorting", was)
	print("  default-build rules hold: %d/7 (off %d, on %d)" % [7 - (_fails - before), off.size(), on.size()])


func members_of(flags_list: Array[int]) -> Dictionary:
	var d := {}
	for fl in flags_list:
		d[fl] = true
	return d


func _parse(src: String) -> Dictionary:
	var d := {"shader_type": "", "render_mode": "", "defines": {}, "includes": {}}
	for line in src.split("\n"):
		var l: String = line.strip_edges()
		if l.begins_with("shader_type"):
			d.shader_type = l.substr(0, l.find(";") + 1)
		elif l.begins_with("render_mode"):
			d.render_mode = l.substr(0, l.find(";") + 1)
		elif l.begins_with("#define"):
			d.defines[l.substr(7).strip_edges()] = true
		elif l.begins_with("#include"):
			d.includes[l.substr(8).strip_edges()] = true
	return d
