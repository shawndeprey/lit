extends RefCounted
class_name LitCookieAtlas

## Packs light cookie textures into one shared atlas and hands out per-texture UV rects.
##
## refresh() is a no-op while the texture set is unchanged; a rebuild happens when a
## texture is added, removed, or emits `changed`. Unpackable textures are skipped with
## a warning and their lights pack as untextured.

const SETTING_MAX_SIZE := "lit/quality/cookie_atlas_max_size"
const DEFAULT_MAX_SIZE := 2048

# Transparent border around each entry so linear filtering doesn't bleed between entries.
const PAD := 2

var _texture: ImageTexture
var _dummy: ImageTexture

# Texture2D -> Rect2: atlas UV rect, inset half a texel. Packed textures only.
var _rects: Dictionary = {}

# Texture2D -> true: every texture seen by the last rebuild, packed or not, so an
# unpackable texture doesn't retrigger a rebuild every frame.
var _known: Dictionary = {}

# Set when a known texture emits `changed`; forces a rebuild.
var _dirty := false

## Rebuild if `textures` differs from the last set, or a texture's contents changed.
func refresh(textures: Array) -> void:
	if not _dirty and textures.size() == _known.size():
		var same := true
		for tex in textures:
			if not _known.has(tex):
				same = false
				break
		if same:
			return
	_rebuild(textures)

## True if `tex` is packed.
func has(tex: Texture2D) -> bool:
	return _rects.has(tex)

## Atlas UV rect for `tex`, or Rect2() if unpacked.
func get_uv_rect(tex: Texture2D) -> Rect2:
	return _rects.get(tex, Rect2())

## The atlas, or a 1x1 transparent dummy so the sampler global stays valid.
func get_texture() -> Texture2D:
	if _texture != null:
		return _texture
	if _dummy == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		_dummy = ImageTexture.create_from_image(img)
	return _dummy

func _on_texture_changed() -> void:
	_dirty = true

## Repack every texture into a fresh atlas.
func _rebuild(textures: Array) -> void:
	_dirty = false

	# Move the changed-signal subscriptions to the new set.
	for tex in _known:
		if is_instance_valid(tex) and tex.changed.is_connected(_on_texture_changed):
			tex.changed.disconnect(_on_texture_changed)
	_known.clear()
	_rects.clear()
	_texture = null

	var max_size := maxi(int(ProjectSettings.get_setting(SETTING_MAX_SIZE, DEFAULT_MAX_SIZE)), 64)

	# Pull a CPU-side RGBA8 image out of each texture; skip anything unreadable,
	# undecompressable, or too large.
	var entries: Array = []
	for tex in textures:
		_known[tex] = true
		if not tex.changed.is_connected(_on_texture_changed):
			tex.changed.connect(_on_texture_changed)
		var img: Image = tex.get_image()
		if img == null or img.get_width() < 2 or img.get_height() < 2:
			push_warning("Lit: cookie texture '%s' has no usable image; its light falls back to analytic falloff." % _tex_name(tex))
			continue
		if img.get_width() + 2 * PAD > max_size or img.get_height() + 2 * PAD > max_size:
			push_warning("Lit: cookie texture '%s' (%dx%d) exceeds lit/quality/cookie_atlas_max_size (%d); its light falls back to analytic falloff." % [_tex_name(tex), img.get_width(), img.get_height(), max_size])
			continue
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		if img.is_compressed():
			push_warning("Lit: cookie texture '%s' uses a format that can't be decompressed; its light falls back to analytic falloff." % _tex_name(tex))
			continue
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		entries.append({"tex": tex, "img": img})
	if entries.is_empty():
		return

	# Shelf packing, tallest first. Width: fits the widest entry, near-square by total
	# area, power of two, capped.
	entries.sort_custom(func(a, b): return a.img.get_height() > b.img.get_height())
	var widest := 0
	var total_area := 0
	for e in entries:
		widest = maxi(widest, e.img.get_width() + 2 * PAD)
		total_area += (e.img.get_width() + 2 * PAD) * (e.img.get_height() + 2 * PAD)
	var width := mini(nearest_po2(maxi(widest, int(ceil(sqrt(float(total_area)))))), max_size)

	var cursor := Vector2i.ZERO
	var shelf_h := 0
	var used_h := 0
	var placements: Array = []
	for e in entries:
		var w: int = e.img.get_width() + 2 * PAD
		var h: int = e.img.get_height() + 2 * PAD
		if cursor.x + w > width:
			cursor.x = 0
			cursor.y += shelf_h
			shelf_h = 0
		if cursor.y + h > max_size:
			push_warning("Lit: cookie atlas is full (lit/quality/cookie_atlas_max_size = %d); '%s' falls back to analytic falloff." % [max_size, _tex_name(e.tex)])
			continue
		placements.append({"e": e, "pos": cursor})
		cursor.x += w
		shelf_h = maxi(shelf_h, h)
		used_h = maxi(used_h, cursor.y + h)
	if placements.is_empty():
		return

	var atlas_img := Image.create(width, used_h, false, Image.FORMAT_RGBA8)
	for p in placements:
		var img: Image = p.e.img
		var pos: Vector2i = Vector2i(p.pos) + Vector2i(PAD, PAD)
		atlas_img.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), pos)
		# UV rect inset half a texel so edge samples stay on texel centers.
		var atlas_size := Vector2(float(width), float(used_h))
		_rects[p.e.tex] = Rect2(
			(Vector2(pos) + Vector2(0.5, 0.5)) / atlas_size,
			(Vector2(img.get_size()) - Vector2(1.0, 1.0)) / atlas_size)
	_texture = ImageTexture.create_from_image(atlas_img)

func _tex_name(tex: Texture2D) -> String:
	return tex.resource_path if tex.resource_path != "" else str(tex)
