extends SceneTree

## Headless gate: receiver exports that the project settings make inert are reported by
## LitReceiverHelper.inactive_reason and rendered read-only by every receiver class's
## _validate_property, and only those. Settings are changed in memory (never saved)
## and restored. Count-guarded: EXPECTED checks must execute.
## Run: godot --headless --path . --script res://Test/gate_receiver_exports.gd

const EXPECTED := 41

const RECEIVERS := [
	"res://addons/lit/nodes/lit_sprite_2d.gd",
	"res://addons/lit/nodes/lit_animated_sprite_2d.gd",
	"res://addons/lit/nodes/lit_tile_map_layer.gd",
]
const PHONG_ONLY := ["specular_strength", "specular_k"]
const PBR_ONLY := ["metallic_value", "roughness_value"]
const NEVER_GATED := ["shadow_min_step", "shadow_ramp", "directional_horizontal_scale",
	"emissive_strength"]

const S_MODEL := "lit/render/lighting_model"
const S_SCALING := "lit/quality/shadow_step_scaling"
const S_MAX := "lit/quality/shadow_steps_max"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	var mgr := root.get_node_or_null("LitManager")
	if mgr != null:
		mgr.set_process(false)
	var saved := {}
	for key in [S_MODEL, S_SCALING, S_MAX]:
		saved[key] = ProjectSettings.get_setting(key, null)

	print("[gate 1] reasons under Blinn-Phong, step scaling off")
	ProjectSettings.set_setting(S_MODEL, 0)
	ProjectSettings.set_setting(S_SCALING, false)
	for p in PHONG_ONLY:
		_check(_reason(p) == "", "%s live under Phong" % p)
	for p in PBR_ONLY:
		_check(_reason(p).contains("Lighting Model"), "%s inert under Phong, names the setting" % p)
	_check(_reason("shadow_steps") == "", "shadow_steps live with scaling off")

	print("[gate 2] reasons under PBR")
	ProjectSettings.set_setting(S_MODEL, 1)
	for p in PHONG_ONLY:
		_check(_reason(p).contains("Lighting Model"), "%s inert under PBR, names the setting" % p)
	for p in PBR_ONLY:
		_check(_reason(p) == "", "%s live under PBR" % p)
	_check(_reason("shadow_steps") == "", "shadow_steps still live under PBR")

	print("[gate 3] shadow_steps under step scaling")
	ProjectSettings.set_setting(S_SCALING, true)
	ProjectSettings.set_setting(S_MAX, 48)
	var r := _reason("shadow_steps")
	_check(r != "", "shadow_steps inert with scaling on")
	_check(r.contains("Shadow Step Scaling"), "reason names the setting")
	_check(r.contains("48"), "reason reports the current Shadow Steps Max")

	print("[gate 4] read-only usage per receiver class (PBR, scaling on)")
	for path in RECEIVERS:
		var script := load(path) as GDScript
		var obj: Object = script.new()
		var usage := _usage_map(obj)
		var cls := String(path.get_file())
		for p in PHONG_ONLY + ["shadow_steps"]:
			_check(usage.has(p) and (usage[p] & PROPERTY_USAGE_READ_ONLY) != 0,
					"%s: %s read-only" % [cls, p])
		for p in PBR_ONLY + NEVER_GATED:
			_check(usage.has(p) and (usage[p] & PROPERTY_USAGE_READ_ONLY) == 0,
					"%s: %s editable" % [cls, p])
		if obj is Node:
			(obj as Node).free()

	for key in saved:
		ProjectSettings.set_setting(key, saved[key])

	_check(_checks == EXPECTED - 1, "check count guard")
	print("PROBE RESULT: %d/%d checks, %d fails" % [_checks - _fails, _checks, _fails])
	quit(1 if _fails > 0 else 0)


func _reason(param: String) -> String:
	return LitReceiverHelper.inactive_reason(param)


func _usage_map(obj: Object) -> Dictionary:
	var out := {}
	for p in obj.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE != 0:
			out[String(p.name)] = int(p.usage)
	return out


func _check(ok: bool, label: String) -> bool:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: " + label)
	return ok
