extends LitSuiteSection

## Light ranges: range_z_min / range_z_max and range_layer_min / range_layer_max on
## LitPointLight2D, LitSpotLight2D and LitDirectionalLight2D, checked against the
## rendered frame. A receiver is lit by a ranged light only while its final z_index
## (z_as_relative offsets summed up its parents) and its CanvasLayer index fall inside
## the light's ranges; a 0..0 layer range (the default) lights every layer. Also: the
## receiver nodes deriving the pair on entering a canvas and on refresh_light_ranges(),
## LitTileMapLayer and LitAnimatedSprite2D, pooling keyed by depth, the packed rows,
## sample_luminance / get_luminance mirroring the test, light masks composing with it,
## and shadows cast regardless of the caster's own z.

const AMBIENT := 0.3
const TOL := 0.03
const LIT := 0.15
const BOX := Vector2(50, 50)

var _mgr: Node


func run() -> void:
	_mgr = get_node("/root/LitManager")
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	label("point: z range", Vector2(40, 74))
	label("spot: z range", Vector2(380, 74))
	label("directional: z range", Vector2(720, 74))
	label("point: layer range", Vector2(40, 354))
	label("spot: layer range", Vector2(380, 354))
	label("directional: layer range", Vector2(720, 354))
	label("z_as_relative, runtime refresh", Vector2(40, 634))
	label("tilemap, animated sprite, pooling", Vector2(380, 634))
	label("shadows, masks, luminance", Vector2(720, 634))
	label("packed rows", Vector2(1060, 74))
	await frames(2)

	await _z_range_point()
	await _z_range_spot()
	await _z_range_directional()
	await _layer_range_point()
	await _layer_range_spot()
	await _layer_range_directional()
	await _relative_and_refresh()
	await _tilemap_and_animated()
	await _pooling()
	await _shadows_and_masks()
	await _luminance()
	await _packed_rows()


## A box receiver at a z_index, spec off so probes read plain diffuse + ambient. z and
## z_as_relative are set before the node enters the tree, which is when a receiver
## reads them (a later write needs refresh_light_ranges(), checked in runtime_refresh).
func _box(pos: Vector2, z := 0, parent: Node = null, mask := 1, relative := true) -> LitSprite2D:
	var b := LitSprite2D.new()
	b.texture = canvas_tex(tex_sized(BOX))
	b.position = pos
	b.specular_strength = 0.0
	b.z_index = z
	b.z_as_relative = relative
	b.receiver_mask = mask
	(parent if parent != null else self).add_child(b)
	return b


func _layer(index: int) -> CanvasLayer:
	var cl := CanvasLayer.new()
	cl.layer = index
	cl.name = "Layer%d" % index
	add_child(cl)
	return cl


func _lit(case_name: String, desc: String, img: Image, at: Vector2) -> void:
	check_gt(case_name, desc, lum(img, at), AMBIENT, LIT)


func _dark(case_name: String, desc: String, img: Image, at: Vector2) -> void:
	check_approx(case_name, desc, AMBIENT, lum(img, at), TOL)


# --- z ranges ----------------------------------------------------------------------------------

func _z_range_point() -> void:
	var case_name := "z_range_point"
	var c := Vector2(180, 200)
	var a := _box(c + Vector2(-80, 0), 0)
	var b := _box(c + Vector2(80, 0), 2)
	var d := _box(c + Vector2(0, 80), -2)
	var l := point_light(c, 140.0, 0.8, Color.WHITE, 200.0)
	await frames(1)
	var img := await capture()
	_lit(case_name, "default ranges: z 0 lit", img, a.position)
	_lit(case_name, "default ranges: z 2 lit", img, b.position)
	_lit(case_name, "default ranges: z -2 lit", img, d.position)
	l.range_z_min = 0
	l.range_z_max = 0
	img = await capture()
	_lit(case_name, "z range 0..0: z 0 lit", img, a.position)
	_dark(case_name, "z range 0..0: z 2 ambient", img, b.position)
	_dark(case_name, "z range 0..0: z -2 ambient", img, d.position)
	l.range_z_min = 1
	l.range_z_max = 3
	img = await capture()
	_dark(case_name, "z range 1..3: z 0 ambient", img, a.position)
	_lit(case_name, "z range 1..3: z 2 lit", img, b.position)
	_dark(case_name, "z range 1..3: z -2 ambient", img, d.position)
	l.range_z_min = -3
	l.range_z_max = -1
	img = await capture()
	_dark(case_name, "z range -3..-1: z 0 ambient", img, a.position)
	_dark(case_name, "z range -3..-1: z 2 ambient", img, b.position)
	_lit(case_name, "z range -3..-1: z -2 lit", img, d.position)
	l.range_z_min = -4096
	l.range_z_max = 4096
	img = await capture()
	_lit(case_name, "back to the full range: z 2 lit again", img, b.position)
	_lit(case_name, "back to the full range: z -2 lit again", img, d.position)
	l.range_z_min = 2
	l.range_z_max = 2
	l.name = "PointZ"


