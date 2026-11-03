@tool
@icon("res://addons/lit/icons/lit_line_light_2d.svg")
extends LitPositionalLight2D
class_name LitLineLight2D

## A line light for the Lit system: a segment of light for lasers, tube lights and
## light sabers, or a curved path of light for rings, arcs and neon tubes.
##
## The segment is centered on the node along its local +X and follows the node's
## transform (rotation, scale and skew). A tube of length 0 is a point light, and a
## longer one lights every point as a point light would from the nearest point of the
## segment, with `range`, `falloff`, `energy` and `height` meaning the same; where the
## tube bends around a point it adds up like two lights, and past each end it tapers
## off. `width` gives the tube a body, lit from overhead across it, and `glow` dims
## the halo around it against the beam.
## Shadows follow: Raymarched casts one hard march from the nearest point of the
## segment, while Cone Traced and Stochastic march `shadow_samples` narrow cones spread
## along the part of the segment within `range` of the receiver (Stochastic dithers
## them), so shadows are soft along the tube and sharp across it. The cookie stays
## centered on the node; FIT_RANGE spans the capsule's bounding box.[br][br]
##
## Add a Path2D child to bend the light: it follows the child's curve instead of
## `length` (select the Path2D to draw and edit the curve with Godot's pen gizmo), and
## `closed` joins the curve's ends into a loop. The curve is lit as true arcs, as many as
## it needs, each straight stretch as one piece and the bends as up to 32 chords per 32
## arcs; Cone Traced and Stochastic shadows march it as `shadow_samples` chords of equal
## length.
## Everything else is inherited from LitPositionalLight2D and LitLight2D.

const LinePathScript := preload("res://addons/lit/runtime/registry/line_path.gd")
const TESSELLATION_MAX := 32

## How `closed` joins the path's last point back to its first. The values match
## line_path.gd's CLOSE_ constants.
enum CloseMode {
	## The default. Closes the way the rest of the path asks for, after the science of
	## symmetry. Where a rotation or mirror carries a piece of the path exactly onto the gap
	## and maps the whole shape onto itself, it repeats that piece (structural regularity,
	## van Lier, van der Helm & Leeuwenberg 1994; partial symmetry detection, Mitra, Guibas &
	## Pauly 2006). Otherwise it takes the close between Curvature Arc and Biarc that best
	## weighs corners, S-bends (Singh & Hoffman 1999) and size against how symmetric it makes
	## the whole shape (Zabrodsky, Peleg & Avnir 1995), with corners costing less the more
	## cornered the path is. A path that already covers its gap gets nothing added, and ends
	## that run past each other get a straight link.
	SYMMETRIC = 3,
	## Always closes smoothly: the biarc of Ullman's "Filling-in the gaps" (1976), two
	## circular arcs leaving the last point along its direction and reaching the first along
	## its own (Bolton 1975). It rounds every gap, even between two corners.
	BIARC = 1,
	## One circular arc carrying the path's average curvature (its smooth turn over its
	## length; corners do not count) across the gap, bending the same way, with corners
	## where it meets the path (after Singh & Fulvio 2005). A polygon closes straight.
	CURVATURE_ARC = 4,
	## Halfway between Curvature Arc and Biarc: two arcs that leave and arrive halfway
	## between the curvature arc's directions and the path's own, halving its corners.
	SOFT_ARC = 5,
	## Always closes with a straight edge, as closepath does in PostScript, PDF and SVG.
	STRAIGHT = 2,
}

@export_group("Line")
## Length of the emitting segment in local pixels, centered on the node along its local
## +X; it stretches with the node's x scale. `range` and `source_radius` follow the
## node's larger scale axis as on a point light, so this is the way to lengthen a tube.
## 0 is a point light at the node. For a laser, raycast to the wall the beam hits and
## set the length to that distance. Ignored while a Path2D child shapes the light.
@export_range(0.0, 4096.0, 1.0, "or_greater") var length: float = 128.0:
	set(value):
		length = maxf(value, 0.0)
		LitLightRegistry.light_state_changed(self)
## Thickness of the tube in local pixels, scaled like `range`. Under the tube the light
## comes from overhead across this width (a flat, fully lit core) and the falloff runs
## from the tube's surface out to `range`. 0 is an ideal line: a laser; a few pixels
## reads as a light saber, tens as a tube light. Shadows across the tube follow
## `source_radius`.
@export_range(0.0, 1024.0, 0.5, "or_greater") var width: float = 0.0:
	set(value):
		width = maxf(value, 0.0)
		LitLightRegistry.light_state_changed(self)
