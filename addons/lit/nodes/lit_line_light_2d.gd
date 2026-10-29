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
## `closed` joins the curve's ends into a loop. The curve is lit as true arcs, up to 32
## of them, each straight stretch as one piece and the bends as up to 32 chords; Cone
## Traced and Stochastic shadows march it as `shadow_samples` chords of equal length.
## Everything else is inherited from LitPositionalLight2D and LitLight2D.

const LinePathScript := preload("res://addons/lit/runtime/registry/line_path.gd")

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
## Joins the Path2D child's last point back to its first with an arc that matches both
## tangents: a ring or a closed loop. Nothing without a Path2D child.
@export var closed: bool = false:
	set(value):
		closed = value
		_path_dirty = true
		LitLightRegistry.light_state_changed(self)

var _path: Path2D
var _path_curve: Curve2D
var _path_xf := Transform2D()
var _path_dirty := true
# The chain is fitted under the node's basis at fit time (so rotation and uniform scale
# never refit it); _fit_xf maps light-local space to that fit space.
var _fit_xf := Transform2D()
var _fit_inv := Transform2D()
var _chain: LinePathScript.Chain
var _fit_rect := Rect2()
var _path_rect := Rect2()
var _path_corners := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _chords := {}
# The packed path row the registry last built from this light, keyed by its inputs.
var _row := PackedFloat32Array()
var _row_pxf := Transform2D()
var _row_n := -1
var _row_arcs := 0
var _row_dirty := true

func _init() -> void:
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)
	child_order_changed.connect(_on_child_order_changed)

func _validate_property(property: Dictionary) -> void:
	if property.name == "shadow_samples" and shadow_algorithm == ShadowAlgorithm.CONE_TRACED:
		return
	if (property.name == "length" and _path != null) or (property.name == "closed" and _path == null):
		property.usage |= PROPERTY_USAGE_READ_ONLY
	super(property)

func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path == null:
		return out
	_refresh_path()
	if _path.curve == null or _path.curve.point_count < 2:
		out.append("The Path2D child needs a curve with at least 2 points; until then the light is its straight segment.")
	elif _chain != null and _chain.truncated:
		out.append("The path needs more than %d arcs; only the first %d light. Simplify the curve." % [LinePathScript.MAX_ARCS, LinePathScript.MAX_ARCS])
	return out

## True while a Path2D child with a curve of at least 2 points shapes the light.
func is_curved() -> bool:
	_refresh_path()
	return _chain != null and _chain.arc_count() > 0

## The fitted arc chain, in fit space (see path_fit_xf).
func path_chain() -> LinePathScript.Chain:
	return _chain

## Light-local space to the chain's fit space.
func path_fit_xf() -> Transform2D:
	return _fit_xf

## The chain's fit space to light-local space.
func path_fit_inv() -> Transform2D:
	return _fit_inv

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

## True while the packed row memo was built from `pxf` and `n` on the current chain.
func path_row_same(pxf: Transform2D, n: int) -> bool:
	return not _row_dirty and n == _row_n and pxf == _row_pxf

## The packed row memo (light_packer.gd _pack_path) and the arc count it packed.
func path_row() -> PackedFloat32Array:
	return _row

func path_row_arcs() -> int:
	return _row_arcs

func path_row_store(row: PackedFloat32Array, pxf: Transform2D, n: int, arcs: int) -> void:
	_row = row
	_row_pxf = pxf
	_row_n = n
	_row_arcs = arcs
	_row_dirty = false

func _on_child_entered(_node: Node) -> void:
	_find_path(null)

func _on_child_exiting(node: Node) -> void:
	_find_path(node)

func _on_child_order_changed() -> void:
	_find_path(null)

func _find_path(exclude: Node) -> void:
	var found: Path2D = null
	for c in get_children():
		if c is Path2D and c != exclude:
			found = c
			break
	if found == _path:
		return
	_path = found
	_path_dirty = true
	if _path == null:
		_unsubscribe()
		_chain = null
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
	_chain = LinePathScript.fit(curve, closed, _fit_xf * _path_xf)
	_chords.clear()
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
