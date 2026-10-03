extends RefCounted

## CPU-side luminance sampling: how lit a matte receiver is at a world point.
##
## Mirrors the receiver shader's compositing - ambient, distance falloff, N.L against
## the light's elevation, spot cones, cookies, masks, shadow tint, the lighting model's
## diffuse share - with a geometric segment-vs-occluder test standing in for the GPU SDF
## march, so the scalar tracks what's rendered without any readback. The surface is one
## flat point unless a receiver passes its own (surface()): the frame it draws,
## summarised, giving the mean over its pixels. Penumbras are not modeled: a point is
## either in an occluder's shadow path or clear of it. Specular is not sampled.

# Surface summaries. Shading goes through lobes: one per occupied (frame cell, normal
# bin) pair, the frame split CELLS x CELLS and normal.xy BINS x BINS; a lobe carries its
# texels' summed normal (as a share of the surface) and their mean position, so a near
# light weighs the part of the sprite that faces it. The sharp-edged terms (spot cone,
# cookie, shadow) average over mask points instead, SUB x SUB per frame cell.
const PROFILE_CELLS := 3
const PROFILE_BINS := 8
const PROFILE_SUB := 2
# Texels read per axis when summarising; larger frames are stride-sampled.
const PROFILE_MAX_AXIS := 32

# Indices into the surface a sample runs on (world space). A cached profile holds the
# first six in frame-local texels, then the frame's reach (its farthest texel offset).
enum { S_NORMALS, S_POINTS, S_CELLS, S_MASK_POINTS, S_MASK_WEIGHTS, S_MASK_CELLS,
		S_CENTER, S_REACH, S_CELL_COUNT }
const P_REACH := 6

# Decompressed cookie images, keyed by texture; never invalidated (cookie art is
# static in practice).
var _cookie_imgs := {}
# [normal texture id, diffuse texture id, source rect] -> profile; never invalidated
# either.
var _profiles := {}


## Luminance at `world_pos`: ambient plus every mask-matching light's contribution.
## `lights` is the culled light list; `occ_nodes` / `occ_layers` are the occluder
## caches from occluder_tiles. `self_source` mirrors the receivers' self-shadow
## exemption: occluders in its subtree or among its direct siblings cast no shadow
## on the sample (their shadows render behind the sprite, not onto it). `dir_scale` is
## the receiver's directional_horizontal_scale; `pbr` the active lighting model;
## `surface` a receiver's surface() (empty: one flat point at `world_pos`).
func sample(tree: SceneTree, lights: Array, occ_nodes: Array, occ_layers: Array,
		world_pos: Vector2, receiver_mask: int, rx_mask: int,
		self_source: Node = null, dir_scale: float = 32.0, pbr: bool = false,
		surface: Array = []) -> float:
	var surf: Array
	if surface.is_empty():
		var point := PackedVector2Array([world_pos])
		var cell := PackedInt32Array([0])
		surf = [PackedVector3Array([Vector3(0.0, 0.0, 1.0)]), point, cell, point,
				PackedFloat32Array([1.0]), cell, world_pos, 0.0, 1]
	else:
		var profile: Array = surface[0]
		var to_world: Transform2D = surface[1]
		var tx := to_world.x.normalized()
		var ty := to_world.y.normalized()
		var local: PackedVector3Array = profile[S_NORMALS]
		var normals := PackedVector3Array()
		normals.resize(local.size())
		for i in local.size():
			var n := local[i]
			# The shader renormalizes after the turn (skew): the lobe keeps its weight.
			var v := Vector3(tx.x * n.x + ty.x * n.y, tx.y * n.x + ty.y * n.y, n.z)
			var turned := v.length()
			normals[i] = v * (n.length() / turned) if turned > 0.0 else v
		surf = [normals, to_world * (profile[S_POINTS] as PackedVector2Array), profile[S_CELLS],
				to_world * (profile[S_MASK_POINTS] as PackedVector2Array),
				profile[S_MASK_WEIGHTS], profile[S_MASK_CELLS], to_world.origin,
				float(profile[P_REACH]) * maxf(to_world.x.length(), to_world.y.length()),
				PROFILE_CELLS * PROFILE_CELLS]

	var lum := _ambient(tree)
	for light in lights:
		if (int(light.light_mask) & receiver_mask) == 0:
			continue
		if light is LitDirectionalLight2D:
			lum += _directional(light, occ_nodes, occ_layers, rx_mask, self_source,
					dir_scale, pbr, surf)
		else:
			lum += _positional(light, world_pos, occ_nodes, occ_layers, rx_mask, self_source,
					pbr, surf)
	return maxf(lum, 0.0)


