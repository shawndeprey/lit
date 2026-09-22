extends LitSuiteSection

## Shader library and precompile: the variant matrix derived from the axes (names,
## flags round trips, selection closure, interaction rules, entry files matching the
## generated source), every variant compiled and rendered by the real renderer (a
## broken variant falls back to the unlit material and reads white in the dark), the
## on-disk entry shaders, the world-SDF encode pipeline, and the precompiler's work
## list, bundle hash, marker, config file, labels, and overlay.

const Lib := preload("res://addons/lit/runtime/lit_shader_library.gd")
const Pre := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const Overlay := preload("res://addons/lit/nodes/lit_precompile_overlay.gd")
const Config := preload("res://addons/lit/editor/lit_precompile_config.gd")
const SHADER_DIR := "res://addons/lit/shaders/"
const AMBIENT := 0.1


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_matrix()
	_selection_closure()
	_interaction_rules()
	_entry_equivalence()
	await _render_matrix()
	_precompiler()
	await _overlay()


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


func _matrix() -> void:
	var case_name := "variant_matrix"
	var all: Array = Lib.all_variant_flags()
	check_true(case_name, "matrix non-empty (%d variants from %d axes)" % [all.size(), Lib.AXES.size()], not all.is_empty())
	var names := {}
	var ok_prune := true
	var ok_unique := true
	var ok_inverse := true
	var ok_src := true
	var ok_flags_of := true
	for fl in all:
		var f: String = Lib.variant_name(fl) + ".gdshader"
		ok_prune = ok_prune and Lib._prune(fl) == fl
		ok_unique = ok_unique and not names.has(f)
		names[f] = true
		ok_inverse = ok_inverse and Lib.flags_from_path(SHADER_DIR + f) == fl \
				and Lib.flags_from_variant_name(f.get_basename()) == fl
		var p := _parse(Lib.source_for(fl))
		var want := {}
		for axis in Lib.AXES:
			if fl & axis.flag != 0:
				want[axis.define] = true
		ok_src = ok_src and p.defines == want and p.includes.size() == 1 and p.shader_type != "" and p.render_mode != ""
		ok_flags_of = ok_flags_of and Lib.flags_of(Lib.get_receiver(fl)) == fl
	check_true(case_name, "prune is a fixed point on every member", ok_prune)
	check_true(case_name, "variant names are unique", ok_unique)
	check_true(case_name, "name <-> flags inverse for every variant", ok_inverse)
	check_true(case_name, "generated source: defines from the axes, one include", ok_src)
	check_true(case_name, "flags_of reads the flags back from generated shaders", ok_flags_of)
	for tier in Lib.ENTRY_PATHS:
		check_true(case_name, "entry tier %d is a matrix member" % tier, all.has(tier))
	check(case_name, "unknown variant name maps to -1", -1, Lib.flags_from_variant_name("lit_receiver_bogus"))
	check(case_name, "non-Lit shader path maps to -1", -1, Lib.flags_from_path("res://foo.gdshader"))
	check_true(case_name, "get_receiver caches (same object twice)", is_same(Lib.get_receiver(Lib.F_CONE), Lib.get_receiver(Lib.F_CONE)))
	check_true(case_name, "generated source carries the plugin version", Lib.source_for(0).contains("lit_version=%s" % lit_version))


func _fold(flags_list: Array[int], combo: int) -> int:
	var out := 0
	for i in flags_list.size():
		if combo & (1 << i) != 0:
			out |= flags_list[i]
	return out


func _selection_closure() -> void:
	var case_name := "variant_selection"
	var node_axes: Array[int] = []
	var act_axes: Array[int] = []
	var tier_mask := 0
	for axis in Lib.AXES:
		match axis.scope:
			"node": node_axes.append(axis.flag)
			"activity": act_axes.append(axis.flag)
			"tier": tier_mask |= axis.flag
	check(case_name, "TIER_MASK equals the tier-scope axes", tier_mask, Lib.TIER_MASK)
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
				if members.has(got) and (got & tier_mask) == tier:
					ok += 1
	check(case_name, "resolve() over every legal input lands on a member with its tier preserved", total, ok)