func _z_range_spot() -> void:
	var case_name := "z_range_spot"
	var c := Vector2(480, 200)
	var s := spot_light(c, 0.0, 160.0, 0.8, Color.WHITE, 200.0)
	s.spot_angle = 80.0
	var a := _box(c + Vector2(90, -60), 0)
	var b := _box(c + Vector2(90, 0), 2)
	var d := _box(c + Vector2(90, 60), -2)
	await frames(1)
	var img := await capture()
	_lit(case_name, "default ranges: z 0 lit", img, a.position)
	_lit(case_name, "default ranges: z 2 lit", img, b.position)
	_lit(case_name, "default ranges: z -2 lit", img, d.position)
	s.range_z_min = 2
	s.range_z_max = 2
	img = await capture()
	_dark(case_name, "z range 2..2: z 0 ambient", img, a.position)
	_lit(case_name, "z range 2..2: z 2 lit", img, b.position)
	_dark(case_name, "z range 2..2: z -2 ambient", img, d.position)
	s.range_z_min = -2
	s.range_z_max = 0
	img = await capture()
	_lit(case_name, "z range -2..0: z 0 lit", img, a.position)
	_dark(case_name, "z range -2..0: z 2 ambient", img, b.position)
	_lit(case_name, "z range -2..0: z -2 lit", img, d.position)
	s.name = "SpotZ"


func _z_range_directional() -> void:
	var case_name := "z_range_directional"
	# Isolated on light_mask 2 so the sun reaches only this exhibit's boxes.
	var c := Vector2(860, 200)
	var a := _box(c + Vector2(-80, 0), 0, null, 2)
	var b := _box(c + Vector2(0, 0), 2, null, 2)
	var d := _box(c + Vector2(80, 0), -2, null, 2)
	_box(Vector2(860, 300), 0)
	await frames(1)
	var img := await capture()
	_dark(case_name, "before the sun: mask-2 box ambient", img, a.position)
	var sun := directional_light(0.0, 0.6, Color.WHITE, 64.0)
	sun.light_mask = 2
	img = await capture()
	_lit(case_name, "default ranges: z 0 lit", img, a.position)
	_lit(case_name, "default ranges: z 2 lit", img, b.position)
	_lit(case_name, "default ranges: z -2 lit", img, d.position)
	_dark(case_name, "mask-1 floor box elsewhere stays ambient", img, Vector2(860, 300))
	sun.range_z_min = 2
	sun.range_z_max = 4096
	img = await capture()
	_dark(case_name, "z range 2..4096: z 0 ambient", img, a.position)
	_lit(case_name, "z range 2..4096: z 2 lit", img, b.position)
	_dark(case_name, "z range 2..4096: z -2 ambient", img, d.position)
	sun.range_z_min = -4096
	sun.range_z_max = -1
	img = await capture()
	_dark(case_name, "z range -4096..-1: z 0 ambient", img, a.position)
	_dark(case_name, "z range -4096..-1: z 2 ambient", img, b.position)
	_lit(case_name, "z range -4096..-1: z -2 lit", img, d.position)
	sun.name = "SunZ"


# --- layer ranges -----------------------------------------------------------------------------