## Brightness of the glow around the beam, at the beam's edge, as a fraction of
## `energy`. 1 runs the glow straight into the beam (the default); lower values keep the
## beam a crisp bar inside a dimmer halo, so a bright laser does not spread into a wide
## saturated band on a pale floor. The beam itself is `energy`: 1 and above is solid,
## below 1 the floor shows through it. At `width` 0 there is no beam, only the glow.
@export_range(0.0, 1.0, 0.01) var glow: float = 1.0:
	set(value):
		glow = clampf(value, 0.0, 1.0)
		LitLightRegistry.light_state_changed(self)
## Joins the Path2D child's last point back to its first: a ring or a closed loop.
## `close_mode` picks how, from Symmetric (the default, which repeats and balances the
## path's own shapes) through the biarc and curvature arcs to a plain straight edge.
## Nothing without a Path2D child, or on a straight 2-point path.
@export var closed: bool = false:
	set(value):
		closed = value
		_path_dirty = true
		notify_property_list_changed()
		LitLightRegistry.light_state_changed(self)
## How `closed` shapes the join; hover each mode for its method and sources.
@export var close_mode: CloseMode = CloseMode.SYMMETRIC:
	set(value):
		close_mode = value
		_path_dirty = true
		LitLightRegistry.light_state_changed(self)
## Lights the Path2D child's curves as straight segments instead of true arcs: cheaper,
## and it follows the curves less closely. Straight stretches and corners stay as they
## are, and a path with no curve ignores it until a curve returns. Nothing without a
## Path2D child.
@export var tessellate: bool = false:
	set(value):
		tessellate = value
		_path_dirty = true
		notify_property_list_changed()
		LitLightRegistry.light_state_changed(self)
## Total straight segments the path's curves are cut into, by length: smooth points are
## cut across, while corners and straight stretches keep at least one segment between
## them. Fewer is cheaper and follows the curves less closely. The most is 32, less one
## for each straight stretch of the path, or the number of arcs the curves are lit as
## where that is more.
@export_range(2, TESSELLATION_MAX, 1, "prefer_slider") var tessellation_segments: int = 16:
	set(value):
		tessellation_segments = maxi(value, 2)
		if tessellate:
			_path_dirty = true
			LitLightRegistry.light_state_changed(self)

var _path: Path2D
var _path_count := 0
var _path_curve: Curve2D
var _path_xf := Transform2D()
var _path_dirty := true
var _closable := true
# The chain is fitted under the node's basis at fit time (so rotation and uniform scale
# never refit it); _fit_xf maps light-local space to that fit space.
var _fit_xf := Transform2D()
var _fit_inv := Transform2D()
var _chain: LinePathScript.Chain
var _fit_rect := Rect2()
var _path_rect := Rect2()
var _path_corners := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _chords := {}
var _seg := PackedVector2Array()
var _tess_active := false
var _tess_max := TESSELLATION_MAX
var _fit_cache := {}
var _tree: LinePathScript.PathTree
var _tree_space: LinePathScript.PathTreeSpace
var _tree_space_xf := Transform2D()
# The packed path row the registry last built from this light, keyed by its inputs.
var _row := PackedFloat32Array()
var _row_pxf := Transform2D()
var _row_n := -1
var _row_arcs := 0
var _row_dirty := true
var _row_head := Transform2D()
var _row_circle := Vector3.ZERO
var _row_len := 0.0

func _init() -> void:
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)
	child_order_changed.connect(_on_child_order_changed)

func _validate_property(property: Dictionary) -> void:
	if property.name == "shadow_samples" and shadow_algorithm == ShadowAlgorithm.CONE_TRACED:
		return
	if (property.name == "length" and _path != null) or (property.name in ["closed", "close_mode", "tessellate"] and _path == null) \
			or (property.name in ["closed", "close_mode"] and not _closable):
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "close_mode" and not closed:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name == "tessellation_segments":
		if tessellate:
			property.hint_string = "2,%d,1,prefer_slider" % maxi(_tess_max, 2)
		else:
			property.usage &= ~PROPERTY_USAGE_EDITOR
	super(property)

