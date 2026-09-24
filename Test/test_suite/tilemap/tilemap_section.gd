extends LitSuiteSection

## LitTileMapLayer: pre-wiring and proxies, lighting on painted cells, tileset
## occlusion polygons casting Lit shadows (only with SDF Collision on), the layer's own
## floor cells exempt from its own walls (self-exclusion from tile rects, self_shadow
## opting back in), tile rects following runtime cell edits, occlusion-layer light
## masks feeding the exclusion tiers, and loose LightOccluder2D descendants.

const AMBIENT := 0.1
const TOL := 0.03
const TILE := 32

var _ts: TileSet
var _map: LitTileMapLayer
var _light: LitPointLight2D
var _floor: LitSprite2D   # separate receiver right of the map, catches the walls' shadows


func run() -> void:
	env(Color(AMBIENT, AMBIENT, AMBIENT))
	await _build()
	await _lighting()
	await _shadows()
	await _self_exclusion()
	await _shadow_ramp()
	await _edits()
	await _masks()
	await _extras()


func _tileset(with_occluders := true) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_occlusion_layer()
	ts.set_occlusion_layer_sdf_collision(0, true)
	var src := TileSetAtlasSource.new()
	src.texture = tex_fn(TILE * 2, TILE, func(x, y):
		if x < TILE:
			return Color(0.8, 0.8, 0.85) if (x > 1 and y > 1 and x < TILE - 2 and y < TILE - 2) else Color(0.5, 0.5, 0.55)
		return Color(0.45, 0.35, 0.3))
	src.texture_region_size = Vector2i(TILE, TILE)
	src.create_tile(Vector2i(0, 0))   # floor
	src.create_tile(Vector2i(1, 0))   # wall with an occluder
	ts.add_source(src, 0)
	if with_occluders:
		var td := src.get_tile_data(Vector2i(1, 0), 0)
		td.add_occluder_polygon(0)
		var poly := OccluderPolygon2D.new()
		var h := TILE * 0.5
		poly.polygon = PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
		td.set_occluder_polygon(0, 0, poly)
	return ts


func _rects(mat: Material) -> int:
	var n = (mat as ShaderMaterial).get_shader_parameter("self_rect_count")
	return 0 if n == null else int(n)


func _extras() -> void:
	var case_name := "tilemap_extras"
	var holder := group("Extras")
	# The layer's own shadow_ignore_mask: a loose mask-2 occluder shadows a floor cell
	# left of the wall; ignoring mask 2 lights it and moves the layer onto an _rx variant.
	var box := occluder(Vector2(300, 120 + 4.5 * TILE), Vector2(16, 60), holder, 2)
	var cell_pt := _cell_center(5, 4)
	_light.shadow_mask = 3
	await frames(4)
	var img := await capture()
	check_approx(case_name, "a loose mask-2 occluder shadows a floor cell (light shadow_mask 3)", AMBIENT * 0.8, lum(img, cell_pt), 0.05)
	_map.shadow_ignore_mask = 2
	await frames(4)
	img = await capture()
	check_gt(case_name, "layer shadow_ignore_mask 2: that cell is lit again", lum(img, cell_pt), AMBIENT * 0.8, 0.1)
	check_true(case_name, "layer shadow_ignore_mask 2: material on an _rx variant",
			LitShaderLibrary.flags_of(_map.material.shader) & LitShaderLibrary.F_RX != 0)
	_map.shadow_ignore_mask = 0
	_light.shadow_mask = 1
	box.queue_free()
	await frames(3)
	# More than four occluder cells collapse into their single union (receiver_driver.gd
	# tile_occluder_rects): two more wall cells make one 5-cell strip.
	var before_count := _rects(_map.material)
	_map.set_cell(Vector2i(6, 2), 0, Vector2i(1, 0))
	_map.set_cell(Vector2i(6, 6), 0, Vector2i(1, 0))
	await frames(3)
	check(case_name, "five wall cells: beyond four the rects collapse into one union", 1, _rects(_map.material))
	var union_rect: Vector4 = (_map.material.get_shader_parameter("self_rects") as PackedVector4Array)[0]
	check_approx(case_name, "the union spans the whole 5-cell column (160 px tall)", 5.0 * TILE, union_rect.w - union_rect.y, 1.0)
	_map.erase_cell(Vector2i(6, 2))
	_map.erase_cell(Vector2i(6, 6))
	await frames(3)
	check(case_name, "back to the original wall cells", before_count, _rects(_map.material))
	# Swapping the TileSet re-derives the tile rects through the layer's changed signal.
	_map.tile_set = _tileset(false)
	await frames(3)
	check(case_name, "tile_set swapped for one without occluder polygons: no self rects", 0, _rects(_map.material))
	_map.tile_set = _ts
	await frames(3)
	check(case_name, "tile_set swapped back: the wall rects return", before_count, _rects(_map.material))
	# A plain TileMapLayer carrying a receiver material is driven like a bare sprite.
	var bare := TileMapLayer.new()
	bare.tile_set = _ts
	bare.material = receiver_material()
	bare.position = Vector2(1000, 700)
	bare.set_cell(Vector2i(0, 0), 0, Vector2i(1, 0))
	bare.set_cell(Vector2i(2, 0), 0, Vector2i(1, 0))
	holder.add_child(bare)
	await frames(3)
	check(case_name, "bare TileMapLayer + receiver material: the registry pushes its two wall rects", 2, _rects(bare.material))
	check_true(case_name, "bare TileMapLayer tiered to the self-exclusion shader",
			LitShaderLibrary.flags_of(bare.material.shader) & LitShaderLibrary.F_SELF_EXCL != 0)
	# Tilemaps never y-sort, even with the setting on.
	set_setting("lit/render/y_sorting", true)
	await frames(4)
	check_true(case_name, "y_sorting on: the LitTileMapLayer stays off the _ysort variant",
			LitShaderLibrary.flags_of(_map.material.shader) & LitShaderLibrary.F_YSORT == 0)
	check_true(case_name, "y_sorting on: the bare TileMapLayer stays off the _ysort variant too",
			LitShaderLibrary.flags_of(bare.material.shader) & LitShaderLibrary.F_YSORT == 0)
	set_setting("lit/render/y_sorting", false)
	await frames(3)
	bare.queue_free()


