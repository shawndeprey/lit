@tool
extends RefCounted

## Conversion tables for "Update Project to Lit": which core Godot classes convert to
## which Lit scripts and how their properties map across. Pure data; transforms that
## need logic (blend clamp, shadow_color premultiply, range heuristic) live in
## lit_update_tool.gd, keyed by the `special` lists here.

const LIT_NODES := "res://addons/lit/nodes/"

# CanvasItem/Node2D surface shared by source and replacement, copied live off the old
# node. `transform` subsumes the individually stored position/rotation/scale/skew keys
# (CONSUMED_ALIASES below marks those as handled for the unmapped-property report).
const COPY_LIVE: Array[StringName] = [&"transform", &"visible", &"visibility_layer",
	&"modulate", &"self_modulate", &"show_behind_parent", &"top_level", &"clip_children",
	&"z_index", &"z_as_relative", &"y_sort_enabled", &"texture_filter", &"texture_repeat",
	&"process_mode", &"process_priority", &"process_physics_priority",
	&"physics_interpolation_mode", &"editor_description"]
const CONSUMED_ALIASES: Array[StringName] = [&"position", &"rotation", &"scale", &"skew"]

# Core class -> replacement spec (the Lit class extends Node2D, so the node itself is
# replaced). `copy`: core property -> Lit property, read live so defaults carry.
# `special`: transformed in code by the tool. Stored properties consumed by neither
# (nor COPY_LIVE) are reported as dropped.
const REPLACEMENTS := {
	&"PointLight2D": {
		"script": LIT_NODES + "lit_point_light_2d.gd",
		"lit_class": &"LitPointLight2D",
		"copy": {
			&"enabled": &"enabled",
			&"color": &"color",
			&"energy": &"energy",
			&"texture": &"texture",
			&"texture_scale": &"texture_scale",
			&"shadow_enabled": &"shadow_enabled",
			&"offset": &"texture_offset",
			&"shadow_item_cull_mask": &"shadow_mask",
			&"range_item_cull_mask": &"light_mask",
		},
		"special": [&"blend_mode", &"shadow_color", &"height", &"range"],
	},
	&"DirectionalLight2D": {
		"script": LIT_NODES + "lit_directional_light_2d.gd",
		"lit_class": &"LitDirectionalLight2D",
		"copy": {
			&"enabled": &"enabled",
			&"color": &"color",
			&"energy": &"energy",
			&"shadow_enabled": &"shadow_enabled",
			&"shadow_item_cull_mask": &"shadow_mask",
			&"range_item_cull_mask": &"light_mask",
			&"max_distance": &"shadow_reach",
		},
		"special": [&"blend_mode", &"shadow_color", &"height"],
	},
	&"CanvasModulate": {
		"script": LIT_NODES + "lit_canvas_modulate.gd",
		"lit_class": &"LitCanvasModulate",
		"copy": {&"color": &"color"},
		"special": [],
	},
}

# Core class -> Lit script for in-place set_script swaps (the Lit class extends the
# core class). Receiver fixups (light_mask -> receiver_mask, CanvasTexture wrap) are
# applied by the tool.
const SWAPS := {
	&"Sprite2D": LIT_NODES + "lit_sprite_2d.gd",
	&"TileMapLayer": LIT_NODES + "lit_tile_map_layer.gd",
}

# Core class -> Lit class for rebasing user scripts (`extends Sprite2D` becomes
# `extends LitSprite2D` on the root of each user inheritance chain).
const REBASES := {
	"Sprite2D": {"lit_class": "LitSprite2D", "script": LIT_NODES + "lit_sprite_2d.gd"},
	"TileMapLayer": {"lit_class": "LitTileMapLayer", "script": LIT_NODES + "lit_tile_map_layer.gd"},
}