func _layer_range_point() -> void:
	var case_name := "layer_range_point"
	var c := Vector2(180, 480)
	var l1 := _layer(1)
	var l2 := _layer(2)
	var l5 := _layer(5)
	var base := _box(c + Vector2(-80, 0), 0)
	var on1 := _box(c + Vector2(0, -80), 0, l1)
	var on2 := _box(c + Vector2(80, 0), 0, l2)
	var on5 := _box(c + Vector2(0, 80), 0, l5)
	var l := point_light(c, 140.0, 0.8, Color.WHITE, 200.0)
	await frames(1)
	var img := await capture()
	_lit(case_name, "layer 0..0 (default): base canvas lit", img, base.position)
	_lit(case_name, "layer 0..0 (default): layer 1 lit", img, on1.position)
	_lit(case_name, "layer 0..0 (default): layer 2 lit", img, on2.position)
	_lit(case_name, "layer 0..0 (default): layer 5 lit (0..0 means every layer)", img, on5.position)
	l.range_layer_min = 1
	l.range_layer_max = 1
	img = await capture()
	_dark(case_name, "layer 1..1: base canvas ambient", img, base.position)
	_lit(case_name, "layer 1..1: layer 1 lit", img, on1.position)
	_dark(case_name, "layer 1..1: layer 2 ambient", img, on2.position)
	_dark(case_name, "layer 1..1: layer 5 ambient", img, on5.position)
	l.range_layer_min = 2
	l.range_layer_max = 5
	img = await capture()
	_dark(case_name, "layer 2..5: base canvas ambient", img, base.position)
	_dark(case_name, "layer 2..5: layer 1 ambient", img, on1.position)
	_lit(case_name, "layer 2..5: layer 2 lit", img, on2.position)
	_lit(case_name, "layer 2..5: layer 5 lit", img, on5.position)
	l.range_layer_min = -1
	l.range_layer_max = 0
	img = await capture()
	_lit(case_name, "layer -1..0: base canvas lit (the base-only recipe)", img, base.position)
	_dark(case_name, "layer -1..0: layer 1 ambient", img, on1.position)
	_dark(case_name, "layer -1..0: layer 5 ambient", img, on5.position)
	l.range_layer_min = 0
	l.range_layer_max = 0
	l.range_z_min = 0
	l.range_z_max = 0
	img = await capture()
	_lit(case_name, "z 0..0 with layer 0..0: layer 5 box at z 0 still lit (z range alone)", img, on5.position)
	on5.z_index = 1
	on5.refresh_light_ranges()
	img = await capture()
	_dark(case_name, "z 0..0 with layer 0..0: layer 5 box moved to z 1 ambient", img, on5.position)
	l.range_layer_min = 5
	l.range_layer_max = 5
	l.range_z_min = -4096
	l.range_z_max = 4096
	l.name = "PointLayer"


func _layer_range_spot() -> void:
	var case_name := "layer_range_spot"
	var c := Vector2(480, 480)
	var l3 := _layer(3)
	var s := spot_light(c, 0.0, 160.0, 0.8, Color.WHITE, 200.0)
	s.spot_angle = 80.0
	var base := _box(c + Vector2(90, -60), 0)
	var on3 := _box(c + Vector2(90, 0), 0, l3)
	var on5 := _box(c + Vector2(90, 60), 0, get_node("Layer5"))
	await frames(1)
	var img := await capture()
	_lit(case_name, "default: base lit", img, base.position)
	_lit(case_name, "default: layer 3 lit", img, on3.position)
	_lit(case_name, "default: layer 5 lit", img, on5.position)
	s.range_layer_min = 3
	s.range_layer_max = 3
	img = await capture()
	_dark(case_name, "layer 3..3: base ambient", img, base.position)
	_lit(case_name, "layer 3..3: layer 3 lit", img, on3.position)
	_dark(case_name, "layer 3..3: layer 5 ambient", img, on5.position)
	s.range_layer_min = -1
	s.range_layer_max = 0
	img = await capture()
	_lit(case_name, "layer -1..0: base lit", img, base.position)
	_dark(case_name, "layer -1..0: layer 3 ambient", img, on3.position)
	s.name = "SpotLayer"


