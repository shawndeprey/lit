extends RefCounted

## Per-frame data spine: view data computed once in begin(), frame state written by
## exactly one owner each and passed to modules explicitly. Reused across frames,
## never reallocated. LitLightRegistry.activity_flags stays the node-facing surface
## (published once per refresh); this object carries the internal frame plumbing.

# View data, computed once per begin().
var canvas_xform: Transform2D
var canvas_scale: float
var vp_size: Vector2
var world_rect: Rect2

# Light set for the frame: view-culled, then reordered directionals-first (the row
# order the data texture and tile buckets share).
var visible: Array = []
var positional: Array = []
var dir_count := 0

# One writer each: facade widens texels_per_light (sticky) and derives excl_active;
# rx_registry computes rx_union; occluder_tiles fills the occ_* frame outputs.
var excl_active := false
var texels_per_light := 9
var rx_union := 0
var occ_rects: Array[Rect2] = []
var occ_masks := PackedInt32Array()
var occ_owners := PackedInt32Array()


## False when the frame should be skipped (no tree/viewport or an empty view).
func begin(tree: SceneTree, viewport: Viewport) -> bool:
	if tree == null or viewport == null:
		return false
	vp_size = viewport.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return false

	# World-to-screen-pixel transform. A Viewport applies global_canvas_transform *
	# canvas_transform to its canvas items, so we need the product, not just
	# canvas_transform. At runtime the global part is identity and the camera lives in
	# canvas_transform; in the editor the view's pan/zoom lives in global_canvas_transform,
	# so canvas_transform alone mis-places lights and drifts them with zoom. The product
	# is correct in both, and feeds positions, the directional/spot basis, and the cull
	# rect alike.
	canvas_xform = viewport.get_global_canvas_transform() * viewport.get_canvas_transform()
	world_rect = _visible_world_rect(canvas_xform, vp_size)

	# World-to-screen pixel scale (camera/editor zoom). The shader does point/spot lighting
	# in screen pixels, so it multiplies each light's world-space range and height by this
	# to keep the math identical at any zoom. maxf of the basis axes matches the tiling
	# scale below, so the shader's effective range never exceeds the tiled footprint (a
	# smaller shader scale would just under-light; a larger one would cull lit tiles).
	canvas_scale = maxf(canvas_xform.x.length(), canvas_xform.y.length())
	return true


## Visible screen rect transformed into world space.
func _visible_world_rect(xform: Transform2D, size: Vector2) -> Rect2:
	var inv := xform.affine_inverse()
	var rect := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	rect = rect.expand(inv * Vector2(size.x, 0.0))
	rect = rect.expand(inv * Vector2(0.0, size.y))
	rect = rect.expand(inv * size)
	return rect