func _build() -> void:
	label("LitTileMapLayer: 12x10 floor with a 3-cell wall; light on the left; a plain receiver to the right",
			Vector2(24, 74))
	_ts = _tileset()
	_map = LitTileMapLayer.new()
	_map.name = "Map"
	_map.tile_set = _ts
	_map.position = Vector2(200, 120)
	for y in 10:
		for x in 12:
			_map.set_cell(Vector2i(x, y), 0, Vector2i(0, 0))
	for y in range(3, 6):
		_map.set_cell(Vector2i(6, y), 0, Vector2i(1, 0))
	_map.specular_strength = 0.0
	add_child(_map)
	_floor = floor_receiver(Rect2(600, 120, 300, 380))
	_light = point_light(Vector2(120, 120 + 4.5 * TILE), 1200.0, 0.8, Color.WHITE, 300.0)
	_light.falloff = 0.2
	_light.shadow_enabled = true
	await frames(3)


func _cell_center(x: int, y: int) -> Vector2:
	return _map.position + Vector2((x + 0.5) * TILE, (y + 0.5) * TILE)


## The world SDF re-renders when tracked content moves (occluder / tilemap transforms
## and visibility, loose-occluder flags) or the view reframes; tileset flag and cell
## edits are not tracked, so a static scene keeps the old SDF. Nudging the layer one
## pixel and back forces two re-renders and leaves it where it was.
func _refresh_sdf() -> void:
	_map.position.x += 1.0
	await frames(2)
	_map.position.x -= 1.0
	await frames(2)


func _lighting() -> void:
	var case_name := "tilemap_lighting"
	var fresh := LitTileMapLayer.new()
	check_true(case_name, "fresh LitTileMapLayer carries the fast receiver material",
			fresh.material is ShaderMaterial and LitShaderLibrary.flags_of((fresh.material as ShaderMaterial).shader) == 0)
	check_proxies(case_name, fresh)
	fresh.free()
	var img := await capture()
	var near := lum(img, _cell_center(1, 4))
	var far := lum(img, _cell_center(11, 8))
	check_gt(case_name, "floor cell near the light is lit", near, AMBIENT, 0.3)
	check_gt(case_name, "attenuation across the map (near brighter than far)", near, far, 0.05)
	_map.receiver_mask = 2
	img = await capture()
	check_approx(case_name, "receiver_mask 2 vs the light's mask 1: ambient only", AMBIENT * 0.8,
			lum(img, _cell_center(1, 4)), 0.05)
	_map.receiver_mask = 1
	_map.emissive_strength = 0.5
	img = await capture()
	check_gt(case_name, "emissive lifts the far cells", lum(img, _cell_center(11, 8)), far, 0.3)
	_map.emissive_strength = 0.0


