extends SceneTree

## Headless gate: bare-receiver driving through LitReceiverHelper - rect push, tier
## swap, self_shadow opt-out, shared-material skip, freed-occluder heal, and the
## LitSprite2D self-driving path. Count-guarded: EXPECTED checks must execute.
## Run: godot --headless --path . --script res://Test/gate_receiver_driving.gd

const RegistryScript := preload("res://addons/lit/runtime/lit_light_registry.gd")
const EXPECTED := 10

var _registry
var _frame := 0
var _checks := 0
var _fails := 0

var _bare: Sprite2D
var _bare_occ: LightOccluder2D
var _shared_a: Sprite2D
var _shared_b: Sprite2D
var _lit_sprite: LitSprite2D
var _rect_first := PackedVector4Array()


func _initialize() -> void:
	var mgr := root.get_node_or_null("LitManager")
	if mgr != null:
		mgr.set_process(false)
	_registry = RegistryScript.new()

	_bare = _make_bare("Bare")
	_bare_occ = _make_occ(_bare)

	_shared_a = _make_bare("SharedA")
	_shared_b = _make_bare("SharedB")
	_shared_b.material = _shared_a.material
	_make_occ(_shared_a)

	_lit_sprite = LitSprite2D.new()
	_lit_sprite.name = "LitSelf"
	root.add_child.call_deferred(_lit_sprite)
	_make_occ(_lit_sprite)

	process_frame.connect(_tick)


func _make_bare(nm: String) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = nm
	var mat := ShaderMaterial.new()
	mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
	s.material = mat
	root.add_child.call_deferred(s)
	return s


func _make_occ(parent: Node) -> LightOccluder2D:
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)])
	occ.occluder = poly
	parent.add_child.call_deferred(occ)
	return occ


func _mat(s: Sprite2D) -> ShaderMaterial:
	return s.material as ShaderMaterial


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: " + label)


func _tick() -> void:
	_frame += 1
	# The autoload registers after _initialize; park it here so only this probe's
	# registry drives the tree.
	var mgr := root.get_node_or_null("LitManager")
	if mgr != null:
		mgr.set_process(false)
	_registry.refresh(self, root, root, null)
	match _frame:
		3:
			_check(int(_mat(_bare).get_shader_parameter("self_rect_count")) == 1,
					"bare: one self rect pushed")
			_check(LitShaderLibrary.flags_of(_mat(_bare).shader) == LitShaderLibrary.F_SELF_EXCL,
					"bare: tiered to full (self exclusion)")
			_rect_first = _mat(_bare).get_shader_parameter("self_rects")
			_bare_occ.position.x += 100.0
		5:
			_check(_mat(_bare).get_shader_parameter("self_rects") != _rect_first,
					"bare: rect follows the occluder")
			_mat(_bare).set_shader_parameter("self_shadow", true)
		7:
			_check(LitShaderLibrary.flags_of(_mat(_bare).shader) == 0,
					"bare: self_shadow=true drops to fast tier")
			_check(_registry._receiver_driver._bare_shared_warned,
					"shared material warned")
			var shared_count: Variant = _mat(_shared_a).get_shader_parameter("self_rect_count")
			_check(shared_count == null or int(shared_count) == 0,
					"shared material not driven")
			_check(int(_mat(_lit_sprite).get_shader_parameter("self_rect_count")) == 1,
					"LitSprite2D drives its own rect")
			_check(LitShaderLibrary.flags_of(_mat(_lit_sprite).shader) == LitShaderLibrary.F_SELF_EXCL,
					"LitSprite2D tiered to full")
			_mat(_bare).set_shader_parameter("self_shadow", false)
			_bare_occ.free()
		10:
			_check(int(_mat(_bare).get_shader_parameter("self_rect_count")) == 0,
					"bare: freed occluder heals rects to zero")
			_check(_checks == EXPECTED - 1, "check count guard")
			print("PROBE RESULT: %d/%d checks, %d fails" % [_checks - _fails, _checks, _fails])
			quit(1 if _fails > 0 else 0)
