extends "res://Test/integration_tests/line_light_review/checks/review_section.gd"

## Issue 4: the precompile work list drops the fast-tier ramp variants, but the game still
## requests them, so they compile mid-game after a precompile and debug builds warn.
##
## LitShaderPrecompiler.dedupe() (new in this PR) drops every variant F_RAMP|X whose
## full-tier sibling F_SELF_EXCL|X is listed: the two are twins, because LIT_OCC_RAMP
## turns on LIT_SELF_EXCLUSION in lit_header.gdshaderinc. But the runtime never folds
## them: a fast-tier receiver under ramp activity resolves to F_RAMP|X
## (LitShaderLibrary._prune keeps F_RAMP without F_SELF_EXCL), a different key in
## LitShaderLibrary._receivers. _mark_warmed() and the silent/build passes only see the
## folded list, so that request misses: a new Shader is created and compiled on the main
## thread, and debug builds log "compiled mid-game ... regenerate lit_precompile.cfg".
## Regenerating cannot help: work_list() runs dedupe() on the configured list too.
##
## The GPU code of the twins is the same (only the #define line differs), so the driver
## cache usually hits; the cost is the Shader object, its parse and its pipelines, plus
## a warning that cannot be made to go away.
##
## Exhibit: a floor (fast tier), a point light, and a small receiver with an occluder
## beside it. The run (1) checks the work list against what the runtime can request,
## (2) runs the real silent precompile pass (what every launch after a precompile does),
## (3) turns on a shadow_ramp so the floor moves to the ramp variant, and (4) reports the
## warning and the main-thread cost of the miss.

class WarningCatcher extends Logger:
	var lines: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_mutex.lock()
		lines.append(code + " " + rationale)
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func matching(text: String) -> PackedStringArray:
		_mutex.lock()
		var out := PackedStringArray()
		for l in lines:
			if l.contains(text):
				out.append(l)
		_mutex.unlock()
		return out


const FLOOR_RECT := Rect2(40, 60, 1340, 1000)

var _catcher := WarningCatcher.new()


func _exit_tree() -> void:
	OS.remove_logger(_catcher)
	super()


