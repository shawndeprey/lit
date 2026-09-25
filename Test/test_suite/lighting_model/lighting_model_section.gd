extends LitSuiteSection

## Lighting model: the lit/render/lighting_model project setting switched live between
## Blinn-Phong and PBR, the PBR inputs (metallic / roughness scalars and maps, AO map)
## acting only under PBR and the Blinn-Phong specular pair only under Phong, and the
## inspector gating that reports the inert exports (LitReceiverHelper.inactive_reason
## and the read-only property usage on every receiver class).

const AMBIENT := 0.1
const S_MODEL := "lit/render/lighting_model"
const S_SCALING := "lit/quality/shadow_step_scaling"
const S_MAX := "lit/quality/shadow_steps_max"
const RECEIVERS := [
	"res://addons/lit/nodes/lit_sprite_2d.gd",
	"res://addons/lit/nodes/lit_animated_sprite_2d.gd",
	"res://addons/lit/nodes/lit_tile_map_layer.gd",
]

var _a: LitSprite2D     # default dielectric
var _b: LitSprite2D     # metallic 1, roughness 0.2
var _c: LitSprite2D     # metallic 1, roughness 1
var _d: LitSprite2D     # specular_strength 2 (spec map)
var _e: LitSprite2D     # specular_strength 0 (spec map)
var _f: LitSprite2D     # ao_map black (long bar, light at its left end)
var _f_ref: LitSprite2D # same bar without the AO map
var _g: LitSprite2D     # metallic 1 with a black metallic map (dielectric again)
var _h: LitSprite2D     # metallic 1, roughness 1 scalar x black roughness map (shiny)


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	_build()
	await frames(2)
	await _phong()
	await _pbr()
	_gating()


func _shiny(pos: Vector2, with_spec_map := false) -> LitSprite2D:
	var s := box_receiver(pos, Vector2(60, 60), Color.WHITE, null, null, white() if with_spec_map else null)
	var l := point_light(pos, 60.0, 0.5, Color.WHITE, 100.0)
	l.falloff = 0.0
	return s


func _build() -> void:
	label("A default | B metal rough 0.2 | C metal rough 1 | D spec 2 | E spec 0 | G metal x black map | H metal x black rough map",
			Vector2(24, 74))
	label("F: AO map black (light at the left end) over the same bar without AO", Vector2(24, 300))
	var y := 180.0
	_a = _shiny(Vector2(100, y))
	_b = _shiny(Vector2(260, y))
	_b.metallic_value = 1.0
	_b.roughness_value = 0.2
	_c = _shiny(Vector2(420, y))
	_c.metallic_value = 1.0
	_c.roughness_value = 1.0
	_d = _shiny(Vector2(580, y), true)
	_d.specular_strength = 2.0
	_e = _shiny(Vector2(740, y), true)
	_e.specular_strength = 0.0
	_g = _shiny(Vector2(900, y))
	_g.metallic_value = 1.0
	_g.make_material_unique().set_shader_parameter("metallic_map", tex_solid(4, Color.BLACK))
	_h = _shiny(Vector2(1060, y))
	_h.metallic_value = 1.0
	_h.roughness_value = 1.0
	_h.make_material_unique().set_shader_parameter("roughness_map", tex_solid(4, Color.BLACK))
	_f = box_receiver(Vector2(300, 360), Vector2(400, 40))
	_f.specular_strength = 0.0
	_f.make_material_unique().set_shader_parameter("ao_map", tex_solid(4, Color.BLACK))
	_f_ref = box_receiver(Vector2(300, 420), Vector2(400, 40))
	_f_ref.specular_strength = 0.0
	for bar in [_f, _f_ref]:
		var l := point_light(bar.position + Vector2(-190, 0), 80.0, 0.5, Color.WHITE, 100.0)
		l.falloff = 0.0


func _phong() -> void:
	var case_name := "phong_model"
	set_setting(S_MODEL, 0)
	await frames(2)
	var img := await capture()
	var a := lum(img, _a.position)
	check_gt(case_name, "Blinn-Phong: the default receiver is lit", a, AMBIENT, 0.3)
	check_approx(case_name, "Blinn-Phong ignores metallic/roughness (B = A)", a, lum(img, _b.position), 0.03)
	check_approx(case_name, "Blinn-Phong ignores metallic/roughness (C = A)", a, lum(img, _c.position), 0.03)
	check_gt(case_name, "Blinn-Phong: specular_strength 2 brighter than 0", lum(img, _d.position), lum(img, _e.position), 0.15)
	var far := Vector2(480, 360)   # 180 px from the bar's light (range 80): ambient only
	check_approx(case_name, "Blinn-Phong ignores the AO map (ambient intact on the far end)", AMBIENT,
			lum(img, far), 0.03)
	check_approx(case_name, "reference bar's far end is ambient too", AMBIENT, lum(img, far + Vector2(0, 60)), 0.03)


