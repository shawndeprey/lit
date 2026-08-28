class_name TileMapLayerPerfBench extends Node2D

## Large-level TileMapLayer benchmark: generates a crypts-style dungeon (rooms,
## corridors, wall wrapping, props) at RPG level scale, places the real rpghub
## torch (light + flicker script + flame anim + smoke particles) and pot (3 lit
## sprites) objects all over it, and drives a gameplay-zoom camera through the
## level while measuring. Prints LITBENCH stats to stdout (same lines as
## StressTest) and quits.
##
## Run fullscreen for true (uncapped) frame times:
##   godot --path . res://Test/misc/tilemaplayer_perf_bench/tilemaplayer_perf_bench.tscn --fullscreen
##
## Options after "--":
##   size=N        map is NxN tiles (default 200, a mid-tier RPG level)
##   seed=N        generation seed
##   warmup=S measure=S capture=PATH   as in StressTest
##   zoom=X        camera zoom (default 2, the RPG's gameplay zoom)
##   speed=PX      camera speed in world px/s (default 240); camera=off holds still
##   torches=off   no torch objects at all
##   pots=off      no pot objects at all
##   lights=off|N  disable every torch light / all but the first N (objects stay)
##   shadows=on    enable shadows on the torch lights (RPG torches are shadowless)
##   range=N       override torch light range
##   solid=on      fill unexcavated rock with the occluding background tile
##   potmode=plain pots built from plain Sprite2Ds sharing the scene's receiver
##                 materials (no LitSprite2D script) - drive-cost attribution
##   dummies=N     spawn N nodes with an empty _process - callback-overhead control

const TORCH_SCENE := preload("res://Test/misc/tilemaplayer_perf_bench/props/crypt_torch/crypt_torch.tscn")
const POT_SCENE := preload("res://Test/misc/tilemaplayer_perf_bench/props/pot/pot.tscn")
const POT_PLAIN_SCENE := preload("res://Test/misc/tilemaplayer_perf_bench/props/pot/pot_plain.tscn")
const DUMMY_SCRIPT := preload("res://Test/misc/tilemaplayer_perf_bench/props/dummy_process.gd")

const SOURCE_ID := 1
const TILE := 16
const FLOOR_ATLAS := Vector2i(6, 0)
const SOLID_ATLAS := Vector2i(1, 3)

# Cell model and wall wrapping mirror rpghub's crypts generator.
const SOLID := 0
const FLOOR := 1
const W_TOP := 2
const W_BOTTOM := 3
const W_RIGHT := 4
const W_LEFT := 5
const W_TL_INNER := 6
const W_TR_INNER := 7
const W_TLR_INNER := 8
const W_TLRB := 9
const W_LR := 10
const W_BL := 11
const W_BR := 12
const W_TL := 13
const W_TR := 14
const W_TL_RIGHT := 15
const W_TR_LEFT := 16
const W_TL_BR := 17
const W_TR_BL := 18
const W_TL_BOTTOM := 19
const W_TR_BOTTOM := 20
const W_BR_LEFT := 21
const W_BL_RIGHT := 22
const W_TL_TR := 23
const W_BL_BR := 24
const W_TL_TR_CONNECTED := 25
const TORCH_WALLS: Array[int] = [W_TOP, W_BOTTOM, W_RIGHT, W_LEFT]

const WALL_ATLAS := {
	W_TOP: Vector2i(1, 18), W_BOTTOM: Vector2i(4, 19),
	W_RIGHT: Vector2i(0, 17), W_LEFT: Vector2i(2, 17),
	W_TL_INNER: Vector2i(0, 16), W_TR_INNER: Vector2i(2, 16),
	W_TLR_INNER: Vector2i(6, 17), W_TLRB: Vector2i(6, 19),
	W_LR: Vector2i(6, 18), W_BL: Vector2i(3, 19), W_BR: Vector2i(5, 19),
	W_TL: Vector2i(3, 16), W_TR: Vector2i(5, 16),
	W_TL_RIGHT: Vector2i(7, 16), W_TR_LEFT: Vector2i(8, 16),
	W_TL_BR: Vector2i(7, 18), W_TR_BL: Vector2i(8, 18),
	W_TL_BOTTOM: Vector2i(9, 16), W_TR_BOTTOM: Vector2i(10, 16),
	W_BR_LEFT: Vector2i(9, 19), W_BL_RIGHT: Vector2i(10, 19),
	W_TL_TR: Vector2i(11, 16), W_BL_BR: Vector2i(11, 18),
	W_TL_TR_CONNECTED: Vector2i(12, 16),
}

