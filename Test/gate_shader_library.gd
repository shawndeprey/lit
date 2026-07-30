extends SceneTree

## Library gates, derived entirely from LitShaderLibrary.AXES so a new axis extends
## them automatically: matrix integrity, selection closure, interaction rules, entry files.
## Run: godot --headless --path . --script res://Test/gate_shader_library.gd

const Lib := preload("res://addons/lit/runtime/lit_shader_library.gd")
const SHADER_DIR := "res://addons/lit/shaders/"

var _fails := 0


func _initialize() -> void:
	_gate_matrix()
	_gate_selection_closure()
	_gate_interaction_rules()
	_gate_entry_equivalence()
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
	var names := {}
	var inv := 0
	var src_ok := 0
	for fl in all:
		var f: String = Lib.variant_name(fl) + ".gdshader"
		_check(Lib._prune(fl) == fl, "prune fixed point for flags %d" % fl)
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
