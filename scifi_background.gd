extends TileMapLayer

## Builds a sci-fi facility background out of the scifi_tiles TileSet at runtime
## via set_cell(), so there's no hand-encoded tile_map_data to maintain. The
## layout is a walled room with a paneled floor, wall band across the top,
## scattered console/button detail tiles, a couple of grates, and a diamond
## motif inset. Tweak the ATLAS_* picks or the build loop to restyle.
##
## Atlas coords are (column, row) into the 16x16 tile atlas. Picks below were
## chosen from the detailed sheet; swap them freely.

const SOURCE_ID := 0

# --- tile role -> atlas coordinate ------------------------------------------
const FLOOR_A := Vector2i(1, 2)   # clean plating
const FLOOR_B := Vector2i(2, 3)   # alt plating (subtle variation)
const FLOOR_C := Vector2i(3, 2)   # third floor variant
const WALL    := Vector2i(1, 1)   # solid wall panel
const WALL_VENT := Vector2i(4, 1) # wall with vertical vent slots
const BTN_CYAN := Vector2i(2, 5)  # console w/ cyan button
const BTN_ORANGE := Vector2i(3, 5)# console w/ orange button
const GRATE   := Vector2i(6, 7)   # floor grate
const DIAMOND := Vector2i(0, 6)   # diamond hazard inset
const PANEL_LIT := Vector2i(2, 6) # panel with inset light

# Room size in tiles.
@export var room_w: int = 30
@export var room_h: int = 20
## Deterministic so the background is stable between runs.
@export var seed: int = 1337


func _ready() -> void:
	build()


func build() -> void:
	clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	for y in range(room_h):
		for x in range(room_w):
			var coord: Vector2i

			# Top three rows read as a back wall.
			if y < 3:
				# Break the wall up with the occasional vent.
				coord = WALL_VENT if (x % 7 == 3 and y == 1) else WALL
			else:
				# Floor field with light variation so it isn't a flat repeat.
				var r := rng.randf()
				if r < 0.72:
					coord = FLOOR_A
				elif r < 0.86:
					coord = FLOOR_B
				else:
					coord = FLOOR_C

			set_cell(Vector2i(x, y), SOURCE_ID, coord)

	# --- scattered detail on the floor -------------------------------------
	# A console cluster near the back-left.
	_place(Vector2i(4, 4), BTN_CYAN)
	_place(Vector2i(5, 4), BTN_ORANGE)
	_place(Vector2i(4, 5), PANEL_LIT)
	_place(Vector2i(5, 5), BTN_CYAN)

	# A second console bank on the right.
	_place(Vector2i(room_w - 6, 5), BTN_ORANGE)
	_place(Vector2i(room_w - 5, 5), BTN_CYAN)
	_place(Vector2i(room_w - 6, 6), BTN_CYAN)

	# Grates set into the floor as a maintenance strip down the middle.
	var gx := room_w / 2
	for gy in range(8, room_h - 2, 3):
		_place(Vector2i(gx, gy), GRATE)

	# Diamond hazard markers flanking the strip.
	_place(Vector2i(gx - 3, room_h - 4), DIAMOND)
	_place(Vector2i(gx + 3, room_h - 4), DIAMOND)


func _place(cell: Vector2i, atlas: Vector2i) -> void:
	if cell.x >= 0 and cell.y >= 0 and cell.x < room_w and cell.y < room_h:
		set_cell(cell, SOURCE_ID, atlas)
