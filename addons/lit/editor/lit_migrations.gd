@tool
extends RefCounted

## Version framework for "Update Project to Lit".
##
## BASELINE_SCHEMA locks the stored (serialized) property surface of every Lit node
## class as of BASELINE_VERSION. It is never edited in place: it only advances through
## MIGRATIONS, and Test/gate_migration_schema.gd fails whenever a class's live schema
## drifts from the baseline advanced through the migration list. A PR that renames,
## removes, retypes, re-defaults, or adds a stored property on a Lit node (or adds a
## new Lit node class) must append the matching MIGRATIONS entry (or schema entry) to
## go green.
##
## The update tool chains a node's migrations oldest-to-newest from its stamped
## `lit_version` (unstamped nodes are assumed BASELINE_VERSION). Because Godot drops
## stored values for renamed/removed script properties at load, migrations read old
## values from `stored` (the tool's SceneState capture of the node's saved properties),
## never off the live node. `apply` functions must be idempotent: guard on the old
## stored name or on the node's stamped version.
##
## MIGRATIONS entry shape (sorted ascending by "to", one entry per breaking change):
##   { "to": "1.2.0", "class": &"LitPointLight2D",
##     "renames": {&"old": &"new"},                  # also drives instance-override remap
##     "adds": {&"prop": {"type": TYPE_FLOAT, "default": 1.0}},
##     "removes": [&"gone"],
##     "retypes": {&"prop": {"type": TYPE_INT}},
##     "redefaults": {&"prop": 2.0},
##     "apply": &"_m_1_2_0_example" }                # optional static func below

const BASELINE_VERSION := "1.1.3"