func _layer_range_directional() -> void:
	var case_name := "layer_range_directional"
	var c := Vector2(860, 480)
	var base := _box(c + Vector2(-80, 0), 0, null, 2)
	var on2 := _box(c + Vector2(0, 0), 0, get_node("Layer2"), 2)
	var on5 := _box(c + Vector2(80, 0), 0, get_node("Layer5"), 2)
	var sun := directional_light(0.0, 0.6, Color.WHITE, 64.0)
	sun.light_mask = 2
	sun.range_layer_min = 2
	sun.range_layer_max = 2
	await frames(1)
	var img := await capture()
	_dark(case_name, "layer 2..2: base ambient", img, base.position)
	_lit(case_name, "layer 2..2: layer 2 lit", img, on2.position)
	_dark(case_name, "layer 2..2: layer 5 ambient", img, on5.position)
	sun.range_layer_min = 0
	sun.range_layer_max = 0
	img = await capture()
	_lit(case_name, "layer 0..0: base lit", img, base.position)
	_lit(case_name, "layer 0..0: layer 2 lit", img, on2.position)
	_lit(case_name, "layer 0..0: layer 5 lit", img, on5.position)
	sun.range_layer_min = 4
	sun.range_layer_max = 9
	img = await capture()
	_dark(case_name, "layer 4..9: base ambient", img, base.position)
	_dark(case_name, "layer 4..9: layer 2 ambient", img, on2.position)
	_lit(case_name, "layer 4..9: layer 5 lit", img, on5.position)
	sun.name = "SunLayer"


# --- z_as_relative and runtime changes ---------------------------------------------------------

func _relative_and_refresh() -> void:
	var case_name := "z_as_relative"
	var c := Vector2(180, 760)
	var parent := group("ZParent")
	parent.z_index = 3
	var rel := _box(c + Vector2(-80, 0), 1, parent)                 # final 4
	var abs_box := _box(c + Vector2(80, 0), 1, parent, 1, false)    # final 1
	var holder := Node.new()
	holder.name = "PlainNode"
	parent.add_child(holder)
	var broken := _box(c + Vector2(0, 80), 1, holder)        # a plain Node breaks the chain: final 1
	var l := point_light(c, 140.0, 0.8, Color.WHITE, 200.0)
	l.range_z_min = 4
	l.range_z_max = 4
	await frames(1)
	var img := await capture()
	_lit(case_name, "z 4..4: child z 1 under a z 3 parent (relative, final 4) lit", img, rel.position)
	_dark(case_name, "z 4..4: z_as_relative off (final 1) ambient", img, abs_box.position)
	_dark(case_name, "z 4..4: z 1 under a plain Node under the z 3 parent (final 1) ambient", img, broken.position)
	check(case_name, "canvas_z of the relative child", 4, LitReceiverHelper.canvas_z(rel))
	check(case_name, "canvas_z of the absolute child", 1, LitReceiverHelper.canvas_z(abs_box))
	check(case_name, "canvas_z below a plain Node", 1, LitReceiverHelper.canvas_z(broken))
	l.range_z_min = 1
	l.range_z_max = 1
	img = await capture()
	_dark(case_name, "z 1..1: relative child (final 4) ambient", img, rel.position)
	_lit(case_name, "z 1..1: absolute child lit", img, abs_box.position)
	_lit(case_name, "z 1..1: child below the plain Node lit", img, broken.position)

	case_name = "runtime_refresh"
	l.range_z_min = 4
	l.range_z_max = 4
	abs_box.z_index = 4
	img = await capture()
	_dark(case_name, "typed z_index write alone is not seen (still ambient)", img, abs_box.position)
	abs_box.refresh_light_ranges()
	img = await capture()
	_lit(case_name, "refresh_light_ranges(): the z 4 box is lit", img, abs_box.position)
	parent.z_index = 0
	img = await capture()
	_lit(case_name, "ancestor z_index 3 -> 0 alone is not seen (relative child still lit)", img, rel.position)
	LitLightRegistry.refresh_light_ranges(parent)
	img = await capture()
	_dark(case_name, "LitLightRegistry.refresh_light_ranges(subtree): relative child (final 1) ambient", img, rel.position)
	_lit(case_name, "subtree refresh leaves the absolute z 4 box lit", img, abs_box.position)
	# Reparenting re-derives by itself (the node enters a canvas again).
	var l5 := get_node("Layer5") as CanvasLayer
	l.range_z_min = -4096
	l.range_z_max = 4096
	l.range_layer_min = 5
	l.range_layer_max = 5
	img = await capture()
	_dark(case_name, "layer 5..5: base-canvas box ambient", img, abs_box.position)
	abs_box.reparent(l5)
	img = await capture()
	_lit(case_name, "reparented into CanvasLayer 5: lit with no refresh call", img, abs_box.position)
	check(case_name, "canvas_layer after the reparent", 5, LitReceiverHelper.canvas_layer(abs_box))
	abs_box.reparent(parent)
	img = await capture()
	_dark(case_name, "reparented back to the base canvas: ambient again", img, abs_box.position)
	l.name = "PointRelative"