func _shadows() -> void:
	var case_name := "tilemap_shadows"
	var img := await capture()
	var shadow_pt := Vector2(700, 120 + 4.5 * TILE)   # on the plain receiver, behind the wall
	var lit_pt := Vector2(700, 128)                    # above the wall's shadow band
	check_approx(case_name, "tileset occluders (SDF Collision on) shadow the receiver behind the wall",
			AMBIENT, lum(img, shadow_pt), TOL)
	check_gt(case_name, "beside the shadow band the receiver is lit", lum(img, lit_pt), AMBIENT, 0.12)
	_ts.set_occlusion_layer_sdf_collision(0, false)
	await frames(3)
	img = await capture()
	check_gt(case_name, "(known gap) tileset SDF Collision toggled at runtime re-renders the world SDF by itself",
			lum(img, shadow_pt), AMBIENT, 0.2)
	await _refresh_sdf()
	img = await capture()
	check_gt(case_name, "SDF Collision off: no shadow", lum(img, shadow_pt), AMBIENT, 0.2)
	_ts.set_occlusion_layer_sdf_collision(0, true)
	await _refresh_sdf()
	img = await capture()
	check_approx(case_name, "SDF Collision back on: shadow returns", AMBIENT, lum(img, shadow_pt), TOL)
	_light.shadow_enabled = false
	img = await capture()
	check_gt(case_name, "light shadows off: lit", lum(img, shadow_pt), AMBIENT, 0.2)
	_light.shadow_enabled = true
	_map.visible = false
	await frames(3)
	img = await capture()
	check_gt(case_name, "hidden layer casts nothing", lum(img, shadow_pt), AMBIENT, 0.2)
	_map.visible = true
	await frames(3)


func _self_exclusion() -> void:
	var case_name := "tilemap_self_exclusion"
	var img := await capture()
	var own_floor := _cell_center(8, 4)   # the layer's own floor cell right of the wall
	check(case_name, "tile rects pushed as self rects (3 wall cells)", 3,
			int(_map.material.get_shader_parameter("self_rect_count")))
	check(case_name, "layer on the full (self-exclusion) tier", LitShaderLibrary.F_SELF_EXCL,
			LitShaderLibrary.flags_of(_map.material.shader) & LitShaderLibrary.TIER_MASK)
	check_true(case_name, "material is private (per-node rects)", not LitLightRegistry.pool_is_pooled(_map.material))
	check_gt(case_name, "own floor cell behind the wall stays lit (own walls cast behind the layer)",
			lum(img, own_floor), AMBIENT, 0.2)
	_map.self_shadow = true
	await frames(2)
	img = await capture()
	check_approx(case_name, "self_shadow = true: own floor cell is shadowed (albedo 0.8 x ambient)",
			AMBIENT * 0.8, lum(img, own_floor), TOL)
	check(case_name, "self_shadow = true drops to the fast tier", 0,
			LitShaderLibrary.flags_of(_map.material.shader) & LitShaderLibrary.TIER_MASK)
	_map.self_shadow = false
	await frames(2)
	img = await capture()
	check_gt(case_name, "self_shadow = false again: exempt again", lum(img, own_floor), AMBIENT, 0.2)


# Wall cells span x 392..424 (lit edge 392): the receiver point is 308 px past it,
# the layer's own floor cell (8, 4) 80 px.
func _shadow_ramp() -> void:
	var case_name := "tilemap_shadow_ramp"
	var shadow_pt := Vector2(700, 120 + 4.5 * TILE)
	var own_floor := _cell_center(8, 4)
	_map.self_shadow = true
	_map.shadow_ramp = 600.0
	await frames(4)
	var img := await capture()
	check_between(case_name, "layer shadow_ramp 600: the receiver 308 px past the wall's lit edge is partly shadowed",
			lum(img, shadow_pt), AMBIENT + 0.05, lum(img, Vector2(700, 128)) - 0.05)
	check_gt(case_name, "own floor cell 80 px in (self_shadow on) is mostly lit", lum(img, own_floor), AMBIENT, 0.15)
	_map.shadow_ramp = 0.0
	await frames(4)
	img = await capture()
	check_approx(case_name, "shadow_ramp 0: the receiver behind the wall is dark again", AMBIENT,
			lum(img, shadow_pt), TOL)
	check_approx(case_name, "shadow_ramp 0: own floor cell dark again (albedo 0.8 x ambient)", AMBIENT * 0.8,
			lum(img, own_floor), TOL)
	_map.self_shadow = false
	await frames(2)