const GRAVE_ATLAS: Array[Vector2i] = [
	Vector2i(16, 8), Vector2i(17, 8), Vector2i(18, 8), Vector2i(19, 8),
	Vector2i(20, 8), Vector2i(21, 8), Vector2i(16, 10), Vector2i(18, 10),
	Vector2i(20, 10), Vector2i(17, 12), Vector2i(19, 12), Vector2i(21, 12),
]

# Room/corridor constants from rpghub's placement + connectivity passes.
const ROOM_PADDING := 3
const ROOM_ATTEMPTS := 250
const ROOM_DENSITY := 20
const NEAREST_K := 3
const LOOP_CHANCE := 0.18
const CORRIDOR_W := 2
const JITTER_SEG_MIN := 3
const JITTER_SEG_MAX := 7
const DOOR_THROAT_MIN := 2
const DOOR_THROAT_MAX := 4
const TORCH_CHANCE := 4      # percent, per plain wall cell
const POT_CHANCE := 10       # percent, per floor cell orthogonal to a wall

const RNG_SEED := 0xC0FFEE
const WARMUP_SEC := 3.0
const MEASURE_SEC := 10.0
const CAPTURE_CLOCK := 60.0

var _opt_size := 200
var _opt_seed := RNG_SEED
var _opt_warmup := WARMUP_SEC
var _opt_measure := MEASURE_SEC
var _opt_capture := ""
var _opt_zoom := 2.0
var _opt_speed := 240.0
var _opt_camera := true
var _opt_torches := true
var _opt_pots := true
var _opt_lights := -1        # -1 all, 0 off, N keep first N enabled
var _opt_shadows := false
var _opt_range := 0.0
var _opt_solid := false
var _opt_potmode := "lit"
var _opt_dummies := 0

var _rng := RandomNumberGenerator.new()
var _w := 0
var _h := 0
var _cells := PackedByteArray()
var _room_ids := PackedInt32Array()
var _rooms: Array[Rect2i] = []
var _mst_edges: Array[Vector2i] = []

var _floor_layer: TileMapLayer
var _walls_layer: TileMapLayer
var _props_layer: TileMapLayer
var _camera: Camera2D
var _route := PackedVector2Array()
var _route_cum := PackedFloat64Array()
var _route_len := 0.0

var _torch_count := 0
var _pot_count := 0
var _grave_count := 0
var _lights_enabled := 0
var _gen_ms := 0
var _shadow_algo_name := "?"

var _clock := 0.0
var _state := "boot"
var _state_time := 0.0
var _frame_times := PackedFloat64Array()
var _process_times := PackedFloat64Array()
var _render_cpu := PackedFloat64Array()
var _render_gpu := PackedFloat64Array()
var _packed_lights := PackedInt32Array()
var _hud: Label


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() != 2:
			continue
		match kv[0]:
			"size": _opt_size = maxi(int(kv[1]), 24)
			"seed": _opt_seed = int(kv[1])
			"warmup": _opt_warmup = float(kv[1])
			"measure": _opt_measure = float(kv[1])
			"capture": _opt_capture = kv[1]
			"zoom": _opt_zoom = maxf(float(kv[1]), 0.05)
			"speed": _opt_speed = float(kv[1])
			"camera": _opt_camera = kv[1] != "off"
			"torches": _opt_torches = kv[1] != "off"
			"pots": _opt_pots = kv[1] != "off"
			"lights": _opt_lights = 0 if kv[1] == "off" else int(kv[1])
			"shadows": _opt_shadows = kv[1] == "on"
			"range": _opt_range = float(kv[1])
			"solid": _opt_solid = kv[1] == "on"
			"potmode": _opt_potmode = kv[1]
			"dummies": _opt_dummies = maxi(int(kv[1]), 0)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	var ui := CanvasLayer.new()
	ui.layer = 128
	add_child(ui)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 18)
	_hud.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hud.add_theme_constant_override("outline_size", 6)
	_hud.position = Vector2(16, 14)
	ui.add_child(_hud)

	_setup.call_deferred()