# --- LitTileMapLayer and LitAnimatedSprite2D -----------------------------------------------------

func _tilemap_and_animated() -> void:
	var case_name := "tilemap_ranges"
	var c := Vector2(520, 760)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	var src := TileSetAtlasSource.new()
	src.texture = tex_sized(Vector2(16, 16))
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src, 0)
	var map_a := LitTileMapLayer.new()
	map_a.tile_set = ts
	map_a.position = c + Vector2(-104, -24)
	for x in 3:
		for y in 3:
			map_a.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))
	map_a.specular_strength = 0.0
	map_a.z_index = 2
	add_child(map_a)
	var map_b := LitTileMapLayer.new()
	map_b.tile_set = ts
	map_b.position = c + Vector2(56, -24)
	for x in 3:
		for y in 3:
			map_b.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))
	map_b.specular_strength = 0.0
	get_node("Layer2").add_child(map_b)
	var pa := map_a.position + Vector2(24, 24)
	var pb := map_b.position + Vector2(24, 24)
	var l := point_light(c, 140.0, 0.8, Color.WHITE, 200.0)
	await frames(2)
	var img := await capture()
	_lit(case_name, "default ranges: z 2 tilemap lit", img, pa)
	_lit(case_name, "default ranges: layer 2 tilemap lit", img, pb)
	check(case_name, "z 2 tilemap proxies receiver_z", 2, int(map_a.material.get_shader_parameter("receiver_z")))
	check(case_name, "layer 2 tilemap proxies receiver_layer", 2, int(map_b.material.get_shader_parameter("receiver_layer")))
	l.range_z_min = 2
	l.range_z_max = 2
	img = await capture()
	_lit(case_name, "z 2..2: z 2 tilemap lit", img, pa)
	_dark(case_name, "z 2..2: z 0 tilemap on layer 2 ambient", img, pb)
	l.range_z_min = -4096
	l.range_z_max = 4096
	l.range_layer_min = 2
	l.range_layer_max = 2
	img = await capture()
	_dark(case_name, "layer 2..2: base-canvas tilemap ambient", img, pa)
	_lit(case_name, "layer 2..2: layer 2 tilemap lit", img, pb)
	map_a.z_index = 0
	map_a.refresh_light_ranges()
	l.range_layer_min = 0
	l.range_layer_max = 0
	l.range_z_min = 1
	l.range_z_max = 4096
	img = await capture()
	_dark(case_name, "z 1..4096 after z_index 2 -> 0 + refresh: tilemap ambient", img, pa)
	check(case_name, "refresh re-proxied receiver_z", 0, int(map_a.material.get_shader_parameter("receiver_z")))

	case_name = "animated_sprite_ranges"
	var sf := SpriteFrames.new()
	sf.add_frame(&"default", canvas_tex(tex_sized(BOX)))
	sf.add_frame(&"default", canvas_tex(tex_sized(BOX)))
	var anim := LitAnimatedSprite2D.new()
	anim.sprite_frames = sf
	anim.position = c + Vector2(0, 80)
	anim.specular_strength = 0.0
	anim.z_index = 3
	add_child(anim)
	anim.play(&"default")
	await frames(1)
	img = await capture()
	_lit(case_name, "z 1..4096: z 3 animated sprite lit", img, anim.position)
	l.range_z_min = 4
	img = await capture()
	_dark(case_name, "z 4..4096: z 3 animated sprite ambient", img, anim.position)
	anim.z_index = 5
	anim.refresh_light_ranges()
	img = await capture()
	_lit(case_name, "z_index 5 + refresh_light_ranges(): lit", img, anim.position)
	l.range_z_min = -4096
	l.range_layer_min = 2
	l.range_layer_max = 2
	l.name = "PointTilemap"