func run() -> void:
	OS.add_logger(_catcher)
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	var fl := floor_receiver(FLOOR_RECT)
	var light := point_light(Vector2(500, 400), 420.0, 0.9, Color.WHITE, 80.0)
	light.shadow_enabled = true
	light.shadow_algorithm = ALGO.RAYMARCHED
	# The post and the occluder share their own group, so the occluder is the post's
	# sibling (its shadow_ramp applies to it) and not the floor's (the floor stays on the
	# fast tier, which is the tier whose ramp variants are folded away).
	var props := group("Props")
	var post := box_receiver(Vector2(560, 520), Vector2(8, 8), Color.WHITE, props)
	post.specular_strength = 0.0
	occluder(Vector2(600, 400), Vector2(16, 120), props)
	label("floor (fast tier) + point light + a receiver beside a 16 px occluder; the receiver's shadow_ramp turns on mid-run",
			Vector2(52, 80), 13)

	# (1) Static: what the runtime can request vs what the precompiler lists.
	var c := "work_list"
	var work: Array = LitShaderPrecompiler.work_list()
	var listed := {}
	for item in work:
		if item is int:
			listed[item] = true
	var requested_missing: Array[int] = []
	var fast_ramp := 0
	for fl_flags in LitShaderLibrary.all_variant_flags():
		if fl_flags & LitShaderLibrary.F_RAMP != 0 and fl_flags & LitShaderLibrary.F_SELF_EXCL == 0 and LitShaderLibrary._prune(fl_flags) == fl_flags:
			fast_ramp += 1
			if not listed.has(fl_flags):
				requested_missing.append(fl_flags)
	var names := PackedStringArray()
	for m in requested_missing.slice(0, 4):
		names.append(LitShaderLibrary.variant_name(m))
	say("SUITE INFO work list: %d items; fast-tier ramp variants the runtime can request: %d; missing from the work list: %d (e.g. %s)" % [
			work.size(), fast_ramp, requested_missing.size(), ", ".join(names)])
	check(c, "every fast-tier ramp variant the runtime can request is in the precompile work list", 0,
			requested_missing.size())
	# Regenerating the config cannot help: a list naming both twins folds the same way.
	var twin := LitShaderLibrary.F_SELF_EXCL
	var folded: Array = LitShaderPrecompiler.dedupe([LitShaderLibrary.F_RAMP, twin])
	check(c, "a config listing both lit_receiver_fast_ramp and its twin keeps both", 2, folded.size())
	# The twins really are the same shader apart from the define line.
	var src_ramp := LitShaderLibrary.source_for(LitShaderLibrary.F_RAMP).split("\n")
	var src_twin := LitShaderLibrary.source_for(twin).split("\n")
	var differing := 0
	for i in mini(src_ramp.size(), src_twin.size()):
		if src_ramp[i] != src_twin[i] and not src_ramp[i].begins_with("// lit_flags"):
			differing += 1
	check_true(c, "(reference) the twins' sources differ only in their #define line", differing == 1)

	# (2) The real silent precompile pass.
	var pre := LitShaderPrecompiler.new()
	add_child(pre)
	pre.start(true)
	if pre.is_processing():
		await pre.finished
	pre.queue_free()
	var warmed := LitShaderLibrary._warmed.size()
	await frames(4)
	var before := _catcher.matching("compiled mid-game").size()
	var shader_before: Shader = (fl.material as ShaderMaterial).shader
	say("SUITE INFO after the silent pass: %d variants marked warmed; floor on %s" % [
			warmed, LitShaderLibrary.variant_name(LitShaderLibrary.flags_of(shader_before))])

	# (3) Turn on a shadow ramp: the floor moves to the ramp variant.
	c = "ramp_after_precompile"
	var frame_ms: Array[float] = []
	var t_prev := Time.get_ticks_usec()
	post.shadow_ramp = 100.0
	for k in 8:
		await RenderingServer.frame_post_draw
		var t := Time.get_ticks_usec()
		frame_ms.append(float(t - t_prev) / 1000.0)
		t_prev = t
	var shader_after: Shader = (fl.material as ShaderMaterial).shader
	var after_flags := LitShaderLibrary.flags_of(shader_after)
	var warnings := _catcher.matching("compiled mid-game")
	check_true(c, "(reference) the floor moved to a ramp variant", after_flags & LitShaderLibrary.F_RAMP != 0)
	check(c, "after a precompile, turning on a shadow ramp logs no 'compiled mid-game' warning", 0,
			warnings.size() - before)
	check_true(c, "the floor's ramp variant was among the warmed variants", LitShaderLibrary._warmed.has(after_flags))
	say("SUITE INFO floor now on %s (warmed: %s); new warnings: %d; frame times after the switch (ms): %s" % [
			LitShaderLibrary.variant_name(after_flags), str(LitShaderLibrary._warmed.has(after_flags)), warnings.size() - before,
			", ".join(frame_ms.map(func(v): return "%.1f" % v))])
	if warnings.size() > before:
		say("SUITE INFO warning text: %s" % warnings[warnings.size() - 1].strip_edges())

	# (4) Main-thread cost of a miss vs a hit, on another missing twin (fresh Shader).
	var probe_miss := -1
	for m in requested_missing:
		if not LitShaderLibrary._receivers.has(m):
			probe_miss = m
			break
	var miss_ms := -1.0
	if probe_miss >= 0:
		var t0 := Time.get_ticks_usec()
		var sh := LitShaderLibrary.get_receiver(probe_miss)
		RenderingServer.force_sync()
		miss_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		sh = null
	var t1 := Time.get_ticks_usec()
	LitShaderLibrary.get_receiver(twin)
	var hit_ms := float(Time.get_ticks_usec() - t1) / 1000.0
	say("SUITE INFO get_receiver main-thread time: miss (%s, new Shader) %.2f ms vs warmed twin %.3f ms" % [
			LitShaderLibrary.variant_name(probe_miss) if probe_miss >= 0 else "-", miss_ms, hit_ms])

	repro("4 precompile ramp twin", requested_missing.size() > 0 and warnings.size() > before,
			"%d of %d fast-tier ramp variants missing from the work list; turning on a ramp after the silent pass logged %d 'compiled mid-game' warning(s) for %s; a miss costs %.2f ms on the main thread (hit %.3f ms)" % [
			requested_missing.size(), fast_ramp, warnings.size() - before, LitShaderLibrary.variant_name(after_flags), miss_ms, hit_ms])