func _interaction_rules() -> void:
	var case_name := "variant_rules"
	var rules := [
		[Lib.F_YSORT, Lib.F_SELF_EXCL, 0, "ysort implies self-exclusion"],
		[Lib.F_MASKS | Lib.F_GX, Lib.F_MASKS, Lib.F_GX, "masks folds gx"],
		[Lib.F_RX | Lib.F_GX, Lib.F_RX, Lib.F_GX, "rx folds gx"],
		[Lib.F_MASKS | Lib.F_RX | Lib.F_GX, Lib.F_MASKS | Lib.F_RX, Lib.F_GX, "masks+rx folds gx"],
	]
	for r in rules:
		var got: int = Lib._prune(r[0])
		check_true(case_name, r[3], got & r[1] == r[1] and got & r[2] == 0)


func _entry_equivalence() -> void:
	var case_name := "entry_shaders"
	for tier in Lib.ENTRY_PATHS:
		var path: String = Lib.ENTRY_PATHS[tier]
		var a := _parse(FileAccess.get_file_as_string(path))
		var b := _parse(Lib.source_for(tier))
		check_true(case_name, "%s matches the generated source for its tier" % path.get_file(),
				a.shader_type == b.shader_type and a.render_mode == b.render_mode and a.defines == b.defines and a.includes == b.includes)
		var sh := load(path) as Shader
		check_true(case_name, "%s compiles (uniforms visible)" % path.get_file(), sh != null and sh.get_shader_uniform_list().size() > 10)
		check(case_name, "%s flags_of from its path" % path.get_file(), tier, Lib.flags_of(sh))
	check_true(case_name, "common include resolves", ResourceLoader.exists(Lib.COMMON_INCLUDE_PATH))
	check(case_name, "every include unit ships", 10, Lib.INCLUDE_UNITS.size())


func _render_matrix() -> void:
	var case_name := "variant_render"
	var all: Array = Lib.all_variant_flags()
	label("every receiver variant rendered: dark with no light, lit under one (a broken variant reads white)",
			Vector2(24, 74))
	var sprites: Array = []
	var origin := Vector2(60, 130)
	var t0 := Time.get_ticks_msec()
	for i in all.size():
		var fl: int = all[i]
		var s := Sprite2D.new()
		s.texture = tex_sized(Vector2(36, 36))
		var mat := ShaderMaterial.new()
		mat.shader = Lib.get_receiver(fl)
		s.material = mat
		@warning_ignore("integer_division")
		s.position = origin + Vector2((i % 12) * 100, (i / 12) * 110)
		add_child(s)
		label(Lib.variant_name(fl).trim_prefix("lit_receiver_").replace("_", "\n"), s.position + Vector2(-18, 22), 9)
		sprites.append([fl, s])
	var t1 := Time.get_ticks_msec()
	await frames(3)
	var t2 := Time.get_ticks_msec()
	var img := await capture()
	say("SUITE   variant matrix: %d shaders created in %d ms, first 3 frames %d ms" % [all.size(), t1 - t0, t2 - t1])
	var dark_ok := 0
	var compiled := 0
	var kept := 0
	for e in sprites:
		var v := lum(img, e[1].position, 4)
		if v < AMBIENT + 0.08:
			dark_ok += 1
		else:
			check_approx(case_name, "%s renders dark with no light" % Lib.variant_name(e[0]), AMBIENT, v, 0.08)
		if (e[1].material as ShaderMaterial).shader.get_shader_uniform_list().size() > 10:
			compiled += 1
		if Lib.flags_of((e[1].material as ShaderMaterial).shader) == e[0]:
			kept += 1
	say("SUITE   variant matrix: uniform lists read in %d ms" % (Time.get_ticks_msec() - t2))
	check(case_name, "variants reporting their uniforms (compiled under the real renderer)", all.size(), compiled)
	check(case_name, "variants rendering ambient-dark with no light (no fallback-white)", all.size(), dark_ok)
	check(case_name, "the registry left every variant on its own shader (no activity, no walk)", all.size(), kept)
	var l := point_light(Vector2(640, 300), 900.0, 0.6, Color.WHITE, 400.0)
	l.falloff = 0.0
	await frames(2)
	img = await capture()
	var lit_ok := 0
	for e in sprites:
		var v := lum(img, e[1].position, 4)
		if v > AMBIENT + 0.25:
			lit_ok += 1
		else:
			check_gt(case_name, "%s lights up under a point light" % Lib.variant_name(e[0]), v, AMBIENT, 0.25)
	check(case_name, "variants lit by a point light", all.size(), lit_ok)
	l.queue_free()
	var mgr := get_node("/root/LitManager")
	var wsdf := mgr.get_node_or_null("LitWorldSdf") as SubViewport
	check_true("world_sdf", "the world-SDF SubViewport lives under LitManager", wsdf != null)
	check_true("world_sdf", "world-SDF encode shader compiled",
			wsdf != null and (wsdf.get_child(0).get_child(0).material as ShaderMaterial).shader.get_shader_uniform_list().size() > 0)
	check(("world_sdf"), "R16F pack pipeline ready on a RenderingDevice renderer", 2, mgr._registry._world_sdf._wsdf_rd_init)