# --- pooling ----------------------------------------------------------------------------------

func _pooling() -> void:
	var case_name := "pooling_by_depth"
	var c := Vector2(1000, 760)
	var a := _box(c + Vector2(-150, -70), 0)
	var b := _box(c + Vector2(-150, 0), 7)
	var d := _box(c + Vector2(-150, 70), -7, get_node("Layer5"))
	var e := _box(c + Vector2(-80, 0), 7)
	await frames(1)
	check_true(case_name, "sprites at z 0, 7 and -7 (one on layer 5) hold three different pooled materials",
			not is_same(a.material, b.material) and not is_same(a.material, d.material)
			and not is_same(b.material, d.material))
	check_true(case_name, "two sprites at z 7 share one pooled material", is_same(b.material, e.material))
	check_true(case_name, "that material is pooled", LitLightRegistry.pool_is_pooled(b.material))
	check(case_name, "the z 7 entry holds receiver_z 7", 7, int((b.material as ShaderMaterial).get_shader_parameter("receiver_z")))
	check(case_name, "the layer 5 entry holds receiver_layer 5", 5, int((d.material as ShaderMaterial).get_shader_parameter("receiver_layer")))
	check(case_name, "the z 0 entry holds the declared defaults", 0,
			int((a.material as ShaderMaterial).get_shader_parameter("receiver_z")) + int((a.material as ShaderMaterial).get_shader_parameter("receiver_layer")))
	var entries: int = LitLightRegistry.pool_stats().entries
	b.z_index = 9
	b.refresh_light_ranges()
	await frames(1)
	check(case_name, "a z change re-keys to one new pool entry", entries + 1, LitLightRegistry.pool_stats().entries)
	check(case_name, "the re-keyed material holds receiver_z 9", 9, int((b.material as ShaderMaterial).get_shader_parameter("receiver_z")))
	check_true(case_name, "the poolmate left at z 7 keeps the z 7 material", not is_same(b.material, e.material)
			and int((e.material as ShaderMaterial).get_shader_parameter("receiver_z")) == 7)
	var ranged := point_light(c + Vector2(-150, 0), 200.0, 0.8, Color.WHITE, 200.0)
	ranged.range_z_min = 9
	ranged.range_z_max = 9
	var img := await capture()
	_lit(case_name, "z 9..9 light: the z 9 sprite is lit through its re-keyed material", img, b.position)
	_dark(case_name, "z 9..9 light: the z 0 sprite 70 px away is ambient", img, a.position)
	_dark(case_name, "z 9..9 light: the z 7 sprite 70 px away is ambient", img, e.position)
	ranged.name = "PointPool"


# --- shadows, masks -------------------------------------------------------------------------------