## A receiver's drawn surface for sample(): `texture` over `src` (the diffuse-texel rect
## it draws) summarised, with `to_world` taking texel offsets from that rect's centre
## into the world. Empty without a texture.
func surface(texture: Texture2D, src: Rect2, to_world: Transform2D) -> Array:
	if texture == null:
		return []
	var diffuse := texture
	var normal: Texture2D = null
	var ct := texture as CanvasTexture
	if ct != null:
		diffuse = ct.diffuse_texture
		normal = ct.normal_texture
	var key := [normal.get_instance_id() if normal != null else 0,
			diffuse.get_instance_id() if diffuse != null else 0, src]
	var profile = _profiles.get(key)
	if profile == null:
		profile = _build_profile(diffuse, normal, Vector2(texture.get_size()), src)
		_profiles[key] = profile
	if profile.is_empty():
		return []
	return [profile, to_world]


# Texels weigh by diffuse alpha; without a readable normal map every normal faces out.
func _build_profile(diffuse: Texture2D, normal: Texture2D, full: Vector2, src: Rect2) -> Array:
	var diffuse_img := _readable_image(diffuse)
	var normal_img := _readable_image(normal)
	if full.x <= 0.0 or full.y <= 0.0:
		return []
	if not src.has_area():
		src = Rect2(Vector2.ZERO, full)
	var diffuse_scale := Vector2(diffuse_img.get_size()) / full if diffuse_img != null else Vector2.ONE
	var normal_scale := Vector2(normal_img.get_size()) / full if normal_img != null else Vector2.ONE
	var cols := clampi(int(ceil(src.size.x)), 1, PROFILE_MAX_AXIS)
	var rows := clampi(int(ceil(src.size.y)), 1, PROFILE_MAX_AXIS)
	var center := src.get_center()
	var fine := PROFILE_CELLS * PROFILE_SUB

	var lobes := {}                  # lobe key -> [summed normal, summed offset, weight]
	var masks := {}                  # mask point key -> [weight, cell, column, row]
	var cell_weights := PackedFloat32Array()
	cell_weights.resize(PROFILE_CELLS * PROFILE_CELLS)
	var total := 0.0
	var reach := 0.0
	for j in rows:
		for i in cols:
			# One texel per grid cell. A stride-sampled frame takes a scattered texel
			# from each, so a regular pattern in the art cannot alias with the stride.
			var h := (i * 73856093) ^ (j * 19349663)
			var u := Vector2((i + ((h & 1023) + 0.5) / 1024.0) / cols,
					(j + (((h >> 10) & 1023) + 0.5) / 1024.0) / rows)
			var at := (src.position + u * src.size).floor() + Vector2(0.5, 0.5)
			var offset := at - center
			var weight := 1.0
			if diffuse_img != null:
				weight = diffuse_img.get_pixelv(_texel(at * diffuse_scale, diffuse_img)).a
				if weight <= 0.0:
					continue
			var n := Vector3(0.0, 0.0, 1.0)
			if normal_img != null:
				# Godot's canvas decode: green is up, so screen y is flipped.
				var c := normal_img.get_pixelv(_texel(at * normal_scale, normal_img))
				n = Vector3(c.r * 2.0 - 1.0, 1.0 - c.g * 2.0, 0.0)
				n.z = sqrt(maxf(0.0, 1.0 - n.x * n.x - n.y * n.y))
				n = n.normalized()
			var fx := mini(int(u.x * fine), fine - 1)
			var fy := mini(int(u.y * fine), fine - 1)
			var cell := mini(int(u.x * PROFILE_CELLS), PROFILE_CELLS - 1) * PROFILE_CELLS \
					+ mini(int(u.y * PROFILE_CELLS), PROFILE_CELLS - 1)
			var key := cell * PROFILE_BINS + clampi(int((n.x * 0.5 + 0.5) * PROFILE_BINS), 0, PROFILE_BINS - 1)
			key = key * PROFILE_BINS + clampi(int((n.y * 0.5 + 0.5) * PROFILE_BINS), 0, PROFILE_BINS - 1)
			var lobe = lobes.get(key)
			if lobe == null:
				lobe = [Vector3.ZERO, Vector2.ZERO, 0.0, cell]
				lobes[key] = lobe
			lobe[0] += n * weight
			lobe[1] += offset * weight
			lobe[2] += weight
			var mask = masks.get(fx * fine + fy)
			if mask == null:
				mask = [0.0, cell, fx, fy]
				masks[fx * fine + fy] = mask
			mask[0] += weight
			cell_weights[cell] += weight
			total += weight
			reach = maxf(reach, offset.length())
	if total <= 0.0:
		return []
	var normals := PackedVector3Array()
	var offsets := PackedVector2Array()
	var cells := PackedInt32Array()
	for key in lobes:
		var lobe: Array = lobes[key]
		normals.append(lobe[0] / total)
		offsets.append(lobe[1] / lobe[2])
		cells.append(lobe[3])
	var mask_offsets := PackedVector2Array()
	var mask_weights := PackedFloat32Array()
	var mask_cells := PackedInt32Array()
	for key in masks:
		var mask: Array = masks[key]
		# Staggered inside its sub-cell by the other axis' index, so no two mask points
		# share a row or a column: a straight edge is resolved fine x fine times, not fine.
		var at := Vector2((mask[2] + (mask[3] + 0.5) / fine) / fine,
				(mask[3] + (mask[2] + 0.5) / fine) / fine)
		mask_offsets.append((at - Vector2(0.5, 0.5)) * src.size)
		mask_weights.append(mask[0] / cell_weights[mask[1]])
		mask_cells.append(mask[1])
	return [normals, offsets, cells, mask_offsets, mask_weights, mask_cells, reach]


