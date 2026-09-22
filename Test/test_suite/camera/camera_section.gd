extends LitSuiteSection

## Camera transforms: Lit shades, shadows, aims and masks its lights in world space, so a
## world point must read the same under any Camera2D transform (zoom, roll, pan): point,
## spot and directional shading, normal maps, shadows, a cookie footprint, a receiver's
## shadow_ignore_mask exemption and a y-sorted depth exemption. Probes go
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
const CK := Vector2(700, 560)        # cookie light: left half opaque, 128 px footprint
const CK_IN := Vector2(660, 560)     # inside the opaque half
const CK_OUT := Vector2(740, 560)    # inside the transparent half
const RXL := Vector2(520, 680)       # mask-2 light on the rx receiver (receiver_mask 2)
const RX_P := Vector2(650, 680)      # on the rx receiver, behind a mask-2 caster
const YL := Vector2(600, 600)        # mask-4 light on the y-sorted receiver (receiver_mask 4)
const YS_P := Vector2(760, 600)      # on it, behind a caster above its depth line

const POINTS := {
	"point light 120 px away": LP_LIT,
	"umbra behind the box": S,
	"beside the shadow band": S_BESIDE,
	"left-facing tile": TILE_L,
	"right-facing tile": TILE_R,
	"spot on-axis": SP_ON,
	"spot off-axis": SP_OFF,
	"cookie opaque half": CK_IN,
	"cookie transparent half": CK_OUT,
	"rx receiver behind an ignored caster": RX_P,
	"y-sorted receiver behind a higher caster": YS_P,
}

var _cam: Camera2D
var _box: LightOccluder2D
var _rx: LitSprite2D
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
	# Cookie: a 64 px left-half-opaque texture at scale 2, falloff 0.
	var ck := point_light(CK, 120.0, 0.4, Color.WHITE, 300.0)
	ck.falloff = 0.0
	ck.texture = tex_fn(64, 64, func(x, _y): return Color(1, 1, 1, 1) if x < 32 else Color(0, 0, 0, 0))
	ck.texture_scale = 2.0
	# Rx: a receiver_mask-2 box lit by a mask-2 shadow light through a mask-2 caster it ignores.
	_rx = box_receiver(RX_P, Vector2(100, 50))
	_rx.specular_strength = 0.0
	_rx.receiver_mask = 2
	_rx.shadow_ignore_mask = 2
	var rxl := point_light(RXL, 200.0, 0.8, Color.WHITE, 100.0)
	rxl.falloff = 0.0
	rxl.light_mask = 2
	rxl.shadow_enabled = true
	rxl.shadow_mask = 3
	occluder(Vector2(580, 680), Vector2(20, 50), get_node("Props"), 2)
	# Y-sort: a receiver_mask-4 box owning a strip (depth line at the strip's bottom, 668)
	# lit by a mask-4 shadow light through a caster whose bottom (630) sits above the line.
	var ys := box_receiver(Vector2(750, 620), Vector2(100, 100))
	ys.specular_strength = 0.0
	ys.receiver_mask = 4
	occluder(Vector2(0, 45), Vector2(90, 6), ys)
	var yl := point_light(YL, 220.0, 0.8, Color.WHITE, 100.0)
	yl.falloff = 0.0
	yl.light_mask = 4
	yl.shadow_enabled = true
	occluder(Vector2(680, 600), Vector2(20, 60), get_node("Props"))
	set_setting("lit/render/y_sorting", true)
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
	check_gt(case_name, "no camera: the cookie's opaque half is lit, its transparent half is not",
			_base["cookie opaque half"], _base["cookie transparent half"], 0.25)
	check_gt(case_name, "no camera: the rx receiver ignores the mask-2 caster",
			_base["rx receiver behind an ignored caster"], AMBIENT, 0.25)
	_rx.shadow_ignore_mask = 0
	await frames(3)
	check_lt(case_name, "no camera: with the mask cleared the caster shadows it", lum(await capture(), RX_P),
			_base["rx receiver behind an ignored caster"] * 0.5)
	_rx.shadow_ignore_mask = 2
	await frames(3)
	check_gt(case_name, "no camera: y-sort exempts the caster above the receiver's depth line",
			_base["y-sorted receiver behind a higher caster"], AMBIENT, 0.25)
	set_setting("lit/render/y_sorting", false)
	await frames(3)
	check_lt(case_name, "no camera: y-sort off, the same caster shadows it", lum(await capture(), YS_P),
			_base["y-sorted receiver behind a higher caster"] * 0.5)
	set_setting("lit/render/y_sorting", true)
	await frames(3)

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