func _setup() -> void:
	_floor_layer = get_node("TileMaps/floor")
	_walls_layer = get_node("TileMaps/walls")
	_props_layer = get_node("TileMaps/props")
	var template: Node2D = get_node("Lights/LitPointLight2D")
	template.get_parent().remove_child(template)
	template.queue_free()

	_floor_layer.clear()
	_walls_layer.clear()
	_props_layer.clear()

	seed(_opt_seed)
	_rng.seed = _opt_seed
	var t0 := Time.get_ticks_msec()
	_generate()
	_add_background()
	_paint_layers()
	_place_props_and_torches()
	_build_route()
	_gen_ms = Time.get_ticks_msec() - t0

	_camera = Camera2D.new()
	_camera.zoom = Vector2(_opt_zoom, _opt_zoom)
	add_child(_camera)
	_camera.make_current()
	_camera.position = _route_pos(0.0)

	_state = "warmup"
	_state_time = 0.0


# --- generation: compact port of rpghub's crypts passes -----------------------------

func _idx(x: int, y: int) -> int:
	return y * _w + x

func _cell(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= _w or y >= _h:
		return SOLID
	return _cells[_idx(x, y)]

func _is_floor(x: int, y: int) -> bool:
	return _cell(x, y) == FLOOR

func _is_wall(x: int, y: int) -> bool:
	return _cell(x, y) >= W_TOP


func _generate() -> void:
	_w = _opt_size
	_h = _opt_size
	_cells = PackedByteArray()
	_cells.resize(_w * _h)
	_room_ids = PackedInt32Array()
	_room_ids.resize(_w * _h)
	_place_rooms()
	_connect_rooms()
	_smooth_floors()
	_wrap_walls()


func _place_rooms() -> void:
	var target := int(round((float(_w * _h) / 2500.0) * float(ROOM_DENSITY)))
	var s := sqrt(float(_w * _h) / 10000.0)
	var min_wh := int(round(8.0 * clampf(s, 1.0, 1.6)))
	var max_wh := int(round(16.0 * clampf(s, 1.0, 2.0)))
	for attempt in ROOM_ATTEMPTS:
		if _rooms.size() >= target:
			break
		var rw := _rng.randi_range(min_wh, max_wh)
		var rh := _rng.randi_range(min_wh, max_wh)
		var rect := Rect2i(_rng.randi_range(1, _w - rw - 2), _rng.randi_range(1, _h - rh - 2), rw, rh)
		var expanded := rect.grow(ROOM_PADDING)
		var overlaps := false
		for r in _rooms:
			if expanded.intersects(r):
				overlaps = true
				break
		if overlaps:
			continue
		var room_id := _rooms.size() + 1
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				_cells[_idx(x, y)] = FLOOR
				_room_ids[_idx(x, y)] = room_id
		_rooms.append(rect)


func _connect_rooms() -> void:
	var n := _rooms.size()
	if n <= 1:
		return
	var centers: Array[Vector2i] = []
	for r in _rooms:
		centers.append(r.get_center())

	var edge_map := {}
	for i in n:
		var dists: Array = []
		for j in n:
			if i == j:
				continue
			var d := centers[i] - centers[j]
			dists.append({"j": j, "w": d.x * d.x + d.y * d.y})
		dists.sort_custom(func(a, b): return a["w"] < b["w"])
		for k in mini(NEAREST_K, dists.size()):
			var j: int = dists[k]["j"]
			var key := "%d|%d" % [mini(i, j), maxi(i, j)]
			if not edge_map.has(key):
				edge_map[key] = [mini(i, j), maxi(i, j), int(dists[k]["w"])]
	var edges: Array = edge_map.values()
	edges.sort_custom(func(a, b):
		if a[2] != b[2]: return a[2] < b[2]
		if a[0] != b[0]: return a[0] < b[0]
		return a[1] < b[1])

	var parent := PackedInt32Array()
	parent.resize(n)
	for i in n:
		parent[i] = i
	var chosen: Array = []
	for e in edges:
		var ra := _dsu_find(parent, e[0])
		var rb := _dsu_find(parent, e[1])
		if ra != rb:
			parent[ra] = rb
			chosen.append(e)
			_mst_edges.append(Vector2i(e[0], e[1]))
		elif _rng.randf() < LOOP_CHANCE:
			chosen.append(e)
	for e in chosen:
		_carve_corridor(_room_floor_tile(e[0]), _room_floor_tile(e[1]))


func _dsu_find(parent: PackedInt32Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]
		x = parent[x]
	return x


func _room_floor_tile(i: int) -> Vector2i:
	var c: Vector2i = _rooms[i].get_center()
	if _is_floor(c.x, c.y):
		return c
	for y in range(_rooms[i].position.y, _rooms[i].end.y):
		for x in range(_rooms[i].position.x, _rooms[i].end.x):
			if _is_floor(x, y):
				return Vector2i(x, y)
	return c


func _carve_corridor(a: Vector2i, b: Vector2i) -> void:
	var p := a
	var guard := _w * _h
	var prefer_x := _rng.randi_range(0, 1) == 0
	var seg_left := _rng.randi_range(JITTER_SEG_MIN, JITTER_SEG_MAX)
	var throat_left := 0
	while p != b and guard > 0:
		guard -= 1
		seg_left -= 1
		if seg_left <= 0:
			prefer_x = _rng.randi_range(0, 1) == 0
			seg_left = _rng.randi_range(JITTER_SEG_MIN, JITTER_SEG_MAX)
		var dx := b.x - p.x
		var dy := b.y - p.y
		var move := Vector2i.ZERO
		if absi(dx) >= absi(dy):
			move.x = signi(dx) if prefer_x else 0
			move.y = 0 if prefer_x else signi(dy)
		else:
			move.y = signi(dy) if prefer_x else 0
			move.x = 0 if prefer_x else signi(dx)
		if move == Vector2i.ZERO:
			if dx != 0: move.x = signi(dx)
			elif dy != 0: move.y = signi(dy)
			else: break
		var next := p + move
		if _room_ids[_idx(p.x, p.y)] == 0 and _room_ids[_idx(next.x, next.y)] > 0:
			throat_left = _rng.randi_range(DOOR_THROAT_MIN, DOOR_THROAT_MAX)
		var carve_w := 1 if throat_left > 0 else CORRIDOR_W
		if throat_left > 0:
			throat_left -= 1
		_carve_cell(p, move, carve_w)
		p = next
		_carve_cell(p, move, carve_w)


func _carve_cell(p: Vector2i, move: Vector2i, w: int) -> void:
	_cells[_idx(p.x, p.y)] = FLOOR
	if w <= 1 or _room_ids[_idx(p.x, p.y)] > 0:
		return
	var perp := Vector2i(0, 1) if move.x != 0 else Vector2i(1, 0)
	var side := perp if _rng.randi_range(0, 1) == 0 else -perp
	var q := p + side
	if q.x > 0 and q.y > 0 and q.x < _w - 1 and q.y < _h - 1:
		_cells[_idx(q.x, q.y)] = FLOOR


func _smooth_floors() -> void:
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for _it in 2:
		var to_floor: Array[Vector2i] = []
		var to_solid: Array[Vector2i] = []
		for y in range(1, _h - 1):
			for x in range(1, _w - 1):
				var n_floor := 0
				for d in dirs:
					if _is_floor(x + d.x, y + d.y):
						n_floor += 1
				if not _is_floor(x, y) and n_floor >= 3:
					to_floor.append(Vector2i(x, y))
				elif _is_floor(x, y) and n_floor <= 1:
					to_solid.append(Vector2i(x, y))
		for p in to_floor:
			_cells[_idx(p.x, p.y)] = FLOOR
		for p in to_solid:
			_cells[_idx(p.x, p.y)] = SOLID


func _wrap_walls() -> void:
	var walls: Array = []
	for y in _h:
		for x in _w:
			if _cell(x, y) != SOLID:
				continue
			var above := _is_floor(x, y - 1)
			var below := _is_floor(x, y + 1)
			var left := _is_floor(x - 1, y)
			var right := _is_floor(x + 1, y)
			var above_right := _is_floor(x + 1, y - 1)
			var above_left := _is_floor(x - 1, y - 1)
			var below_right := _is_floor(x + 1, y + 1)
			var below_left := _is_floor(x - 1, y + 1)
			var tl_wall := not below and not right and below_right
			var tr_wall := not below and not left and below_left
			var bl_wall := not above and not right and above_right and not below
			var br_wall := not above and not left and above_left and not below
			var cell := -1
			if tl_wall and tr_wall and above: cell = W_TL_TR_CONNECTED
			elif tl_wall and tr_wall: cell = W_TL_TR
			elif bl_wall and br_wall: cell = W_BL_BR
			elif tl_wall and left: cell = W_TL_RIGHT
			elif tr_wall and right: cell = W_TR_LEFT
			elif tl_wall and br_wall: cell = W_TL_BR
			elif tr_wall and bl_wall: cell = W_TR_BL
			elif tl_wall and above: cell = W_TL_BOTTOM
			elif tr_wall and above: cell = W_TR_BOTTOM
			elif br_wall and right: cell = W_BR_LEFT
			elif bl_wall and left: cell = W_BL_RIGHT
			elif above and left and right and below: cell = W_TLRB
			elif above and left and right and not below: cell = W_TLR_INNER
			elif (above and left and not below and not right) or (above and tr_wall): cell = W_TL_INNER
			elif (above and right and not below and not left) or (above and tl_wall): cell = W_TR_INNER
			elif not above and right and not below and left: cell = W_LR
			elif tl_wall: cell = W_TL
			elif tr_wall: cell = W_TR
			elif bl_wall: cell = W_BL
			elif br_wall: cell = W_BR
			elif below: cell = W_TOP
			elif above: cell = W_BOTTOM
			elif right: cell = W_LEFT
			elif left: cell = W_RIGHT
			if cell >= 0:
				walls.append([x, y, cell])
	for wc in walls:
		_cells[_idx(wc[0], wc[1])] = wc[2]


# --- painting + props ----------------------------------------------------------------

func _add_background() -> void:
	var bg := Polygon2D.new()
	bg.name = "Background"
	bg.color = Color.BLACK
	var m := 2048.0
	var size := Vector2(_w, _h) * TILE
	bg.polygon = PackedVector2Array([
		Vector2(-m, -m), Vector2(size.x + m, -m),
		Vector2(size.x + m, size.y + m), Vector2(-m, size.y + m),
	])
	add_child(bg)
	move_child(bg, 0)


func _paint_layers() -> void:
	for y in _h:
		for x in _w:
			var c := _cell(x, y)
			var pos := Vector2i(x, y)
			if c == FLOOR:
				_floor_layer.set_cell(pos, SOURCE_ID, FLOOR_ATLAS)
			elif c >= W_TOP:
				_floor_layer.set_cell(pos, SOURCE_ID, FLOOR_ATLAS)
				_walls_layer.set_cell(pos, SOURCE_ID, WALL_ATLAS[c])
			elif _opt_solid:
				_walls_layer.set_cell(pos, SOURCE_ID, SOLID_ATLAS)


func _cell_world(x: int, y: int) -> Vector2:
	return _floor_layer.to_global(_floor_layer.map_to_local(Vector2i(x, y)))


func _place_props_and_torches() -> void:
	var pots_parent := Node2D.new()
	pots_parent.name = "Props"
	add_child(pots_parent)
	move_child(pots_parent, get_node("Lights").get_index())
	var lights_parent := get_node("Lights")

	var torch_cells: Array = []
	for y in _h:
		for x in _w:
			var c := _cell(x, y)
			if c == FLOOR:
				if _is_wall(x, y - 1) or _is_wall(x, y + 1) or _is_wall(x - 1, y) or _is_wall(x + 1, y):
					if _rng.randi_range(0, 99) < POT_CHANCE and _opt_pots:
						var pot := (POT_PLAIN_SCENE if _opt_potmode == "plain" else POT_SCENE).instantiate()
						pot.position = _cell_world(x, y)
						pots_parent.add_child(pot)
						_pot_count += 1
			elif c in TORCH_WALLS:
				if _rng.randi_range(0, 99) < TORCH_CHANCE:
					torch_cells.append([x, y, c])

	# Gravestone rows in about half the rooms, on a sparse interior grid.
	for r in _rooms:
		if _rng.randf() >= 0.5:
			continue
		for y in range(r.position.y + 2, r.end.y - 2, 3):
			for x in range(r.position.x + 2, r.end.x - 2, 2):
				if not _is_floor(x, y) or _rng.randf() >= 0.5:
					continue
				_props_layer.set_cell(Vector2i(x, y), SOURCE_ID,
						GRAVE_ATLAS[_rng.randi() % GRAVE_ATLAS.size()])
				_grave_count += 1

	if _opt_dummies > 0:
		var dummies_parent := Node2D.new()
		dummies_parent.name = "Dummies"
		add_child(dummies_parent)
		for i in _opt_dummies:
			dummies_parent.add_child(DUMMY_SCRIPT.new())

	if not _opt_torches:
		return
	for tc in torch_cells:
		var torch := TORCH_SCENE.instantiate()
		var world: Vector2 = _cell_world(tc[0], tc[1])
		match tc[2]:
			W_BOTTOM: world -= Vector2(0, 9)
			W_RIGHT: world -= Vector2(9, 0)
			W_LEFT: world += Vector2(9, 0)
		torch.position = world
		var light: Node2D = torch.get_node("PointLight2D")
		if _opt_lights >= 0 and _torch_count >= _opt_lights:
			light.enabled = false
		else:
			_lights_enabled += 1
		if _opt_shadows:
			light.shadow_enabled = true
		if _opt_range > 0.0:
			light.range = _opt_range
		_shadow_algo_name = ["raymarch", "cone", "stochastic"][light.shadow_algorithm]
		lights_parent.add_child(torch)
		_torch_count += 1


# --- camera route: walk the MST room graph depth-first, backtracking included --------

func _build_route() -> void:
	var points := PackedVector2Array()
	if _rooms.is_empty():
		points.append(Vector2(_w, _h) * TILE * 0.5)
	else:
		var adj := {}
		for e in _mst_edges:
			if not adj.has(e.x): adj[e.x] = []
			if not adj.has(e.y): adj[e.y] = []
			adj[e.x].append(e.y)
			adj[e.y].append(e.x)
		var visited := {}
		var order: Array[int] = []
		_route_dfs(0, adj, visited, order)
		for i in order:
			var c: Vector2i = _rooms[i].get_center()
			points.append(_cell_world(c.x, c.y))
	if points.size() == 1 or not _opt_camera:
		_route = points.slice(0, 1)
		_route_len = 0.0
		return
	points.append(points[0])
	_route = points
	_route_cum = PackedFloat64Array()
	_route_cum.resize(points.size())
	_route_cum[0] = 0.0
	for i in range(1, points.size()):
		_route_cum[i] = _route_cum[i - 1] + points[i - 1].distance_to(points[i])
	_route_len = _route_cum[points.size() - 1]


func _route_dfs(i: int, adj: Dictionary, visited: Dictionary, order: Array[int]) -> void:
	visited[i] = true
	order.append(i)
	for j in adj.get(i, []):
		if not visited.has(j):
			_route_dfs(j, adj, visited, order)
			order.append(i)


func _route_pos(dist: float) -> Vector2:
	if _route_len <= 0.0:
		return _route[0]
	var d := fmod(dist, _route_len)
	var lo := 0
	var hi := _route_cum.size() - 1
	while lo + 1 < hi:
		var mid := (lo + hi) >> 1
		if _route_cum[mid] <= d:
			lo = mid
		else:
			hi = mid
	var seg := _route_cum[hi] - _route_cum[lo]
	var t := 0.0 if seg <= 0.0 else (d - _route_cum[lo]) / seg
	return _route[lo].lerp(_route[hi], t)


# --- benchmark loop ------------------------------------------------------------------

func _process(dt: float) -> void:
	if _state == "boot" or _state == "done":
		return
	_clock += dt
	if _opt_camera:
		_camera.position = _route_pos(_clock * _opt_speed)
	_state_time += dt

	if _state == "warmup":
		_hud.text = "WARMUP %.1f / %.1f s   map %dx%d   torches %d   pots %d" \
				% [_state_time, _opt_warmup, _w, _h, _torch_count, _pot_count]
		if _state_time >= _opt_warmup:
			_state = "measure"
			_state_time = 0.0
		return

	var vp_rid := get_viewport().get_viewport_rid()
	_frame_times.append(dt)
	_process_times.append(Performance.get_monitor(Performance.TIME_PROCESS))
	_render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp_rid))
	_render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp_rid))
	_packed_lights.append(_sample_packed_lights())
	_hud.text = "MEASURE %.1f / %.1f s   torches %d   pots %d   packed %d   fps %d" \
			% [_state_time, _opt_measure, _torch_count, _pot_count, _packed_lights[-1], Engine.get_frames_per_second()]
	if _state_time >= _opt_measure:
		_state = "done"
		_report()
		if _opt_capture != "":
			_capture_and_quit()
		else:
			get_tree().quit()