static func _texel(at: Vector2, img: Image) -> Vector2i:
	return Vector2i(at.floor()).clamp(Vector2i.ZERO, img.get_size() - Vector2i.ONE)


static func _readable_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img != null and img.is_compressed() and img.decompress() != OK:
		return null
	return img


# The dielectric diffuse share PBR leaves after Fresnel, for a light direction with
# elevation component `lz`: V.H = sqrt((1 + lz) / 2) against the fixed view.
static func _pbr_diffuse(lz: float) -> float:
	return 0.96 * (1.0 - pow(1.0 - sqrt((1.0 + lz) * 0.5), 5.0))


# Matches the shader's ambient base; without a LitCanvasModulate the globals default
# to white at energy 1 (a scene with no darkness source renders fully lit).
func _ambient(tree: SceneTree) -> float:
	var mods := tree.get_nodes_in_group(LitCanvasModulate.GROUP)
	for i in range(mods.size() - 1, -1, -1):
		var cm = mods[i]
		if is_instance_valid(cm) and cm.is_inside_tree():
			return cm.color.get_luminance() * cm.ambient_energy
	return 1.0


func _directional(light: LitDirectionalLight2D,
		occ_nodes: Array, occ_layers: Array, rx_mask: int, self_source: Node,
		dir_scale: float, pbr: bool, surf: Array) -> float:
	var toward := -Vector2.from_angle(light.global_rotation)
	var ldir := Vector3(toward.x * dir_scale, toward.y * dir_scale,
			maxf(light.height, 0.0)).normalized()
	var normals: PackedVector3Array = surf[S_NORMALS]
	var casters: Array = []
	var march := toward * (maxf(light.shadow_reach, 0.0) * clampf(light.shadow_length, 0.0, 1.0))
	if light.shadow_enabled and light.shadow_length > 0.0:
		var center: Vector2 = surf[S_CENTER]
		casters = _casters(light, center, center + march, surf[S_REACH], occ_nodes, occ_layers,
				rx_mask, self_source)

	var lit := Color(0.0, 0.0, 0.0)
	if casters.is_empty():
		var share := 0.0
		for n in normals:
			share += maxf(n.dot(ldir), 0.0)
		lit = Color(share, share, share)
	else:
		var cell_mask := _shadow_masks(surf, casters, light.shadow_color, march)
		var cells: PackedInt32Array = surf[S_CELLS]
		for i in normals.size():
			lit += cell_mask[cells[i]] * maxf(normals[i].dot(ldir), 0.0)
	var color := Color(light.color.r * lit.r, light.color.g * lit.g, light.color.b * lit.b)
	var lum: float = light.energy * color.get_luminance()
	if pbr:
		lum *= _pbr_diffuse(ldir.z)
	return -lum if light.blend_mode == LitShaderLibrary.BlendMode.SUBTRACT else lum


