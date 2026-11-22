extends Control

## Scrollable grid of scene tiles that fills the window edge to edge. Every tile's hover
## glow is a Lit light, so the menu itself is lit; the ambient is white and the tiles
## darken themselves, so the glow only ever adds.

signal selected(entry: Dictionary)

const TILE := preload("res://Test/integration_test_harness/harness_tile.tscn")
const COOKIE_SIZE := Vector2i(320, 180)

## Tiles per row; the tile width is the window width divided by this.
@export var columns: int = 4

@onready var _grid: GridContainer = $Scroll/Grid
@onready var _backdrop: Sprite2D = $Backdrop

var _cookie: ImageTexture

func build(entries: Array[Dictionary]) -> void:
	randomize()
	_grid.columns = columns
	for e in entries:
		var tile := TILE.instantiate()
		_grid.add_child(tile)
		tile.setup(e)
		tile.pressed.connect(func() -> void: selected.emit(e))
	_layout()
	get_viewport().size_changed.connect(_layout)

func _layout() -> void:
	var screen := get_viewport().get_visible_rect().size
	var tile_size := Vector2(screen.x / columns, screen.x / columns * 9.0 / 16.0)
	if _backdrop.texture == null:
		var px := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		px.fill(Color.WHITE)
		_backdrop.texture = ImageTexture.create_from_image(px)
	_backdrop.scale = screen / Vector2(_backdrop.texture.get_size())
	if _cookie == null:
		_cookie = ImageTexture.create_from_image(_make_cookie())
	for tile in _grid.get_children():
		tile.set_tile_size(tile_size, _cookie, 2.0 * tile_size.x / COOKIE_SIZE.x)

## Soft rectangular frame: clear over the tile's own footprint (the inner half of the
## image), fading out towards the edges. Drawn at twice the tile size it glows around
## the tile without washing out the tile itself.
func _make_cookie() -> Image:
	var img := Image.create(COOKIE_SIZE.x, COOKIE_SIZE.y, false, Image.FORMAT_RGBA8)
	var half := Vector2(COOKIE_SIZE) * 0.25
	var reach := half.y
	for y in COOKIE_SIZE.y:
		for x in COOKIE_SIZE.x:
			var q := (Vector2(x + 0.5, y + 0.5) - Vector2(COOKIE_SIZE) * 0.5).abs() - half
			var d := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0)
			var a := clampf(1.0 - d / reach, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	return img
