@tool
extends RefCounted

## The scan behind "Generate Lit Precompile Config" (Project > Tools): finds every
## actual Lit use in the project's saved scenes and writes res://lit_precompile.cfg,
## which the precompiler then runs verbatim instead of the full variant matrix
## (delete the file to restore full builds). Scenes are read through SceneState
## (never instanced), so no scene code runs. Lit usage created purely from code is
## invisible here; dev builds warn when a variant compiles outside the configured
## list, which is the cue to regenerate or hand-extend the file.

const LitShaderPrecompilerScript := preload("res://addons/lit/runtime/lit_shader_precompiler.gd")
const WorldSdfScript := preload("res://addons/lit/runtime/registry/world_sdf.gd")

const LIGHT_SCRIPTS := {
	"res://addons/lit/nodes/lit_point_light_2d.gd": true,
	"res://addons/lit/nodes/lit_spot_light_2d.gd": true,
	"res://addons/lit/nodes/lit_directional_light_2d.gd": true,
}
const RECEIVER_SCRIPTS := {
	"res://addons/lit/nodes/lit_sprite_2d.gd": true,
	"res://addons/lit/nodes/lit_tile_map_layer.gd": true,
}


## Scan, write the settings, and return a summary:
## {scenes, variants: PackedStringArray, shaders: Array, full: int}.
static func generate() -> Dictionary:
	var scenes: Array[String] = []
	LitShaderPrecompilerScript._collect_scenes("res://", scenes)

	var tiers := {}
	var receivers := false
	var rx := false
	var cone := false
	var stoch := false
	var masks := false
	for scene_path in scenes:
		var packed := load(scene_path) as PackedScene
		if packed == null:
			push_warning("Lit: precompile scan could not load '%s'; skipped" % scene_path)
			continue
		var state := packed.get_state()
		for i in state.get_node_count():
			var props := {}
			for p in state.get_node_property_count(i):
				props[state.get_node_property_name(i, p)] = state.get_node_property_value(i, p)
			var script_path := ""
			var script = props.get("script")
			if script is Script:
				script_path = (script as Script).resource_path
			if RECEIVER_SCRIPTS.has(script_path):
				receivers = true
			# Properties are checked by name, not just by script: overrides on instanced
			# sub-scene nodes carry the property without the script.
			if props.has("shadow_algorithm"):
				var algo := int(props["shadow_algorithm"])
				cone = cone or algo == LitShaderLibrary.ShadowAlgorithm.CONE_TRACED
				stoch = stoch or algo == LitShaderLibrary.ShadowAlgorithm.STOCHASTIC
			elif LIGHT_SCRIPTS.has(script_path):
				cone = true  # absent export = the CONE_TRACED default
			if int(props.get("shadow_mask", 1)) != 1 \
					or bool(props.get("exclude_scene_occluders", false)) \
					or int(props.get("occluder_light_mask", 1)) != 1:
				masks = true
			if int(props.get("shadow_ignore_mask", 0)) != 0:
				rx = true
			var ts = props.get("tile_set")
			if ts is TileSet:
				for l in (ts as TileSet).get_occlusion_layers_count():
					if (ts as TileSet).get_occlusion_layer_light_mask(l) != 1:
						masks = true
			var mat = props.get("material")
			if mat is ShaderMaterial:
				var flags := LitShaderLibrary.flags_of((mat as ShaderMaterial).shader)
				if flags >= 0:
					receivers = true
					tiers[flags & LitShaderLibrary.TIER_MASK] = true

	# Receiver tiers fluctuate at runtime (LitReceiverHelper re-tiers per frame): any
	# receiver can sit on fast or full, and on the y-sort tier while the project
	# setting is on. Authored material tiers are merged on top.
	if receivers:
		tiers[0] = true
		tiers[LitShaderLibrary.F_SELF_EXCL] = true
		if bool(ProjectSettings.get_setting("lit/render/y_sorting", false)):
			tiers[LitShaderLibrary.F_SELF_EXCL | LitShaderLibrary.F_YSORT] = true

	# Every subset of the observed activity axes is runtime-reachable (algorithms and
	# masks toggle with scene state), so the powerset goes in; resolve() prunes.
	var axes: Array[int] = []
	if cone:
		axes.append(LitShaderLibrary.F_CONE)
	if stoch:
		axes.append(LitShaderLibrary.F_STOCH)
	if masks:
		axes.append(LitShaderLibrary.F_MASKS)
		axes.append(LitShaderLibrary.F_GX)
	var node_opts: Array[int] = [0]
	if rx:
		node_opts.append(LitShaderLibrary.F_RX)
	var seen := {}
	for tier in tiers:
		for n in node_opts:
			for combo in 1 << axes.size():
				var act := 0
				for a in axes.size():
					if combo & (1 << a) != 0:
						act |= axes[a]
				seen[LitShaderLibrary.resolve(tier, n, act)] = true
	var flags_list: Array = seen.keys()
	flags_list.sort()

	var statics: Array = []
	for tier in LitShaderLibrary.ENTRY_PATHS:
		if tiers.has(tier):
			statics.append(LitShaderLibrary.ENTRY_PATHS[tier])
	if not flags_list.is_empty():
		statics.append(WorldSdfScript.ENCODE_SHADER_PATH)
	LitShaderPrecompilerScript._post_scan = null
	statics.append_array(LitShaderPrecompilerScript.used_post_shaders())

	var names := PackedStringArray()
	for f in flags_list:
		names.append(LitShaderLibrary.variant_name(f))
	var cfg := ConfigFile.new()
	cfg.set_value("lit", "variants", names)
	cfg.set_value("lit", "shaders", PackedStringArray(statics))
	var err := cfg.save(LitShaderPrecompilerScript.CONFIG_PATH)
	if err != OK:
		push_warning("Lit: could not write '%s' (error %d)" % [LitShaderPrecompilerScript.CONFIG_PATH, err])
	elif Engine.is_editor_hint():
		# The write bypasses the editor's filesystem tracking: rescan so the file
		# shows up in the FileSystem dock, and refresh any open tab showing it
		# (respects the user's auto-reload setting; untouched files are no-ops).
		EditorInterface.get_resource_filesystem().scan()
		EditorInterface.get_script_editor().reload_open_files()
	return {
		"scenes": scenes.size(),
		"variants": names,
		"shaders": statics,
		"full": LitShaderLibrary.all_variant_flags().size(),
		"saved": err == OK,
	}