func _shadows_and_masks() -> void:
	var case_name := "shadows_unaffected"
	var c := Vector2(1000, 650)
	var wrap := group("Casters")
	var caster := occluder(c + Vector2(50, 0), Vector2(16, 60), wrap)
	caster.z_index = 5
	var lit_box := _box(c + Vector2(120, 0), 0)
	var l := point_light(c, 200.0, 0.8, Color.WHITE, 200.0)
	l.shadow_enabled = true
	l.shadow_hardness = 1.0
	l.range_z_min = 0
	l.range_z_max = 0
	await frames(3)
	var img := await capture()
	_dark(case_name, "z 0..0 light: in-range box behind a z 5 occluder is shadowed (ranges never cull casters)",
			img, lit_box.position)
	caster.position.y += 200.0
	await frames(2)
	img = await capture()
	_lit(case_name, "occluder moved away: the in-range box is lit", img, lit_box.position)
	caster.position.y -= 200.0
	lit_box.z_index = 1
	lit_box.refresh_light_ranges()
	await frames(2)
	img = await capture()
	_dark(case_name, "box moved out of the z range: ambient (no light, so no shadow either)", img, lit_box.position)
	lit_box.z_index = 0
	lit_box.refresh_light_ranges()

	case_name = "masks_compose"
	var m1 := _box(c + Vector2(-120, 0), 0, null, 1)
	var m2 := _box(c + Vector2(0, -110), 0, null, 2)
	l.light_mask = 2
	await frames(1)
	img = await capture()
	_dark(case_name, "light_mask 2 vs receiver_mask 1 (z in range): ambient", img, m1.position)
	_lit(case_name, "light_mask 2 vs receiver_mask 2 (z in range): lit", img, m2.position)
	m2.z_index = 3
	m2.refresh_light_ranges()
	img = await capture()
	_dark(case_name, "mask passes but z 3 is out of 0..0: ambient", img, m2.position)
	l.light_mask = 1
	img = await capture()
	_lit(case_name, "mask 1 and z 0: lit", img, m1.position)
	l.name = "PointShadow"


# --- luminance mirror -----------------------------------------------------------------------------

func _luminance() -> void:
	var case_name := "luminance_mirror"
	var c := Vector2(1200, 900)
	var l := point_light(c, 140.0, 0.8, Color.WHITE, 200.0)
	l.range_z_min = 2
	l.range_z_max = 2
	var at := c + Vector2(80, 0)
	await frames(1)
	var flat_lit: float = _mgr.sample_luminance(at, 1, 0, null, 32.0, 2, 0)
	check_gt(case_name, "sample_luminance at z 2: lit", flat_lit, AMBIENT, LIT)
	check_approx(case_name, "sample_luminance at z 0 (default args): ambient", AMBIENT,
			_mgr.sample_luminance(at), 0.005)
	check_approx(case_name, "sample_luminance at z 3: ambient", AMBIENT,
			_mgr.sample_luminance(at, 1, 0, null, 32.0, 3, 0), 0.005)
	l.range_z_min = -4096
	l.range_z_max = 4096
	l.range_layer_min = 5
	l.range_layer_max = 5
	check_gt(case_name, "sample_luminance on layer 5: lit", _mgr.sample_luminance(at, 1, 0, null, 32.0, 0, 5), AMBIENT, LIT)
	check_approx(case_name, "sample_luminance on the base canvas: ambient", AMBIENT,
			_mgr.sample_luminance(at, 1, 0, null, 32.0, 0, 0), 0.005)
	check_approx(case_name, "sample_luminance on layer 4: ambient", AMBIENT,
			_mgr.sample_luminance(at, 1, 0, null, 32.0, 0, 4), 0.005)
	l.range_layer_min = 0
	l.range_layer_max = 0
	check_gt(case_name, "layer 0..0: sample_luminance on layer 4 lit", _mgr.sample_luminance(at, 1, 0, null, 32.0, 0, 4), AMBIENT, LIT)
	var spr := _box(at, 0, get_node("Layer5"))
	var base_spr := _box(c + Vector2(-80, 0), 2)
	l.range_z_min = 2
	l.range_z_max = 2
	await frames(1)
	var img := await capture()
	check_approx(case_name, "get_luminance() of a layer-5 sprite at z 0 under a z 2..2 light: ambient",
			AMBIENT, spr.get_luminance(), 0.005)
	check_approx(case_name, "get_luminance() of the z 2 sprite matches its rendered mean",
			lum(img, base_spr.position), base_spr.get_luminance(), 0.02)
	l.range_z_min = -4096
	l.range_z_max = 4096
	l.range_layer_min = 5
	l.range_layer_max = 5
	img = await capture()
	check_approx(case_name, "get_luminance() of the layer-5 sprite under a layer 5..5 light matches the render",
			lum(img, spr.position), spr.get_luminance(), 0.02)
	check_approx(case_name, "get_luminance() of the base-canvas sprite under that light: ambient",
			AMBIENT, base_spr.get_luminance(), 0.005)
	l.name = "PointLuminance"


# --- packed rows ----------------------------------------------------------------------------------

