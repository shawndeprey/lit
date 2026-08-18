extends RefCounted

## CPU-side luminance sampling: how much Lit light reaches a world point.
##
## Mirrors the receiver shader's compositing - ambient, distance falloff, spot cones,
## cookies, masks, shadow tint - with a geometric segment-vs-occluder test standing in
## for the GPU SDF march, so the scalar tracks what's rendered without any readback.
## Penumbras are not modeled: a point is either in an occluder's shadow path or clear
## of it.

# Decompressed cookie images, keyed by texture; never invalidated (cookie art is
# static in practice).
var _cookie_imgs := {}


## Luminance at `world_pos`: ambient plus every mask-matching light's contribution.
## `lights` is the culled light list; `occ_nodes` / `occ_layers` are the occluder
## caches from occluder_tiles. `self_source` mirrors the receivers' self-shadow
## exemption: occluders in its subtree or among its direct siblings cast no shadow
## on the sample (their shadows render behind the sprite, not onto it).
func sample(tree: SceneTree, lights: Array, occ_nodes: Array, occ_layers: Array,
		world_pos: Vector2, receiver_mask: int, rx_mask: int,
		self_source: Node = null) -> float:
	var lum := _ambient(tree)
	for light in lights:
		if (int(light.light_mask) & receiver_mask) == 0:
			continue
		if light is LitDirectionalLight2D:
			lum += _directional(light, world_pos, occ_nodes, occ_layers, rx_mask, self_source)
		else:
			lum += _positional(light, world_pos, occ_nodes, occ_layers, rx_mask, self_source)
	return maxf(lum, 0.0)


# Matches the shader's ambient base; without a LitCanvasModulate the globals default
# to white at energy 1 (a scene with no darkness source renders fully lit).
func _ambient(tree: SceneTree) -> float:
	var mods := tree.get_nodes_in_group(LitCanvasModulate.GROUP)
	for i in range(mods.size() - 1, -1, -1):
		var cm = mods[i]
		if is_instance_valid(cm) and cm.is_inside_tree():
			return cm.color.get_luminance() * cm.ambient_energy
	return 1.0


func _directional(light: LitDirectionalLight2D, pos: Vector2,
		occ_nodes: Array, occ_layers: Array, rx_mask: int, self_source: Node) -> float:
	var color := light.color
	if light.shadow_enabled and light.shadow_length > 0.0:
		var toward := -Vector2.from_angle(light.global_rotation)
		var reach := maxf(light.shadow_reach, 0.0) * clampf(light.shadow_length, 0.0, 1.0)
		if _occluded(pos, pos + toward * reach, light, occ_nodes, occ_layers, rx_mask, self_source):
			color *= light.shadow_color
	var lum: float = light.energy * color.get_luminance()
	return -lum if light.blend_mode == LitShaderLibrary.BlendMode.SUBTRACT else lum


# Point and spot share the radial path, exactly like the shader. `light` is accessed
# dynamically: the shared properties live on both LitPointLight2D and LitSpotLight2D.
func _positional(light, pos: Vector2,
		occ_nodes: Array, occ_layers: Array, rx_mask: int, self_source: Node) -> float:
	var to_light: Vector2 = light.global_position - pos
	var dist := to_light.length()
	var range_px: float = light.range
	if range_px <= 0.0 or dist > range_px:
		return 0.0
	var factor: float = light.energy * pow(clampf(1.0 - dist / range_px, 0.0, 1.0), light.falloff)

	if light is LitSpotLight2D:
		var cos_outer := cos(deg_to_rad(light.spot_angle))
		var cos_inner := cos(deg_to_rad(light.spot_angle * (1.0 - light.spot_softness)))
		if cos_inner <= cos_outer:
			cos_inner = cos_outer + 0.0001
		var aim := Vector2.from_angle(light.global_rotation)
		var dir_to_frag := -to_light / dist if dist > 0.0001 else aim
		factor *= smoothstep(cos_outer, cos_inner, aim.dot(dir_to_frag))
	if factor <= 0.0:
		return 0.0

	var ck := _cookie(light, -to_light)
	var color := Color(light.color.r * ck.r, light.color.g * ck.g, light.color.b * ck.b) * ck.a
	if color.get_luminance() <= 0.0:
		return 0.0

	if light.shadow_enabled and dist > 0.0001:
		var cap := dist * clampf(light.shadow_length, 0.01, 1.0)
		if _occluded(pos, pos + (to_light / dist) * cap, light, occ_nodes, occ_layers,
				rx_mask, self_source):
			color *= light.shadow_color
	var lum: float = factor * color.get_luminance()
	return -lum if light.blend_mode == LitShaderLibrary.BlendMode.SUBTRACT else lum