func _precompiler() -> void:
	var case_name := "precompile"
	var work: Array = Pre.work_list()
	var has_entries := true
	for tier in Lib.ENTRY_PATHS:
		has_entries = has_entries and work.has(Lib.ENTRY_PATHS[tier])
	var has_variants := true
	for fl in Lib.all_variant_flags():
		has_variants = has_variants and work.has(fl)
	var cfg_present := FileAccess.file_exists(Pre.CONFIG_PATH)
	if cfg_present:
		check_true(case_name, "a lit_precompile.cfg is present: work list comes from it", work.size() > 0)
	else:
		check_true(case_name, "full work list carries the entry files", has_entries)
		check_true(case_name, "full work list carries the world-SDF encode shader", work.has("res://addons/lit/shaders/sdf/lit_world_sdf_encode.gdshader"))
		check_true(case_name, "full work list carries every receiver variant", has_variants)
	check(case_name, "static shaders: three entries + encoder", 4, Pre.static_shaders().size())
	var h1: String = Pre.bundle_hash(work)
	check_true(case_name, "bundle hash is a 32-char md5", h1.length() == 32)
	check(case_name, "bundle hash is deterministic", h1, Pre.bundle_hash(work))
	check_true(case_name, "bundle hash changes with the work list", Pre.bundle_hash([0]) != h1)
	if bool(ProjectSettings.get_setting("lit/startup/precompile_shaders", true)):
		check_true(case_name, "marker fresh after this run's boot precompile", Pre.marker_fresh(work))
	check_true(case_name, "marker not fresh for a different work list", not Pre.marker_fresh([0]))
	check(case_name, "variant_label(0)", "base", Pre.variant_label(0))
	check_true(case_name, "variant_label names the axes", Pre.variant_label(Lib.F_CONE | Lib.F_SELF_EXCL).contains("shadow_cone")
			and Pre.variant_label(Lib.F_CONE | Lib.F_SELF_EXCL).contains("self_exclusion"))
	check(case_name, "item_label of a path is its basename", "lit_receiver_fast", Pre.item_label(Lib.ENTRY_PATHS[0]))
	check(case_name, "done_key of a variant", "f_%d" % Lib.F_CONE, Pre.done_key(Lib.F_CONE))
	check_true(case_name, "done_key of a path is stable", Pre.done_key("a") == Pre.done_key("a") and Pre.done_key("a") != Pre.done_key("b"))
	if not cfg_present:
		var cfg := ConfigFile.new()
		# (Unknown shader paths and variant names are skipped with a Lit warning; that path
		# is left unexercised so a green run stays warning-free.)
		cfg.set_value("lit", "shaders", PackedStringArray([Lib.ENTRY_PATHS[0]]))
		cfg.set_value("lit", "variants", PackedStringArray(["lit_receiver_fast", "lit_receiver_cone"]))
		if cfg.save(Pre.CONFIG_PATH) == OK:
			var parsed = Pre.config_work_list()
			DirAccess.remove_absolute(Pre.CONFIG_PATH)
			check_true(case_name, "config file: shader paths and variant names parse into a work list",
					parsed is Array and parsed.size() == 3 and parsed[0] == Lib.ENTRY_PATHS[0]
					and parsed[1] == 0 and parsed[2] == (Lib.F_CONE | Lib.F_SELF_EXCL))
			check_true(case_name, "config file removed again", not FileAccess.file_exists(Pre.CONFIG_PATH))
		check_true(case_name, "no config file: config_work_list is null", Pre.config_work_list() == null)
	var used = Pre.used_post_shaders()
	var all_post := used is Array
	for pth in (used if used is Array else []):
		all_post = all_post and String(pth).ends_with(".gdshader") and ResourceLoader.exists(String(pth))
	check_true(case_name, "used_post_shaders() lists existing post-effect shaders referenced by saved scenes (%d found)" % (used.size() if used is Array else -1),
			all_post)
	if not cfg_present:
		# The editor's "Generate Lit Precompile Config" is runtime-safe: scan the saved
		# scenes, write the config, parse it back, remove it again.
		var gen: Dictionary = Config.generate()
		check_true(case_name, "Generate Lit Precompile Config writes lit_precompile.cfg",
				bool(gen.get("saved", false)) and FileAccess.file_exists(Pre.CONFIG_PATH))
		check_true(case_name, "generated config lists the fast receiver variant and the entry shaders",
				Array(gen.get("variants", [])).has("lit_receiver_fast") and Array(gen.get("shaders", [])).has(Lib.ENTRY_PATHS[0]))
		var listed = Pre.config_work_list()
		check_true(case_name, "generated config parses back into a non-empty work list", listed is Array and listed.size() > 0)
		DirAccess.remove_absolute(Pre.CONFIG_PATH)
		check_true(case_name, "generated config removed again", not FileAccess.file_exists(Pre.CONFIG_PATH))
	var mgr := get_node("/root/LitManager")
	check_true(case_name, "LitManager exposes precompile_shaders()", mgr.has_method("precompile_shaders"))
	check_true(case_name, "LitManager exposes the progress and finished signals",
			mgr.has_signal("precompile_progress") and mgr.has_signal("precompile_finished"))