func _edits() -> void:
	var case_name := "tilemap_edits"
	_map.set_cell(Vector2i(6, 7), 0, Vector2i(1, 0))
	await frames(3)
	check(case_name, "set_cell adding a wall cell grows the self rects", 4,
			int(_map.material.get_shader_parameter("self_rect_count")))
	await _refresh_sdf()
	var img := await capture()
	# The light sits on row 4.5; the shadow of cell (6, 7) lands where that line
	# crosses x = 700.
	var new_shadow := Vector2(700, 120 + 4.5 * TILE + 3.0 * TILE * (700.0 - 120.0) / (408.0 - 120.0))
	check_approx(case_name, "the new wall cell casts on the receiver behind it", AMBIENT, lum(img, new_shadow), 0.05)
	_map.set_cell(Vector2i(6, 7), 0, Vector2i(0, 0))
	await frames(3)
	check(case_name, "painting it back to floor shrinks the self rects", 3,
			int(_map.material.get_shader_parameter("self_rect_count")))
	await _refresh_sdf()
	img = await capture()
	check_gt(case_name, "and its shadow is gone", lum(img, new_shadow), AMBIENT, 0.2)
	# A loose LightOccluder2D child counts as an own occluder too.
	var occ := occluder(Vector2(9.5 * TILE, 8.5 * TILE), Vector2(TILE, TILE), _map)
	await frames(3)
	check(case_name, "a LightOccluder2D child adds a self rect", 4,
			int(_map.material.get_shader_parameter("self_rect_count")))
	occ.queue_free()
	await frames(3)
	check(case_name, "freeing it heals the count", 3, int(_map.material.get_shader_parameter("self_rect_count")))
	var rects_before: PackedVector4Array = _map.material.get_shader_parameter("self_rects")
	_map.position += Vector2(0, 8)
	await frames(2)
	var rects_after: PackedVector4Array = _map.material.get_shader_parameter("self_rects")
	check_approx(case_name, "moving the layer 8 px moves its self rects 8 px (world space)", 8.0,
			rects_after[0].y - rects_before[0].y, 0.5)
	_map.position -= Vector2(0, 8)
	await frames(2)


func _masks() -> void:
	var case_name := "tilemap_occluder_mask"
	var shadow_pt := Vector2(700, 120 + 4.5 * TILE)
	_ts.set_occlusion_layer_light_mask(0, 2)
	await frames(4)
	var img := await capture()
	check(case_name, "(known gap) an occlusion-layer mask edited at runtime is classified without the layer re-entering the tree",
			false, _ts.get_occlusion_layer_sdf_collision(0))
	# Authored masks are noticed when the layer enters the tree: re-enter it.
	var parent := _map.get_parent()
	parent.remove_child(_map)
	parent.add_child(_map)
	await frames(4)
	img = await capture()
	check(case_name, "occlusion layer mask 2 vs shadow_mask 1: runtime SDF culling flips the tileset flag off",
			false, _ts.get_occlusion_layer_sdf_collision(0))
	# The tree re-entry itself marks the world SDF dirty, and the cull lands in the same
	# refresh, so the re-rendered SDF has no walls.
	check_gt(case_name, "occlusion layer light mask 2 vs shadow_mask 1: walls cast nothing (SDF re-rendered on re-entry)",
			lum(img, shadow_pt), AMBIENT, 0.2)
	# Restore through a light mask change alone (no tree change): the registry flips the
	# tileset flag back, but world_sdf.gd polls only transform and visibility for tilemap
	# layers, so the old wall-free SDF texture stays bound until something tracked moves.
	_light.shadow_mask = 3
	await frames(4)
	check(case_name, "light shadow_mask 3 matches mask 2: culling restored the tileset flag",
			true, _ts.get_occlusion_layer_sdf_collision(0))
	img = await capture()
	check_approx(case_name, "(known gap) restoring a tileset layer via a light shadow_mask change re-renders the world SDF by itself",
			AMBIENT, lum(img, shadow_pt), TOL)
	await _refresh_sdf()
	img = await capture()
	check_approx(case_name, "light shadow_mask 3 matches mask 2 again: shadow back after a tracked move", AMBIENT,
			lum(img, shadow_pt), TOL)
	_floor.shadow_ignore_mask = 2
	await frames(4)
	img = await capture()
	check_gt(case_name, "receiver shadow_ignore_mask 2 ignores the tilemap's shadow", lum(img, shadow_pt),
			AMBIENT, 0.2)
	_floor.shadow_ignore_mask = 0
	# Cull again through the light alone: same staleness in the other direction.
	_light.shadow_mask = 1
	await frames(4)
	check(case_name, "light shadow_mask back to 1: the tileset layer is culled again",
			false, _ts.get_occlusion_layer_sdf_collision(0))
	img = await capture()
	check_gt(case_name, "(known gap) culling a tileset layer via a light shadow_mask change re-renders the world SDF by itself",
			lum(img, shadow_pt), AMBIENT, 0.2)
	await _refresh_sdf()
	img = await capture()
	check_gt(case_name, "culled again: walls cast nothing after a tracked move", lum(img, shadow_pt), AMBIENT, 0.2)
	_ts.set_occlusion_layer_light_mask(0, 1)
	await frames(3)