func _pbr() -> void:
	var case_name := "pbr_model"
	set_setting(S_MODEL, 1)
	await frames(2)
	var img := await capture()
	check(case_name, "manager published the PBR model", 1, get_node("/root/LitManager").lighting_model)
	var a := lum(img, _a.position)
	var b := lum(img, _b.position)
	var c := lum(img, _c.position)
	check_gt(case_name, "PBR: the default dielectric receiver is lit", a, AMBIENT, 0.2)
	check_gt(case_name, "PBR: polished metal (rough 0.2) far brighter than matte metal (rough 1)", b, c, 0.15)
	check_gt(case_name, "PBR: polished metal brighter than the default dielectric", b, a, 0.1)
	check_approx(case_name, "PBR ignores specular_strength (D = E)", lum(img, _d.position), lum(img, _e.position), 0.03)
	check_approx(case_name, "PBR: metallic 1 x black metallic map = dielectric (G = A)", a, lum(img, _g.position), 0.04)
	check_gt(case_name, "PBR: black roughness map makes the metal shiny (H > C)", lum(img, _h.position), c, 0.15)
	var far := Vector2(480, 360)
	check_approx(case_name, "PBR: black AO map kills the ambient term on the far end", 0.0, lum(img, far), 0.03)
	check_approx(case_name, "PBR: the bar without AO keeps its ambient", AMBIENT, lum(img, far + Vector2(0, 60)), 0.03)
	set_setting(S_MODEL, 0)
	await frames(2)
	img = await capture()
	check_approx(case_name, "switched back to Blinn-Phong: metallic ignored again (B = A)",
			lum(img, _a.position), lum(img, _b.position), 0.03)


func _gating() -> void:
	var case_name := "export_gating"
	set_setting(S_MODEL, 0)
	set_setting(S_SCALING, false)
	for p in ["specular_strength", "specular_k"]:
		check(case_name, "%s live under Phong" % p, "", LitReceiverHelper.inactive_reason(p))
	for p in ["metallic_value", "roughness_value"]:
		check_true(case_name, "%s inert under Phong, reason names the setting" % p,
				LitReceiverHelper.inactive_reason(p).contains("Lighting Model"))
	check(case_name, "shadow_steps live with step scaling off", "", LitReceiverHelper.inactive_reason("shadow_steps"))
	set_setting(S_MODEL, 1)
	for p in ["specular_strength", "specular_k"]:
		check_true(case_name, "%s inert under PBR" % p, LitReceiverHelper.inactive_reason(p).contains("Lighting Model"))
	for p in ["metallic_value", "roughness_value"]:
		check(case_name, "%s live under PBR" % p, "", LitReceiverHelper.inactive_reason(p))
	set_setting(S_SCALING, true)
	set_setting(S_MAX, 48)
	var r := LitReceiverHelper.inactive_reason("shadow_steps")
	check_true(case_name, "shadow_steps inert with step scaling on, names the setting and the max (48)",
			r.contains("Shadow Step Scaling") and r.contains("48"))
	for path in RECEIVERS:
		var script := load(path) as GDScript
		var obj: Object = script.new()
		var usage := {}
		for p in obj.get_property_list():
			if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE != 0:
				usage[String(p.name)] = int(p.usage)
		var cls := String(path.get_file())
		var ro_ok := true
		for p in ["specular_strength", "specular_k", "shadow_steps"]:
			ro_ok = ro_ok and usage.has(p) and (usage[p] & PROPERTY_USAGE_READ_ONLY) != 0
		var rw_ok := true
		for p in ["metallic_value", "roughness_value", "shadow_min_step", "shadow_ramp",
				"directional_horizontal_scale", "emissive_strength"]:
			rw_ok = rw_ok and usage.has(p) and (usage[p] & PROPERTY_USAGE_READ_ONLY) == 0
		check_true(case_name, "%s: inert exports read-only (PBR, scaling on)" % cls, ro_ok)
		check_true(case_name, "%s: live exports editable" % cls, rw_ok)
		if obj is Node:
			(obj as Node).free()
	# Light dials: only the selected algorithm's inputs stay in the inspector. The probe
	# nodes live in the tree and leave through queue_free: constructing Lit nodes and
	# freeing them within one frame outside the tree hung the renderer at teardown.
	var pl := LitPointLight2D.new()
	pl.enabled = false
	add_child(pl)
	pl.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.RAYMARCHED
	var u := _editor_usage(pl)
	check_true(case_name, "point light on Raymarched: source_radius, shadow_samples and shadow_jitter hidden",
			not u["source_radius"] and not u["shadow_samples"] and not u["shadow_jitter"])
	pl.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.CONE_TRACED
	u = _editor_usage(pl)
	check_true(case_name, "point light on Cone Traced: source_radius shown, samples hidden",
			u["source_radius"] and not u["shadow_samples"])
	pl.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.STOCHASTIC
	u = _editor_usage(pl)
	check_true(case_name, "point light on Stochastic: source_radius, samples and jitter shown",
			u["source_radius"] and u["shadow_samples"] and u["shadow_jitter"])
	var dl := LitDirectionalLight2D.new()
	dl.enabled = false
	add_child(dl)
	dl.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.RAYMARCHED
	u = _editor_usage(dl)
	check_true(case_name, "directional on Raymarched: source_angle hidden", not u["source_angle"])
	dl.shadow_algorithm = LitShaderLibrary.ShadowAlgorithm.CONE_TRACED
	u = _editor_usage(dl)
	check_true(case_name, "directional on Cone Traced: source_angle shown", u["source_angle"])
	# Post effects hide the Node2D surface a fullscreen pass never uses.
	var host := LitPostProcess.new()
	host.visible = false
	add_child(host)
	var fx := LitPostBloom.new()
	host.add_child(fx)
	u = _editor_usage(fx)
	check_true(case_name, "post effect: position / modulate / material hidden from the inspector, visible kept",
			not u["position"] and not u["modulate"] and not u["material"] and u["visible"])
	pl.queue_free()
	dl.queue_free()
	host.queue_free()
	await frames(2)
	restore_settings()


## name -> whether the property shows in the inspector (PROPERTY_USAGE_EDITOR).
func _editor_usage(obj: Object) -> Dictionary:
	var out := {}
	for p in obj.get_property_list():
		out[String(p.name)] = (int(p.usage) & PROPERTY_USAGE_EDITOR) != 0
	return out