# Per frame cell, the share of each colour channel a directional light's shadows let
# through: every mask point marches `march`.
func _shadow_masks(surf: Array, casters: Array, shadow_color: Color,
		march: Vector2) -> Array[Color]:
	var cell_mask: Array[Color] = []
	cell_mask.resize(surf[S_CELL_COUNT])
	cell_mask.fill(Color(0.0, 0.0, 0.0))
	var mask_points: PackedVector2Array = surf[S_MASK_POINTS]
	var mask_weights: PackedFloat32Array = surf[S_MASK_WEIGHTS]
	var mask_cells: PackedInt32Array = surf[S_MASK_CELLS]
	for k in mask_points.size():
		var p := mask_points[k]
		cell_mask[mask_cells[k]] += (shadow_color if _blocked(p, p + march, casters) else Color.WHITE) \
				* mask_weights[k]
	return cell_mask


# Point and spot share the radial path, exactly like the shader. `light` is accessed
# dynamically: the shared properties live on both LitPointLight2D and LitSpotLight2D.
# Falloff and N.L go per lobe; cone, cookie and shadow per mask point.
func _positional(light, pos: Vector2,
		occ_nodes: Array, occ_layers: Array, rx_mask: int, self_source: Node,
		pbr: bool, surf: Array) -> float:
	var xf: Transform2D = light.global_transform
	var s := maxf(xf.x.length(), xf.y.length())
	if absf(s - 1.0) < 1e-5:
		s = 1.0
	var range_px: float = light.range * s
	var energy: float = light.energy
	if range_px <= 0.0 or energy <= 0.0 or xf.origin.distance_to(pos) > range_px:
		return 0.0
	# Height is world px and, unlike range, not scaled by the node.
	var height := maxf(light.height, 0.0)
	var falloff: float = light.falloff
	var spot := light is LitSpotLight2D
	var cos_outer := 0.0
	var cos_inner := 0.0
	var aim := Vector2.ZERO
	if spot:
		cos_outer = cos(deg_to_rad(light.spot_angle))
		cos_inner = cos(deg_to_rad(light.spot_angle * (1.0 - light.spot_softness)))
		if cos_inner <= cos_outer:
			cos_inner = cos_outer + 0.0001
		aim = Vector2.from_angle(light.global_rotation)

	var textured: bool = light.texture != null
	var casters: Array = []
	if light.shadow_enabled:
		casters = _casters(light, surf[S_CENTER], xf.origin, surf[S_REACH], occ_nodes, occ_layers,
				rx_mask, self_source)
	var masked := spot or textured or not casters.is_empty()
	var cell_mask: Array[Color] = []
	if masked:
		cell_mask.resize(surf[S_CELL_COUNT])
		cell_mask.fill(Color(0.0, 0.0, 0.0))
		var mask_points: PackedVector2Array = surf[S_MASK_POINTS]
		var mask_weights: PackedFloat32Array = surf[S_MASK_WEIGHTS]
		var mask_cells: PackedInt32Array = surf[S_MASK_CELLS]
		var shadow_color: Color = light.shadow_color
		var cap := clampf(light.shadow_length, 0.01, 1.0)
		for k in mask_points.size():
			var p := mask_points[k]
			var tl: Vector2 = xf.origin - p
			var d := tl.length()
			var m := Color.WHITE
			if spot and d > 0.0001:
				var cone := smoothstep(cos_outer, cos_inner, aim.dot(-tl / d))
				m = Color(cone, cone, cone)
			if textured:
				var ck := _cookie(light, -tl, xf, range_px)
				m = Color(m.r * ck.r, m.g * ck.g, m.b * ck.b) * ck.a
			if d > 0.0001 and not casters.is_empty() and _blocked(p, p + tl * cap, casters):
				m = Color(m.r * shadow_color.r, m.g * shadow_color.g, m.b * shadow_color.b)
			cell_mask[mask_cells[k]] += m * mask_weights[k]

	var normals: PackedVector3Array = surf[S_NORMALS]
	var points: PackedVector2Array = surf[S_POINTS]
	var cells: PackedInt32Array = surf[S_CELLS]
	var lit := Color(0.0, 0.0, 0.0)
	var factor := 0.0
	for i in normals.size():
		var tl: Vector2 = xf.origin - points[i]
		var d := tl.length()
		if d > range_px:
			continue
		var slant := sqrt(d * d + height * height)
		if slant <= 0.0:
			continue
		var n := normals[i]
		var ndotl := (n.x * tl.x + n.y * tl.y + n.z * height) / slant
		if ndotl <= 0.0:
			continue
		var f := pow(1.0 - d / range_px, falloff) * ndotl
		if pbr:
			f *= _pbr_diffuse(height / slant)
		if masked:
			lit += cell_mask[cells[i]] * f
		else:
			factor += f
	if not masked:
		lit = Color(factor, factor, factor)
	var color := Color(light.color.r * lit.r, light.color.g * lit.g, light.color.b * lit.b)
	var lum: float = energy * color.get_luminance()
	return -lum if light.blend_mode == LitShaderLibrary.BlendMode.SUBTRACT else lum