func _overlay() -> void:
	var case_name := "precompile_overlay"
	set_setting("lit/startup/precompile_title", "Suite Title")
	set_setting("lit/startup/precompile_verbose", true)
	var pre := Pre.new()
	add_child(pre)
	var ov := Overlay.new()
	ov.attach(pre)
	add_child(ov)
	await frames(1)
	check_true(case_name, "takeover overlay builds a progress bar", not ov.find_children("*", "ProgressBar", true, false).is_empty())
	check(case_name, "overlay sits on layer 128 (above game HUDs)", 128, ov.layer)
	var titled := false
	for lbl in ov.find_children("*", "Label", true, false):
		titled = titled or (lbl as Label).text == "Suite Title"
	check_true(case_name, "lit/startup/precompile_title names the overlay", titled)
	check_true(case_name, "precompile_verbose on: a detail label exists", ov._detail != null)
	pre.progress.emit(3, 10, "shadow_cone")
	check_approx(case_name, "progress signal drives the bar (3 of 10)", 3.0, float(ov._bar.value), 0.01)
	check(case_name, "progress signal drives the counter", "3/10", ov._count.text)
	check(case_name, "progress label lands in the detail line", "shadow_cone", ov._detail.text)
	pre.finished.emit()
	var waited := 0.0
	while is_instance_valid(ov) and waited < 3.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	check_true(case_name, "finished fades the overlay out and frees it", not is_instance_valid(ov))
	if is_instance_valid(ov):
		ov.queue_free()
	pre.queue_free()
	set_setting("lit/startup/precompile_verbose", false)
	var pre2 := Pre.new()
	add_child(pre2)
	var ov2 := Overlay.new()
	ov2.attach(pre2)
	add_child(ov2)
	await frames(1)
	check_true(case_name, "precompile_verbose off: no detail label", ov2._detail == null)
	ov2.queue_free()
	pre2.queue_free()
	await frames(1)