## Cookie modulation at `world_offset` from the light's center: WHITE when the light
## has no readable cookie, TRANSPARENT outside the footprint (the cookie masks the
## light to zero there).
func _cookie(light, world_offset: Vector2) -> Color:
	var tex: Texture2D = light.texture
	if tex == null:
		return Color.WHITE
	var half: Vector2
	var local: Vector2
	if int(light.texture_size_mode) == LitShaderLibrary.TextureSizeMode.FIT_RANGE:
		half = Vector2(light.range, light.range) * light.texture_scale
		local = world_offset.rotated(-light.global_rotation)
	else:
		half = Vector2(tex.get_size()) * 0.5 * light.texture_scale
		var xf: Transform2D = light.get_global_transform()
		var basis := Transform2D(xf.x, xf.y, Vector2.ZERO)
		if absf(basis.determinant()) < 1e-8:
			return Color.WHITE
		local = basis.affine_inverse() * world_offset
	if half.x <= 0.0 or half.y <= 0.0:
		return Color.WHITE
	var sx := 0.5 / half.x
	var sy := 0.5 / half.y
	var off: Vector2 = light.texture_offset
	var uv := Vector2(0.5 - off.x * sx + local.x * sx, 0.5 - off.y * sy + local.y * sy)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return Color.TRANSPARENT
	var img := _cookie_image(tex)
	if img == null:
		return Color.WHITE
	var size := img.get_size()
	var px := Vector2i((uv * Vector2(size)).floor()).clamp(Vector2i.ZERO, size - Vector2i.ONE)
	return img.get_pixelv(px)


func _cookie_image(tex: Texture2D) -> Image:
	if _cookie_imgs.has(tex):
		return _cookie_imgs[tex]
	var img := tex.get_image()
	if img != null and img.is_compressed() and img.decompress() != OK:
		img = null
	_cookie_imgs[tex] = img
	return img


## True when a shadow-casting occluder crosses the segment. Honors the light's
## shadow_mask, exclude_scene_occluders and the receiver's shadow_ignore_mask with
## the same effective-layer algebra as the shader.
func _occluded(seg_from: Vector2, seg_to: Vector2, light,
		occ_nodes: Array, occ_layers: Array, rx_mask: int, self_source: Node) -> bool:
	var smask: int = light.shadow_mask
	if smask == 0:
		return false
	if rx_mask != 0 and (smask & ~rx_mask) == 0:
		return false
	var scope: Node = null
	if light.exclude_scene_occluders:
		scope = light.owner if light.owner != null else light.get_parent()

	for entry in occ_nodes:
		var occ = entry[0]
		if not is_instance_valid(occ):
			continue
		if not occ.sdf_collision or occ.occluder == null or occ.occluder.polygon.is_empty():
			continue
		if not occ.is_inside_tree() or not occ.is_visible_in_tree():
			continue
		var m: int = occ.occluder_light_mask
		if (m & smask) == 0 or (m & smask & rx_mask) != 0:
			continue
		if scope != null and (occ == scope or scope.is_ancestor_of(occ)):
			continue
		# Same "own occluders" set LitSprite2D exempts: descendants and direct siblings.
		if self_source != null and (self_source.is_ancestor_of(occ)
				or occ.get_parent() == self_source.get_parent()):
			continue
		var inv: Transform2D = occ.global_transform.affine_inverse()
		if _segment_hits_polygon(inv * seg_from, inv * seg_to,
				occ.occluder.polygon, occ.occluder.closed):
			return true

	# Tilemap cells test against their cached cell-strip rects; exact for the usual
	# full-cell occluders, a bounding box for partial-cell shapes.
	for entry in occ_layers:
		var layer = entry[0]
		if not is_instance_valid(layer) or not layer.is_inside_tree() \
				or not layer.is_visible_in_tree():
			continue
		if scope != null and (layer == scope or scope.is_ancestor_of(layer)):
			continue
		var rects: Array = entry[1]
		var masks: PackedInt32Array = entry[4]
		var inv: Transform2D = layer.global_transform.affine_inverse()
		var a := inv * seg_from
		var b := inv * seg_to
		var seg_rect := Rect2(a, Vector2.ZERO).expand(b)
		for i in rects.size():
			var m := masks[i]
			if (m & smask) == 0 or (m & smask & rx_mask) != 0:
				continue
			var r: Rect2 = rects[i]
			if r.intersects(seg_rect) and _segment_hits_rect(a, b, r):
				return true
	return false


static func _segment_hits_polygon(a: Vector2, b: Vector2, poly: PackedVector2Array,
		closed: bool) -> bool:
	var n := poly.size()
	if n < 2:
		return false
	var edges := n if closed and n > 2 else n - 1
	for i in edges:
		if Geometry2D.segment_intersects_segment(a, b, poly[i], poly[(i + 1) % n]) != null:
			return true
	return false


static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	if r.has_point(a) or r.has_point(b):
		return true
	var d := b - a
	var tmin := 0.0
	var tmax := 1.0
	for axis in 2:
		if absf(d[axis]) < 1e-9:
			if a[axis] < r.position[axis] or a[axis] > r.end[axis]:
				return false
		else:
			var t1: float = (r.position[axis] - a[axis]) / d[axis]
			var t2: float = (r.end[axis] - a[axis]) / d[axis]
			tmin = maxf(tmin, minf(t1, t2))
			tmax = minf(tmax, maxf(t1, t2))
			if tmin > tmax:
				return false
	return true