## Lights the registry actually packed this frame; -1 when unreadable.
func _sample_packed_lights() -> int:
	var mgr := get_node_or_null("/root/LitManager")
	if mgr == null:
		return -1
	return mgr._registry._ctx.visible.size()


func _capture_and_quit() -> void:
	_clock = CAPTURE_CLOCK
	if _opt_camera:
		_camera.position = _route_pos(_clock * _opt_speed)
	_hud.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_opt_capture)
	print("LITBENCH capture=%s" % _opt_capture)
	get_tree().quit()


func _report() -> void:
	var n := _frame_times.size()
	var total := 0.0
	for t in _frame_times:
		total += t
	var avg_ms := total / float(n) * 1000.0
	var fps := float(n) / total

	var sorted := _frame_times.duplicate()
	sorted.sort()
	var worst_n := maxi(int(float(n) * 0.01), 1)
	var worst_sum := 0.0
	for i in worst_n:
		worst_sum += sorted[n - 1 - i]
	var low1_ms := worst_sum / float(worst_n) * 1000.0

	var stall := 0
	var hitch := 0
	var smooth := 0
	var worst := 0.0
	var smooth_time := 0.0
	for t in _frame_times:
		worst = maxf(worst, t)
		if t > 0.1: stall += 1
		elif t > 0.025: hitch += 1
		else:
			smooth += 1
			smooth_time += t
	print("LITBENCH histo stall100=%d hitch25=%d smooth=%d worst_ms=%.1f smooth_share=%.2f"
			% [stall, hitch, smooth, worst * 1000.0, smooth_time / total])

	var packed_sum := 0
	var packed_max := 0
	for c in _packed_lights:
		packed_sum += c
		packed_max = maxi(packed_max, c)
	print("LITBENCH map=%dx%d rooms=%d torches=%d pots=%d graves=%d solid=%s gen_ms=%d" \
			% [_w, _h, _rooms.size(), _torch_count, _pot_count, _grave_count,
			"on" if _opt_solid else "off", _gen_ms])
	print("LITBENCH potmode=%s dummies=%d" % [_opt_potmode, _opt_dummies])
	var census := {}
	_census(get_tree().root, census)
	var parts: Array = []
	for k in census:
		parts.append("%s=%d" % [k, census[k]])
	parts.sort()
	print("LITBENCH processing " + " ".join(parts))
	print("LITBENCH packed_lights avg=%.1f max=%d of=%d" \
			% [float(packed_sum) / maxi(n, 1), packed_max, _lights_enabled])
	print("LITBENCH camera=%s zoom=%.2f speed=%.0f route_px=%.0f" \
			% ["on" if _opt_camera else "off", _opt_zoom, _opt_speed, _route_len])
	print("LITBENCH shadow_algo=%s" % _shadow_algo_name)
	print("LITBENCH shadows=%s range=%s" % ["on" if _opt_shadows else "off",
			("%.0f" % _opt_range) if _opt_range > 0.0 else "template"])
	print("LITBENCH frames=%d" % n)
	print("LITBENCH avg_fps=%.2f" % fps)
	print("LITBENCH avg_frame_ms=%.3f" % avg_ms)
	print("LITBENCH low1pct_frame_ms=%.3f (%.1f fps)" % [low1_ms, 1000.0 / low1_ms])
	print("LITBENCH main_process_ms=%.3f" % (_mean(_process_times) * 1000.0))
	print("LITBENCH render_cpu_ms=%.3f" % _mean(_render_cpu))
	print("LITBENCH render_gpu_ms=%.3f" % _mean(_render_gpu))
	print("LITBENCH viewport=%s screen=%s" % [get_viewport_rect().size, DisplayServer.screen_get_size()])


## Count processing nodes per script/class, for attributing main_process_ms.
func _census(node: Node, acc: Dictionary) -> void:
	if node.is_processing():
		var s := node.get_script() as Script
		var key := s.resource_path.get_file() if s != null else node.get_class()
		acc[key] = acc.get(key, 0) + 1
	for c in node.get_children():
		_census(c, acc)


func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / float(a.size())