func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path == null:
		return out
	if _path_count > 1:
		out.append("Only the first Path2D child shapes the light; remove the others.")
	_refresh_path()
	if _path.curve == null or _path.curve.point_count < 2:
		out.append("The Path2D child needs a curve with at least 2 points; until then the light is its straight segment.")
	return out

## True while a Path2D child with a curve of at least 2 points shapes the light.
func is_curved() -> bool:
	_refresh_path()
	return _chain != null and _chain.arc_count() > 0

## True while `closed` joins the path (never on a straight 2-point path).
func path_closed() -> bool:
	return closed and _closable

## The fitted arc chain, in fit space (see path_fit_xf).
func path_chain() -> LinePathScript.Chain:
	return _chain

## The chain as a PathTree while it is longer than LinePath.ROW_ARCS arcs (else null).
func path_tree() -> LinePathScript.PathTree:
	if _tree == null and _chain != null and _chain.arc_count() > LinePathScript.ROW_ARCS:
		_tree = LinePathScript.tree(_chain)
	return _tree

## path_tree under `xf` (applied to fit space), kept for the last `xf` asked.
func path_tree_space(xf: Transform2D) -> LinePathScript.PathTreeSpace:
	if path_tree() == null:
		return null
	if _tree_space == null or _tree_space.tree != _tree or xf != _tree_space_xf:
		_tree_space = LinePathScript.tree_space(_tree, xf)
		_tree_space_xf = xf
	return _tree_space

## Light-local space to the chain's fit space.
func path_fit_xf() -> Transform2D:
	return _fit_xf

## The chain's fit space to light-local space.
func path_fit_inv() -> Transform2D:
	return _fit_inv

## True while `tessellate` has replaced the path's curves with straight segments.
func path_tessellated() -> bool:
	_refresh_path()
	return _tess_active

## The most segments `tessellation_segments` uses on the current path.
func path_tessellation_max() -> int:
	_refresh_path()
	return _tess_max

## True while the chain is one straight arc; path_segment holds its ends.
func path_straight() -> bool:
	return not _seg.is_empty()

## The ends of a straight chain in light-local space (empty while it bends).
func path_segment() -> PackedVector2Array:
	return _seg

## Bounds of the chain in fit space.
func path_fit_rect() -> Rect2:
	return _fit_rect

## Bounds of the chain in light-local space.
func path_rect() -> Rect2:
	return _path_rect

## Bounds of the chain under `xf` applied to light-local space.
func path_rect_in(xf: Transform2D) -> Rect2:
	var c := xf * _path_corners
	return Rect2(c[0], Vector2.ZERO).expand(c[1]).expand(c[2]).expand(c[3])

## Half extents of the chain around the node in the node's rotated frame, in world px
## under `xf` (the FIT_RANGE cookie footprint).
func path_extent(xf: Transform2D) -> Vector2:
	var rot := -xf.get_rotation()
	var c := Transform2D(xf.x, xf.y, Vector2.ZERO) * _path_corners
	var e := Vector2.ZERO
	for p in c:
		e = e.max(p.rotated(rot).abs())
	return e

## `n` + 1 fit-space points cutting the chain into `n` chords of equal arc length.
func path_chords(n: int) -> PackedVector2Array:
	if not _chords.has(n):
		_chords[n] = LinePathScript.chords(_chain, n)
	return _chords[n]

## Fit-space points cutting the chain into its shading chords, at most max(`n`, arcs)
## of them (line_path.gd shade_chords).
func path_shade_chords(n: int) -> PackedVector2Array:
	if not _chords.has(-n):
		_chords[-n] = LinePathScript.shade_chords(_chain, n)
	return _chords[-n]

## True while the packed rows memo was built from `m` and `n` on the current chain.
func path_row_same(m: Transform2D, n: int) -> bool:
	return not _row_dirty and n == _row_n and m == _row_pxf

## True while its screen px texels were packed under `pxf`.
func path_row_head_same(pxf: Transform2D) -> bool:
	return pxf == _row_head

## The packed rows memo (light_packer.gd _pack_path), the arc count it packed (-1: a
## tree), and its circle and length in the rows' space.
func path_row() -> PackedFloat32Array:
	return _row

func path_row_arcs() -> int:
	return _row_arcs

func path_row_circle() -> Vector3:
	return _row_circle

func path_row_length() -> float:
	return _row_len