## Cookie modulation at `world_offset` from the light's center: WHITE when the light
## has no readable cookie, TRANSPARENT outside the footprint (the cookie masks the
## light to zero there).
func _cookie(light, world_offset: Vector2, xf: Transform2D, range_px: float) -> Color:
	var tex: Texture2D = light.texture
	if tex == null:
		return Color.WHITE
	var half: Vector2
	var local: Vector2
	if int(light.texture_size_mode) == LitShaderLibrary.TextureSizeMode.FIT_RANGE:
		half = Vector2(range_px, range_px) * light.texture_scale
		local = world_offset.rotated(-light.global_rotation)
	else:
		half = Vector2(tex.get_size()) * 0.5 * light.texture_scale
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


## The occluders that can shadow a surface from `light`: those passing the light's
## shadow_mask, exclude_scene_occluders and the receiver's shadow_ignore_mask (the same
## effective-layer algebra as the shader), and lying within `reach` of the segment from
## the surface's centre `from` to `to`. Entries are [inverse transform, polygon, closed]
## for loose occluders and [inverse transform, rects] for tilemap layers.
func _casters(light, from: Vector2, to: Vector2, reach: float,
		occ_nodes: Array, occ_layers: Array, rx_mask: int, self_source: Node) -> Array:
	var casters: Array = []
	var smask: int = light.shadow_mask
	if smask == 0:
		return casters
	if rx_mask != 0 and (smask & ~rx_mask) == 0:
		return casters
	var scope: Node = null
	if light.exclude_scene_occluders:
		scope = light.owner if light.owner != null else light.get_parent()

	for entry in occ_nodes:
		var occ = entry[0]
		if not is_instance_valid(occ):
			continue
		if not occ.sdf_collision or occ.occluder == null:
			continue
		if not occ.is_inside_tree() or not occ.is_visible_in_tree():
			continue
		var m: int = occ.occluder_light_mask
		if (m & smask) == 0 or (m & smask & rx_mask) != 0:
			continue
		var poly: PackedVector2Array = occ.occluder.polygon
		if poly.is_empty():
			continue
		var closed: bool = occ.occluder.closed
		var inv: Transform2D = occ.global_transform.affine_inverse()
		if not _polygon_near_segment(inv * from, inv * to,
				reach * maxf(inv.x.length(), inv.y.length()), poly, closed):
			continue
		if scope != null and (occ == scope or scope.is_ancestor_of(occ)):
			continue
		# Same "own occluders" set LitSprite2D exempts: descendants and direct siblings.
		if self_source != null and (self_source.is_ancestor_of(occ)
				or occ.get_parent() == self_source.get_parent()):
			continue
		casters.append([inv, poly, closed])

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
		var seg_rect := Rect2(inv * from, Vector2.ZERO).expand(inv * to) \
				.grow(reach * maxf(inv.x.length(), inv.y.length()))
		var near: Array[Rect2] = []
		for i in rects.size():
			var m := masks[i]
			if (m & smask) == 0 or (m & smask & rx_mask) != 0:
				continue
			var r: Rect2 = rects[i]
			if r.intersects(seg_rect):
				near.append(r)
		if not near.is_empty():
			casters.append([inv, near])
	return casters


## True when one of `casters` crosses the segment.
static func _blocked(seg_from: Vector2, seg_to: Vector2, casters: Array) -> bool:
	for caster in casters:
		var inv: Transform2D = caster[0]
		var a := inv * seg_from
		var b := inv * seg_to
		if caster.size() == 3:
			if _segment_hits_polygon(a, b, caster[1], caster[2]):
				return true
		else:
			var seg_rect := Rect2(a, Vector2.ZERO).expand(b)
			for r: Rect2 in caster[1]:
				if r.intersects(seg_rect) and _segment_hits_rect(a, b, r):
					return true
	return false


static func _polygon_near_segment(a: Vector2, b: Vector2, reach: float,
		poly: PackedVector2Array, closed: bool) -> bool:
	if reach <= 0.0:
		return _segment_hits_polygon(a, b, poly, closed)
	var n := poly.size()
	if n < 2:
		return false
	var edges := n if closed and n > 2 else n - 1
	var reach_sq := reach * reach
	for i in edges:
		var near := Geometry2D.get_closest_points_between_segments(a, b, poly[i], poly[(i + 1) % n])
		if near[0].distance_squared_to(near[1]) <= reach_sq:
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
