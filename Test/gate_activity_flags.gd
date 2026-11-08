extends SceneTree

## Headless gate: activity_flags transitions under scripted state changes - the
## behavioral replacement for the deleted _activity_mirror asserts. Count-guarded.
## Run: godot --headless --path . --script res://Test/gate_activity_flags.gd

const RegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")
const EXPECTED := 11

var _registry
var _frame := 0
var _checks := 0
var _fails := 0

var _light: LitPointLight2D
var _light2: LitPointLight2D
var _line: LitLineLight2D


func _initialize() -> void:
	_registry = RegistryScript.new()

	_light = LitPointLight2D.new()
	_light.shadow_enabled = true
	_light.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.CONE_TRACED
	root.add_child.call_deferred(_light)
	_add_occ(1)

	var bare := Sprite2D.new()
	var mat := ShaderMaterial.new()
	mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
	bare.material = mat
	root.add_child.call_deferred(bare)

	process_frame.connect(_tick)


func _add_occ(mask: int) -> void:
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(20, 20), Vector2(60, 20), Vector2(60, 60), Vector2(20, 60)])
	occ.occluder = poly
	occ.occluder_light_mask = mask
	root.add_child.call_deferred(occ)


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s (activity_flags=%d)" % [label, RegistryScript.activity_flags])


func _tick() -> void:
	_frame += 1
	var mgr := root.get_node_or_null("LitManager")
	if mgr != null:
		mgr.set_process(false)
	_registry.refresh(self, root, root, null)
	var fl: int = RegistryScript.activity_flags
	match _frame:
		3:
			_check(fl & LitShaderLibrary.F_CONE != 0 and fl & LitShaderLibrary.F_STOCH == 0,
					"cone light publishes F_CONE")
			_light.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.STOCHASTIC
		6:
			_check(fl & LitShaderLibrary.F_STOCH != 0 and fl & LitShaderLibrary.F_CONE == 0,
					"algorithm switch publishes F_STOCH")
			_light.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.RAYMARCHED
		9:
			_check(fl == 0, "raymarched with default masks publishes 0")
			_line = LitLineLight2D.new()
			root.add_child.call_deferred(_line)
		12:
			_check(fl & (LitShaderLibrary.F_LINE | LitShaderLibrary.F_STOCH) == LitShaderLibrary.F_LINE | LitShaderLibrary.F_STOCH
					and fl & LitShaderLibrary.F_CONE == 0, "a shadowless line publishes stoch+line")
			_light.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.CONE_TRACED
		15:
			_check(fl & LitShaderLibrary.F_LINE != 0 and fl & LitShaderLibrary.F_CONE == 0,
					"a cone light beside a line folds into stoch+line")
			_line.enabled = false
		18:
			_check(fl & LitShaderLibrary.F_CONE != 0 and fl & (LitShaderLibrary.F_LINE | LitShaderLibrary.F_STOCH) == 0,
					"a disabled line drops the line axis")
			_line.queue_free()
			_light.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.RAYMARCHED
			_add_occ(2)
		24:
			_check(fl & LitShaderLibrary.F_GX != 0,
					"occluder excluded from every light publishes F_GX")
			_check(fl & LitShaderLibrary.F_MASKS == 0, "no per-light masks yet")
			_light2 = LitPointLight2D.new()
			_light2.shadow_enabled = true
			_light2.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.RAYMARCHED
			_light2.shadow_mask = 3
			root.add_child.call_deferred(_light2)
		30:
			_check(fl & LitShaderLibrary.F_MASKS != 0,
					"split shadow masks publish F_MASKS")
			_check(fl & LitShaderLibrary.F_GX == 0, "gx tier folds away under masks")
			_check(_checks == EXPECTED - 1, "check count guard")
			print("PROBE RESULT: %d/%d checks, %d fails" % [_checks - _fails, _checks, _fails])
			quit(1 if _fails > 0 else 0)