func path_row_store(rows: PackedFloat32Array, m: Transform2D, n: int, arcs: int, pxf: Transform2D,
		circle: Vector3, length: float) -> void:
	_row = rows
	_row_pxf = m
	_row_n = n
	_row_arcs = arcs
	_row_head = pxf
	_row_circle = circle
	_row_len = length
	_row_dirty = false

func _on_child_entered(_node: Node) -> void:
	_find_path(null)

func _on_child_exiting(node: Node) -> void:
	_find_path(node)

func _on_child_order_changed() -> void:
	_find_path(null)

func _find_path(exclude: Node) -> void:
	var found: Path2D = null
	var count := 0
	for c in get_children():
		if c is Path2D and c != exclude:
			count += 1
			if found == null:
				found = c
	if count != _path_count:
		_path_count = count
		update_configuration_warnings()
	if found == _path:
		return
	_path = found
	_path_dirty = true
	if _path == null:
		_unsubscribe()
		_chain = null
		_seg = PackedVector2Array()
		_tess_active = false
		_tree = null
		_tree_space = null
		_fit_cache.clear()
	notify_property_list_changed()
	update_configuration_warnings()
	LitLightRegistry.light_state_changed(self)

func _on_curve_changed() -> void:
	_path_dirty = true
	LitLightRegistry.light_state_changed(self)

func _unsubscribe() -> void:
	if _path_curve != null and _path_curve.changed.is_connected(_on_curve_changed):
		_path_curve.changed.disconnect(_on_curve_changed)
	_path_curve = null

func _refresh_path() -> void:
	if _path == null:
		return
	var curve := _path.curve
	if curve != _path_curve:
		_unsubscribe()
		_path_curve = curve
		if curve != null:
			curve.changed.connect(_on_curve_changed)
		_path_dirty = true
	if _path.transform != _path_xf:
		_path_xf = _path.transform
		_path_dirty = true
	var basis := global_transform
	basis.origin = Vector2.ZERO
	if not _path_dirty and not _similar(basis * _fit_inv):
		_path_dirty = true
	if not _path_dirty:
		return
	_path_dirty = false
	_fit_xf = basis if absf(basis.determinant()) > 1e-8 else Transform2D()
	_fit_inv = _fit_xf.affine_inverse()
	var closable := not LinePathScript.straight_pair(curve, _fit_xf * _path_xf)
	if closable != _closable:
		_closable = closable
		notify_property_list_changed()
	_chain = LinePathScript.fit(curve, path_closed(), _fit_xf * _path_xf, _fit_cache, close_mode)
	_tree = null
	_tree_space = null
	_tess_active = false
	if tessellate:
		var curved := 0
		var bending := 0
		var straight := 0
		for r in LinePathScript.runs(_chain):
			if r[2]:
				curved += r[1] - r[0]
				bending += 1
			else:
				straight += 1
		var most := maxi(maxi(TESSELLATION_MAX - straight, curved), bending)
		if most != _tess_max:
			_tess_max = most
			notify_property_list_changed()
		if bending > 0:
			_tess_active = true
			_chain = LinePathScript.tessellated(_chain, mini(tessellation_segments, most))
	_chords.clear()
	_seg = PackedVector2Array()
	# Straight: the arc's sagitta under a tenth of the fit tolerance.
	if _chain.arc_count() == 1 and absf(_chain.bulges[0]) * _chain.points[0].distance_to(_chain.points[1]) \
			< 0.2 * LinePathScript.TOLERANCE:
		_seg = _fit_inv * _chain.points
	_row_dirty = true
	_fit_rect = LinePathScript.bounds(_chain)
	_path_rect = _rect_in(_fit_rect, _fit_inv)
	_path_corners = PackedVector2Array(_corners(_path_rect))
	update_configuration_warnings()
	LitLightRegistry.light_state_changed(self)

static func _similar(q: Transform2D) -> bool:
	var xx := q.x.length_squared()
	var yy := q.y.length_squared()
	var s := maxf(xx, yy)
	return s > 0.0 and absf(xx - yy) <= 1e-3 * s and absf(q.x.dot(q.y)) <= 1e-3 * s

static func _corners(r: Rect2) -> Array[Vector2]:
	return [r.position, r.end, Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.position.y)]

static func _rect_in(r: Rect2, xf: Transform2D) -> Rect2:
	var out := Rect2(xf * r.position, Vector2.ZERO)
	for c in _corners(r):
		out = out.expand(xf * c)
	return out