# Regenerate a class's block with:
#   godot --headless --path . --script res://Test/gate_migration_schema.gd -- --dump
const BASELINE_SCHEMA := {
	&"LitCanvasModulate": {
		"script": "res://addons/lit/nodes/lit_canvas_modulate.gd",
		"props": {
			&"ambient_energy": {"type": TYPE_FLOAT, "default": 1.0},
			&"color": {"type": TYPE_COLOR, "default": Color(0.101960786, 0.101960786, 0.101960786, 1)},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
		},
	},
	&"LitDirectionalLight2D": {
		"script": "res://addons/lit/nodes/lit_directional_light_2d.gd",
		"props": {
			&"blend_mode": {"type": TYPE_INT, "default": 0},
			&"color": {"type": TYPE_COLOR, "default": Color(1, 1, 1, 1)},
			&"enabled": {"type": TYPE_BOOL, "default": true},
			&"energy": {"type": TYPE_FLOAT, "default": 1.0},
			&"exclude_scene_occluders": {"type": TYPE_BOOL, "default": false},
			&"height": {"type": TYPE_FLOAT, "default": 16.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"shadow_algorithm": {"type": TYPE_INT, "default": 1},
			&"shadow_color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"shadow_enabled": {"type": TYPE_BOOL, "default": false},
			&"shadow_hardness": {"type": TYPE_FLOAT, "default": 0.5},
			&"shadow_jitter": {"type": TYPE_FLOAT, "default": 0.35},
			&"shadow_length": {"type": TYPE_FLOAT, "default": 1.0},
			&"shadow_mask": {"type": TYPE_INT, "default": 1},
			&"shadow_reach": {"type": TYPE_FLOAT, "default": 4096.0},
			&"shadow_samples": {"type": TYPE_INT, "default": 8},
			&"source_angle": {"type": TYPE_FLOAT, "default": 6.0},
		},
	},
	&"LitPointLight2D": {
		"script": "res://addons/lit/nodes/lit_point_light_2d.gd",
		"props": {
			&"blend_mode": {"type": TYPE_INT, "default": 0},
			&"color": {"type": TYPE_COLOR, "default": Color(1, 1, 1, 1)},
			&"enabled": {"type": TYPE_BOOL, "default": true},
			&"energy": {"type": TYPE_FLOAT, "default": 1.0},
			&"exclude_scene_occluders": {"type": TYPE_BOOL, "default": false},
			&"falloff": {"type": TYPE_FLOAT, "default": 1.0},
			&"height": {"type": TYPE_FLOAT, "default": 16.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"range": {"type": TYPE_FLOAT, "default": 256.0},
			&"shadow_algorithm": {"type": TYPE_INT, "default": 1},
			&"shadow_color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"shadow_enabled": {"type": TYPE_BOOL, "default": false},
			&"shadow_hardness": {"type": TYPE_FLOAT, "default": 0.5},
			&"shadow_jitter": {"type": TYPE_FLOAT, "default": 0.35},
			&"shadow_length": {"type": TYPE_FLOAT, "default": 1.0},
			&"shadow_mask": {"type": TYPE_INT, "default": 1},
			&"shadow_samples": {"type": TYPE_INT, "default": 8},
			&"source_radius": {"type": TYPE_FLOAT, "default": 32.0},
			&"texture": {"type": TYPE_OBJECT, "default": null},
			&"texture_offset": {"type": TYPE_VECTOR2, "default": Vector2(0, 0)},
			&"texture_scale": {"type": TYPE_FLOAT, "default": 1.0},
			&"texture_size_mode": {"type": TYPE_INT, "default": 0},
		},
	},
	&"LitPostAberration": {
		"script": "res://addons/lit/nodes/post/lit_post_aberration.gd",
		"props": {
			&"amount": {"type": TYPE_FLOAT, "default": 3.0},
			&"edge_falloff": {"type": TYPE_FLOAT, "default": 2.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
		},
	},
	&"LitPostAutoExposure": {
		"script": "res://addons/lit/nodes/post/lit_post_auto_exposure.gd",
		"props": {
			&"acclimate_time": {"type": TYPE_FLOAT, "default": 6.0},
			&"amount": {"type": TYPE_FLOAT, "default": 1.0},
			&"center_weight": {"type": TYPE_FLOAT, "default": 0.6},
			&"dark_adapt_time": {"type": TYPE_FLOAT, "default": 3.0},
			&"exposure_compensation": {"type": TYPE_FLOAT, "default": 0.0},
			&"histogram_high": {"type": TYPE_FLOAT, "default": 0.97},
			&"histogram_low": {"type": TYPE_FLOAT, "default": 0.7},
			&"light_adapt_time": {"type": TYPE_FLOAT, "default": 0.85},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"max_exposure": {"type": TYPE_FLOAT, "default": 1.5},
			&"min_exposure": {"type": TYPE_FLOAT, "default": -2.5},
			&"show_meter": {"type": TYPE_BOOL, "default": false},
			&"target_level": {"type": TYPE_FLOAT, "default": 1.0},
		},
	},
	&"LitPostBloom": {
		"script": "res://addons/lit/nodes/post/lit_post_bloom.gd",
		"props": {
			&"intensity": {"type": TYPE_FLOAT, "default": 0.5},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"radius": {"type": TYPE_FLOAT, "default": 4.0},
			&"threshold": {"type": TYPE_FLOAT, "default": 0.7},
		},
	},
	&"LitPostColorGrade": {
		"script": "res://addons/lit/nodes/post/lit_post_color_grade.gd",
		"props": {
			&"contrast": {"type": TYPE_FLOAT, "default": 1.0},
			&"exposure": {"type": TYPE_FLOAT, "default": 1.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"saturation": {"type": TYPE_FLOAT, "default": 1.0},
			&"tint": {"type": TYPE_COLOR, "default": Color(1, 1, 1, 1)},
		},
	},
	&"LitPostCrt": {
		"script": "res://addons/lit/nodes/post/lit_post_crt.gd",
		"props": {
			&"aberration": {"type": TYPE_FLOAT, "default": 1.5},
			&"brightness": {"type": TYPE_FLOAT, "default": 1.2},
			&"curvature": {"type": TYPE_FLOAT, "default": 0.2},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"mask_strength": {"type": TYPE_FLOAT, "default": 0.3},
			&"scanline_count": {"type": TYPE_FLOAT, "default": 240.0},
			&"scanline_strength": {"type": TYPE_FLOAT, "default": 0.3},
			&"vignette": {"type": TYPE_FLOAT, "default": 0.3},
		},
	},
	&"LitPostDither": {
		"script": "res://addons/lit/nodes/post/lit_post_dither.gd",
		"props": {
			&"levels": {"type": TYPE_FLOAT, "default": 4.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"monochrome": {"type": TYPE_BOOL, "default": false},
			&"pattern_scale": {"type": TYPE_FLOAT, "default": 1.0},
			&"strength": {"type": TYPE_FLOAT, "default": 1.0},
		},
	},
	&"LitPostEffect": {
		"script": "res://addons/lit/nodes/post/lit_post_effect.gd",
		"props": {
			&"lit_version": {"type": TYPE_STRING, "default": ""},
		},
	},
	&"LitPostFilmGrain": {
		"script": "res://addons/lit/nodes/post/lit_post_film_grain.gd",
		"props": {
			&"colored": {"type": TYPE_BOOL, "default": false},
			&"intensity": {"type": TYPE_FLOAT, "default": 0.05},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"luminance_response": {"type": TYPE_FLOAT, "default": 0.5},
			&"size": {"type": TYPE_FLOAT, "default": 1.0},
		},
	},
	&"LitPostFocus": {
		"script": "res://addons/lit/nodes/post/lit_post_focus.gd",
		"props": {
			&"amount": {"type": TYPE_FLOAT, "default": -0.5},
			&"dream": {"type": TYPE_FLOAT, "default": 0.2},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"radius": {"type": TYPE_FLOAT, "default": 2.0},
		},
	},
	&"LitPostGlitch": {
		"script": "res://addons/lit/nodes/post/lit_post_glitch.gd",
		"props": {
			&"block_size": {"type": TYPE_FLOAT, "default": 12.0},
			&"intensity": {"type": TYPE_FLOAT, "default": 0.5},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"rgb_shift": {"type": TYPE_FLOAT, "default": 4.0},
			&"speed": {"type": TYPE_FLOAT, "default": 8.0},
		},
	},
	&"LitPostHalation": {
		"script": "res://addons/lit/nodes/post/lit_post_halation.gd",
		"props": {
			&"intensity": {"type": TYPE_FLOAT, "default": 0.6},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"radius": {"type": TYPE_FLOAT, "default": 5.0},
			&"threshold": {"type": TYPE_FLOAT, "default": 0.6},
			&"tint": {"type": TYPE_COLOR, "default": Color(1, 0.25, 0.1, 1)},
		},
	},
	&"LitPostHalftone": {
		"script": "res://addons/lit/nodes/post/lit_post_halftone.gd",
		"props": {
			&"amount": {"type": TYPE_FLOAT, "default": 1.0},
			&"angle": {"type": TYPE_FLOAT, "default": 0.0},
			&"dot_size": {"type": TYPE_FLOAT, "default": 6.0},
			&"ink_color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"paper_color": {"type": TYPE_COLOR, "default": Color(1, 1, 1, 1)},
		},
	},
	&"LitPostLensDistortion": {
		"script": "res://addons/lit/nodes/post/lit_post_lens_distortion.gd",
		"props": {
			&"amount": {"type": TYPE_FLOAT, "default": 0.2},
			&"edge_color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"zoom": {"type": TYPE_FLOAT, "default": 1.0},
		},
	},
	&"LitPostLetterbox": {
		"script": "res://addons/lit/nodes/post/lit_post_letterbox.gd",
		"props": {
			&"color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"size": {"type": TYPE_FLOAT, "default": 0.12},
			&"softness": {"type": TYPE_FLOAT, "default": 0.0},
		},
	},
	&"LitPostLightLeaks": {
		"script": "res://addons/lit/nodes/post/lit_post_light_leaks.gd",
		"props": {
			&"color1": {"type": TYPE_COLOR, "default": Color(1, 0.5, 0.2, 1)},
			&"color2": {"type": TYPE_COLOR, "default": Color(1, 0.2, 0.3, 1)},
			&"intensity": {"type": TYPE_FLOAT, "default": 0.6},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"speed": {"type": TYPE_FLOAT, "default": 1.0},
			&"texture": {"type": TYPE_OBJECT, "default": null},
		},
	},
	&"LitPostLut": {
		"script": "res://addons/lit/nodes/post/lit_post_lut.gd",
		"props": {
			&"amount": {"type": TYPE_FLOAT, "default": 1.0},
			&"custom_texture": {"type": TYPE_OBJECT, "default": null},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"preset": {"type": TYPE_INT, "default": 0},
		},
	},
	&"LitPostOutline": {
		"script": "res://addons/lit/nodes/post/lit_post_outline.gd",
		"props": {
			&"color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"softness": {"type": TYPE_FLOAT, "default": 0.1},
			&"strength": {"type": TYPE_FLOAT, "default": 1.0},
			&"thickness": {"type": TYPE_FLOAT, "default": 1.0},
			&"threshold": {"type": TYPE_FLOAT, "default": 0.1},
		},
	},
	&"LitPostPixelate": {
		"script": "res://addons/lit/nodes/post/lit_post_pixelate.gd",
		"props": {
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"pixel_size": {"type": TYPE_FLOAT, "default": 4.0},
		},
	},
	&"LitPostPosterize": {
		"script": "res://addons/lit/nodes/post/lit_post_posterize.gd",
		"props": {
			&"levels": {"type": TYPE_FLOAT, "default": 4.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"strength": {"type": TYPE_FLOAT, "default": 1.0},
		},
	},
	&"LitPostProcess": {
		"script": "res://addons/lit/nodes/lit_post_process.gd",
		"props": {
			&"lit_version": {"type": TYPE_STRING, "default": ""},
		},
	},
	&"LitPostThreshold": {
		"script": "res://addons/lit/nodes/post/lit_post_threshold.gd",
		"props": {
			&"cutoff": {"type": TYPE_FLOAT, "default": 0.5},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
		},
	},
	&"LitPostVhs": {
		"script": "res://addons/lit/nodes/post/lit_post_vhs.gd",
		"props": {
			&"bleed": {"type": TYPE_FLOAT, "default": 0.5},
			&"chroma_shift": {"type": TYPE_FLOAT, "default": 2.0},
			&"grain": {"type": TYPE_FLOAT, "default": 0.12},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"roll_strength": {"type": TYPE_FLOAT, "default": 0.1},
			&"tracking_speed": {"type": TYPE_FLOAT, "default": 0.2},
			&"tracking_strength": {"type": TYPE_FLOAT, "default": 0.6},
			&"wobble_speed": {"type": TYPE_FLOAT, "default": 4.0},
			&"wobble_strength": {"type": TYPE_FLOAT, "default": 2.0},
		},
	},
	&"LitPostVignette": {
		"script": "res://addons/lit/nodes/post/lit_post_vignette.gd",
		"props": {
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"softness": {"type": TYPE_FLOAT, "default": 0.5},
			&"strength": {"type": TYPE_FLOAT, "default": 0.4},
		},
	},
	&"LitPrecompileOverlay": {
		"script": "res://addons/lit/nodes/lit_precompile_overlay.gd",
		"props": {
		},
	},
	&"LitSplashScreen": {
		"script": "res://addons/lit/nodes/lit_splash_screen.gd",
		"props": {
			&"auto_free": {"type": TYPE_BOOL, "default": true},
			&"autoplay": {"type": TYPE_BOOL, "default": true},
			&"background_color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"fade_in_time": {"type": TYPE_FLOAT, "default": 0.7},
			&"fade_out_time": {"type": TYPE_FLOAT, "default": 0.45},
			&"glitch_strength": {"type": TYPE_FLOAT, "default": 0.55},
			&"hold_time": {"type": TYPE_FLOAT, "default": 2.5},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"logo": {"type": TYPE_OBJECT, "default": "res://addons/lit/branding/Lit-Logo-Text.png"},
			&"logo_screen_ratio": {"type": TYPE_FLOAT, "default": 0.6},
			&"sfx": {"type": TYPE_OBJECT, "default": "res://addons/lit/branding/glitch.mp3"},
			&"skippable": {"type": TYPE_BOOL, "default": true},
		},
	},
	&"LitSpotLight2D": {
		"script": "res://addons/lit/nodes/lit_spot_light_2d.gd",
		"props": {
			&"blend_mode": {"type": TYPE_INT, "default": 0},
			&"color": {"type": TYPE_COLOR, "default": Color(1, 1, 1, 1)},
			&"enabled": {"type": TYPE_BOOL, "default": true},
			&"energy": {"type": TYPE_FLOAT, "default": 1.0},
			&"exclude_scene_occluders": {"type": TYPE_BOOL, "default": false},
			&"falloff": {"type": TYPE_FLOAT, "default": 1.0},
			&"height": {"type": TYPE_FLOAT, "default": 16.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"range": {"type": TYPE_FLOAT, "default": 256.0},
			&"shadow_algorithm": {"type": TYPE_INT, "default": 1},
			&"shadow_color": {"type": TYPE_COLOR, "default": Color(0, 0, 0, 1)},
			&"shadow_enabled": {"type": TYPE_BOOL, "default": false},
			&"shadow_hardness": {"type": TYPE_FLOAT, "default": 0.5},
			&"shadow_jitter": {"type": TYPE_FLOAT, "default": 0.35},
			&"shadow_length": {"type": TYPE_FLOAT, "default": 1.0},
			&"shadow_mask": {"type": TYPE_INT, "default": 1},
			&"shadow_samples": {"type": TYPE_INT, "default": 8},
			&"source_radius": {"type": TYPE_FLOAT, "default": 32.0},
			&"spot_angle": {"type": TYPE_FLOAT, "default": 30.0},
			&"spot_softness": {"type": TYPE_FLOAT, "default": 0.5},
			&"texture": {"type": TYPE_OBJECT, "default": null},
			&"texture_offset": {"type": TYPE_VECTOR2, "default": Vector2(0, 0)},
			&"texture_scale": {"type": TYPE_FLOAT, "default": 1.0},
			&"texture_size_mode": {"type": TYPE_INT, "default": 0},
		},
	},
	&"LitSprite2D": {
		"script": "res://addons/lit/nodes/lit_sprite_2d.gd",
		"props": {
			&"directional_horizontal_scale": {"type": TYPE_FLOAT, "default": 32.0},
			&"emissive_strength": {"type": TYPE_FLOAT, "default": 0.0},
			&"footprint_shadow": {"type": TYPE_FLOAT, "default": 16.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"metallic_value": {"type": TYPE_FLOAT, "default": 0.0},
			&"receiver_mask": {"type": TYPE_INT, "default": 1},
			&"roughness_value": {"type": TYPE_FLOAT, "default": 1.0},
			&"self_shadow": {"type": TYPE_BOOL, "default": false},
			&"shadow_ignore_mask": {"type": TYPE_INT, "default": 0},
			&"shadow_min_step": {"type": TYPE_FLOAT, "default": 0.2},
			&"shadow_steps": {"type": TYPE_INT, "default": 64},
			&"specular_k": {"type": TYPE_FLOAT, "default": 32.0},
			&"specular_strength": {"type": TYPE_FLOAT, "default": 0.5},
		},
	},
	&"LitTileMapLayer": {
		"script": "res://addons/lit/nodes/lit_tile_map_layer.gd",
		"props": {
			&"directional_horizontal_scale": {"type": TYPE_FLOAT, "default": 32.0},
			&"emissive_strength": {"type": TYPE_FLOAT, "default": 0.0},
			&"footprint_shadow": {"type": TYPE_FLOAT, "default": 16.0},
			&"lit_version": {"type": TYPE_STRING, "default": ""},
			&"metallic_value": {"type": TYPE_FLOAT, "default": 0.0},
			&"receiver_mask": {"type": TYPE_INT, "default": 1},
			&"roughness_value": {"type": TYPE_FLOAT, "default": 1.0},
			&"self_shadow": {"type": TYPE_BOOL, "default": false},
			&"shadow_ignore_mask": {"type": TYPE_INT, "default": 0},
			&"shadow_min_step": {"type": TYPE_FLOAT, "default": 0.2},
			&"shadow_steps": {"type": TYPE_INT, "default": 64},
			&"specular_k": {"type": TYPE_FLOAT, "default": 32.0},
			&"specular_strength": {"type": TYPE_FLOAT, "default": 0.5},
		},
	},
}

const MIGRATIONS: Array[Dictionary] = []


static func current_version() -> String:
	return LitShaderLibrary._get_version()


## -1, 0, or 1; missing components count as 0 ("1.2" == "1.2.0").
static func semver_cmp(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var na := int(pa[i]) if i < pa.size() else 0
		var nb := int(pb[i]) if i < pb.size() else 0
		if na != nb:
			return -1 if na < nb else 1
	return 0


## The version a node's saved data is shaped as: its stamp, a legacy meta stamp, or
## the baseline for unstamped nodes.
static func node_version(node: Node) -> String:
	var v: Variant = node.get(&"lit_version")
	if v is String and not (v as String).is_empty():
		return v
	if node.has_meta(&"lit_version"):
		return str(node.get_meta(&"lit_version"))
	return BASELINE_VERSION


## Migrations that still apply to a node of `klass` whose data is at `from_version`,
## oldest first.
static func chain_for(klass: StringName, from_version: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in MIGRATIONS:
		if m["class"] == klass and semver_cmp(from_version, m["to"]) < 0:
			out.append(m)
	return out


## Merged old -> new property renames across a node's remaining chain; drives both the
## live-node migration and the instance-override remap in parent scenes.
static func rename_map_for(klass: StringName, from_version: String) -> Dictionary:
	var out := {}
	for m in chain_for(klass, from_version):
		out.merge(m.get("renames", {}), true)
	return out


## Run a node's remaining chain against its live self plus its as-saved property
## capture. Returns true when anything changed.
static func apply_chain(node: Node, klass: StringName, stored: Dictionary, report: Array) -> bool:
	var from := node_version(node)
	var changed := false
	var script := load("res://addons/lit/editor/lit_migrations.gd")
	for m in chain_for(klass, from):
		for old_name in m.get("renames", {}):
			if stored.has(old_name):
				node.set(m["renames"][old_name], stored[old_name])
				changed = true
				report.append("MIGRATED %s: %s -> %s (to v%s)"
						% [klass, old_name, m["renames"][old_name], m["to"]])
		if m.has("apply"):
			if script.call(m["apply"], node, stored, report):
				changed = true
	return changed


## BASELINE_SCHEMA advanced through MIGRATIONS: what the live classes must look like.
static func expected_schema() -> Dictionary:
	var schema := {}
	for klass in BASELINE_SCHEMA:
		schema[klass] = {
			"script": BASELINE_SCHEMA[klass]["script"],
			"props": BASELINE_SCHEMA[klass]["props"].duplicate(true),
		}
	for m in MIGRATIONS:
		var props: Dictionary = schema[m["class"]]["props"]
		var renames: Dictionary = m.get("renames", {})
		for old_name in renames:
			props[renames[old_name]] = props[old_name]
			props.erase(old_name)
		for gone in m.get("removes", []):
			props.erase(gone)
		for added in m.get("adds", {}):
			props[added] = m["adds"][added]
		for retyped in m.get("retypes", {}):
			props[retyped]["type"] = m["retypes"][retyped]["type"]
		for redefaulted in m.get("redefaults", {}):
			props[redefaulted]["default"] = m["redefaults"][redefaulted]
	return schema
