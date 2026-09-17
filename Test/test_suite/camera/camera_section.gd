extends LitSuiteSection

## Camera transforms: Lit shades, shadows and aims its lights in world space, so a world
## point must read the same under any Camera2D transform (zoom, roll, pan). Probes go
## through to_px(), which applies the live canvas transform, so the same world points are
## sampled on every frame; each transform's readings are compared with the camera-less
## baseline (the lights and shadows sections pin the baseline values themselves).

const AMBIENT := 0.2
const TOL := 0.03

# Layout: inside x 200..800, y 320..700 so every probe stays on screen and clear of the
# HUD panel (screen x >= 1400) under zoom 2 centred on (600, 500), and within 540 px of
# that centre so the rolled view still shows it.
const CAM_CENTER := Vector2(600, 500)
const LP := Vector2(300, 450)        # point light
const LP_LIT := Vector2(300, 330)    # 120 px above it
const BOX := Vector2(400, 450)       # occluder 40 x 100
const S := Vector2(500, 450)         # umbra probe 100 px behind the box
const S_BESIDE := Vector2(500, 330)  # same distance band, above the shadow
const TILE_L := Vector2(700, 380)    # left-facing normal tile under the sun
const TILE_R := Vector2(760, 380)    # right-facing normal tile
const SP := Vector2(300, 620)        # spot light aimed +x, 20 deg cone, hard edge
const SP_ON := Vector2(450, 620)
const SP_OFF := Vector2(450, 700)    # 28 deg off axis: outside the cone

const POINTS := {
	"point light 120 px away": LP_LIT,
	"umbra behind the box": S,
	"beside the shadow band": S_BESIDE,
	"left-facing tile": TILE_L,
	"right-facing tile": TILE_R,
	"spot on-axis": SP_ON,
	"spot off-axis": SP_OFF,
}

var _cam: Camera2D
var _box: LightOccluder2D
var _base := {}


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	floor_receiver(Rect2(20, 90, 1360, 950))
	label("camera transforms: the same world points are probed with no camera, under zoom 2, zoom 0.5, a 45 deg roll and a pan",
			Vector2(24, 74))
	var l := point_light(LP, 400.0, 1.0, Color.WHITE, 100.0)
	l.shadow_enabled = true
	l.shadow_hardness = 1.0
	# Under its own holder: a LitSprite2D owns sibling occluders (self-exclusion), and the
	# floor must receive this one's shadow.
	_box = occluder(BOX, Vector2(40, 100), group("Props"))
	directional_light(0.0, 0.4, Color.WHITE, 16.0)
	var left := box_receiver(TILE_L, Vector2(40, 40), Color.WHITE, null, tex_normal(8, -1.0))
	var right := box_receiver(TILE_R, Vector2(40, 40), Color.WHITE, null, tex_normal(8, 1.0))
	left.specular_strength = 0.0
	right.specular_strength = 0.0
	var sp := spot_light(SP, 0.0, 300.0, 0.6, Color.WHITE, 120.0)
	sp.spot_angle = 20.0
	sp.spot_softness = 0.0
	_cam = Camera2D.new()
	_cam.ignore_rotation = false
	_cam.enabled = false
	add_child(_cam)
	await frames(3)
	var img := await capture()
	var case_name := "camera_baseline"
	for k in POINTS:
		_base[k] = lum(img, POINTS[k])
	# The sun lights the whole floor, so the baseline sanity checks are relative: the
	# absolute values are pinned by the lights and shadows sections.
	check_gt(case_name, "no camera: the point light lights 120 px away", _base["point light 120 px away"], AMBIENT, 0.2)
	_box.visible = false
	await frames(2)
	var no_box := lum(await capture(), S)
	_box.visible = true
	await frames(2)
	check_gt(case_name, "no camera: hiding the box lights the umbra probe by the point light's share",
			no_box, _base["umbra behind the box"], 0.15)
	check_true(case_name, "no camera: the sun tells the left- and right-facing tiles apart",
			absf(_base["left-facing tile"] - _base["right-facing tile"]) > 0.1)
	check_gt(case_name, "no camera: the spot lights its axis", _base["spot on-axis"], AMBIENT, 0.2)
	check_lt(case_name, "no camera: 28 deg off the spot's axis is darker than on it", _base["spot off-axis"],
			_base["spot on-axis"], 0.2)

	_cam.enabled = true
	_cam.make_current()
	_cam.position = CAM_CENTER
	_cam.zoom = Vector2(2, 2)
	await _compare("camera_zoom", "zoom 2")
	_cam.zoom = Vector2(0.5, 0.5)
	await _compare("camera_zoom", "zoom 0.5")
	_cam.zoom = Vector2.ONE
	_cam.rotation = PI / 4.0
	await _compare("camera_rotation", "45 deg roll")
	_cam.rotation = 0.0
	_cam.position = Vector2(900, 700)
	await _compare("camera_pan", "pan to (900, 700)")
	_cam.enabled = false
	await frames(2)
	get_viewport().canvas_transform = Transform2D()
	await _compare("camera_off", "camera disabled again")


## Reads every probe under the current camera and expects the baseline value.
func _compare(case_name: String, tag: String) -> void:
	await frames(3)
	var img := await capture()
	for k in POINTS:
		check_approx(case_name, "%s: %s reads as without a camera" % [tag, k], _base[k], lum(img, POINTS[k]), TOL)


func _exit_tree() -> void:
	# Never leave a camera transform behind for the next section.
	if _cam != null and is_instance_valid(_cam):
		_cam.enabled = false
	get_viewport().canvas_transform = Transform2D()
	super()
