@tool
extends RefCounted

## Receiver material policy for "Update Project to Lit": classifying what sits in a
## candidate's material slot, and producing/syncing the Lit receiver material and
## CanvasTexture wrap. Shared by the scan classifier and the scene converter.


## What sits in the material slot decides the conversion path:
##  none            - convert; the Lit _init supplies the receiver material.
##  receiver        - already carries a Lit receiver ShaderMaterial ("Make Selected
##                    Nodes Lit" output); convert keeping it, syncing exports from it.
##  default_canvas  - a CanvasItemMaterial with default behavior; drop it and convert.
##  unlit           - deliberately unlit (unshaded/blend CanvasItemMaterial, or a
##                    shader declaring render_mode unshaded): already Lit-native as an
##                    overlay that composes above the lighting; left as-is.
##  custom          - a custom shader; can't be fused automatically, grouped in the
##                    report with the Custom Shaders pattern menu.
static func classify(mat: Material) -> Dictionary:
	if mat == null:
		return {"kind": "none"}
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if LitShaderLibrary.flags_of(sh) >= 0:
			return {"kind": "receiver"}
		if sh != null:
			var rx := RegEx.new()
			rx.compile("(?m)^\\s*render_mode[^;]*\\bunshaded\\b")
			if rx.search(sh.code) != null:
				return {"kind": "unlit", "why": "shader declares render_mode unshaded"}
		var shader_path := "<embedded shader>"
		if sh != null and not sh.resource_path.is_empty():
			shader_path = sh.resource_path
		elif not mat.resource_path.is_empty():
			shader_path = mat.resource_path
		return {"kind": "custom", "shader": shader_path}
	if mat is CanvasItemMaterial:
		var cm := mat as CanvasItemMaterial
		if cm.blend_mode == CanvasItemMaterial.BLEND_MODE_MIX \
				and cm.light_mode == CanvasItemMaterial.LIGHT_MODE_NORMAL \
				and not cm.particles_animation:
			return {"kind": "default_canvas"}
		return {"kind": "unlit", "why": "unshaded/blended CanvasItemMaterial"}
	return {"kind": "custom", "shader": mat.get_class()}


## A pre-existing receiver material is authoritative: land its per-node params on the
## new Lit exports (the setters write the same values straight back).
static func sync_exports(node: Node) -> void:
	var mat := (node as CanvasItem).material as ShaderMaterial
	for pair in [["receiver_mask", &"receiver_mask"], ["emissive_strength", &"emissive_strength"],
			["self_shadow", &"self_shadow"], ["rx_mask", &"shadow_ignore_mask"]]:
		var v: Variant = mat.get_shader_parameter(pair[0])
		if v != null:
			node.set(pair[1], v)


## Mirrors the receiver material the Lit _init would have created had the slot been
## empty at load.
static func fresh_material(node: Node) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(LitShaderLibrary.ENTRY_PATHS[0])
	for pair in [["emissive_strength", &"emissive_strength"],
			["receiver_mask", &"receiver_mask"], ["self_shadow", &"self_shadow"]]:
		mat.set_shader_parameter(pair[0], node.get(pair[1]))
	return mat


static func wrap_texture(node: Node) -> bool:
	var tex = node.get("texture")
	if tex is Texture2D and not (tex is CanvasTexture):
		var ct := CanvasTexture.new()
		ct.diffuse_texture = tex
		node.set("texture", ct)
		return true
	return false