func _packed_rows() -> void:
	var case_name := "packed_rows"
	var reg = _mgr._registry
	var packer = reg._light_packer
	var c := Vector2(1200, 200)
	LitLightRegistry.light_ranges_seen = false
	var plain := point_light(c, 100.0, 0.5, Color.WHITE, 200.0)
	var ranged := point_light(c + Vector2(0, 230), 100.0, 0.5, Color.WHITE, 200.0)
	await frames(2)
	check(case_name, "a default light leaves light_ranges_seen off", false, LitLightRegistry.light_ranges_seen)
	# The frame width is sticky once a section widened it (ranges to 10, exclusions to
	# 16), so the layout constants are checked, not the live width.
	check(case_name, "base row width is 9 texels", 9, int(LitLightRegistry.FrameContextScript.new().texels_per_light))
	check(case_name, "row width with ranges is 10 texels", 10, int(LitLightRegistry.RANGED_TEXELS_PER_LIGHT))
	check(case_name, "row width with exclusions is 16 texels", 16, int(LitLightRegistry.TEXELS_PER_LIGHT))
	check_true(case_name, "live row width is one of the three", int(packer._tpl) in [9, 10, 16])
	check(case_name, "default light: flags bit 19 clear", 0, int(_packed(plain, 1)) & 524288)
	check(case_name, "default light: not ranged", false, plain.ranged)
	ranged.range_z_min = -1
	ranged.range_z_max = 1
	check(case_name, "a non-default range sets light_ranges_seen", true, LitLightRegistry.light_ranges_seen)
	check(case_name, "a non-default range marks the light ranged", true, ranged.ranged)
	await frames(2)
	check(case_name, "ranged light: flags bit 19 set", 524288, int(_packed(ranged, 1)) & 524288)
	check_true(case_name, "a ranged light widens the live rows to at least 10 texels", int(packer._tpl) >= 10)
	check(case_name, "default light next to it: flags bit 19 still clear", 0, int(_packed(plain, 1)) & 524288)
	check_approx(case_name, "texel 9.x = z_min", -1.0, _packed(ranged, 36), 0.001)
	check_approx(case_name, "texel 9.y = z_max", 1.0, _packed(ranged, 37), 0.001)
	check_true(case_name, "layer 0..0 packs as an unbounded layer range (min)", _packed(ranged, 38) < -1e8)
	check_true(case_name, "layer 0..0 packs as an unbounded layer range (max)", _packed(ranged, 39) > 1e8)
	ranged.range_layer_min = 3
	ranged.range_layer_max = 4
	await frames(2)
	check_approx(case_name, "texel 9.z = layer_min", 3.0, _packed(ranged, 38), 0.001)
	check_approx(case_name, "texel 9.w = layer_max", 4.0, _packed(ranged, 39), 0.001)
	ranged.range_z_min = -4096
	ranged.range_z_max = 4096
	ranged.range_layer_min = 0
	ranged.range_layer_max = 0
	await frames(2)
	check(case_name, "back to the defaults: flags bit 19 clear again", 0, int(_packed(ranged, 1)) & 524288)
	check_approx(case_name, "back to the defaults: texel 9 zeroed", 0.0, _packed(ranged, 36), 0.001)
	var sun := directional_light(0.0, 0.0, Color.WHITE, 16.0)
	sun.range_layer_min = 2
	sun.range_layer_max = 2
	await frames(2)
	check(case_name, "directional light: flags bit 19 set", 524288, int(_packed(sun, 1)) & 524288)
	check_approx(case_name, "directional light: texel 9.x = z_min (full)", -4096.0, _packed(sun, 36), 0.001)
	check_approx(case_name, "directional light: texel 9.z = layer_min", 2.0, _packed(sun, 38), 0.001)
	sun.queue_free()
	await frames(1)


## One float of a light's packed row (texel index * 4 + component).
func _packed(light: Node, float_index: int) -> float:
	var reg = _mgr._registry
	var packer = reg._light_packer
	var row: int = reg._ctx.visible.find(light)
	if row < 0:
		return NAN
	return packer._pack_buf[row * packer._tpl * 4 + float_index]
