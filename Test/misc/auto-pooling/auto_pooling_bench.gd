extends Node2D

## Material auto-pooling bench. Builds every receiver configuration the runtime pool
## must tell apart (or is allowed to merge), then mutates them the way a game would
## (proxy edits, shadow masks, occluders, make_material_unique, frees, node
## duplication, runtime material swaps, shadow-algorithm switches) and checks the pool
## after each step: which nodes share a material, what each entry holds, and whether
## the refcounts stay honest.
##
## Every check prints one POOLBENCH line (PASS/FAIL with expected vs actual); the
## pool's compiled entries (material, refcount, members, key) are dumped after the
## static build and at the end; the HUD shows the same results plus live entries/refs,
## and every exhibit carries a live tag naming the material it holds (M1, M2, ...) and
## whether it is pooled, so the sharing can be watched on screen. Exhibits stay on
## screen so a wrong merge is also visible (a mask-free sprite glowing through another
## sprite's emissive mask, for instance).
##
## Run windowed (the headless renderer never compiles shaders):
##   godot --path . res://Test/misc/auto-pooling/auto_pooling_bench.tscn
## Options after "--":
##   quit=on        quit after the final report (console / CI use)
##   capture=PATH   save a PNG of the final frame (implies a quit afterwards)
## The scene stays open by default; Escape quits.

# Uniforms the runtime drives per node. They must never take part in the pool key: a
# pooled entry holds them empty by construction (nodes needing per-node values detach
# first). Every other uniform the receiver shader declares is content the key must see.
const POOL_DRIVEN: Array[String] = [
	"self_rect_count", "self_rects", "ysort_on", "ysort_y",
	"rx_mask", "rx_bounds", "rx_bound_count",
]

# One sprite per entry: a single non-default proxy value each.
const SCALAR_SPLITS := {
	"emissive_strength": 0.7, "receiver_mask": 3, "self_shadow": true,
	"specular_strength": 0.9, "specular_k": 8.0, "metallic_value": 0.5,
	"roughness_value": 0.3, "shadow_steps": 32, "shadow_min_step": 0.5,
	"footprint_shadow": 4.0, "directional_horizontal_scale": 8.0,
}

const CELL := Vector2(228.0, 190.0)
const ORIGIN := Vector2(20.0, 70.0)
const COLS := 6
const HUD_X := 1400.0
const DEFAULT_COUNT := 10

var _opt_quit := false
var _opt_capture := ""

var _frame := 0
var _results: Array = []
var _mat_labels := {}
var _tex_names := {}
var _hud: RichTextLabel
var _stats: Label
var _exhibits: Node2D
var _tags: Array = []
var _cell_index := 0
var _finished := false

var _diffuse: ImageTexture
var _checker: ImageTexture
var _stripes: ImageTexture
var _grad_h: ImageTexture
var _grad_v: ImageTexture
var _radial: ImageTexture
var _white: ImageTexture
var _tile_tex: ImageTexture
var _fast_shader: Shader
var _full_shader: Shader

# Static exhibits.
var _defaults: Array = []
var _default_members: Array = []
var _authored_default: ShaderMaterial
var _default_vals := {}
var _mask_a: LitSprite2D
var _mask_b: LitSprite2D
var _mask_c: LitSprite2D
var _tm_mask: LitTileMapLayer
var _key_sprite: LitSprite2D
var _splits := {}
var _map_sprites := {}
var _spec_sprite: LitSprite2D
var _local_sprite: LitSprite2D
var _local_authored: ShaderMaterial
var _custom_sprite: LitSprite2D
var _custom_mat: ShaderMaterial
var _nullsh_sprite: LitSprite2D
var _nullsh_mat: ShaderMaterial
var _rx_sprite: LitSprite2D
var _occ_sprite: LitSprite2D
var _tm_occ: LitTileMapLayer
var _bare_param_sprite: LitSprite2D
var _shared_a: LitSprite2D
var _shared_b: LitSprite2D
var _shared_authored: ShaderMaterial
var _bare_sprite: Sprite2D
var _bare_mat: ShaderMaterial
var _full_sprite: LitSprite2D
var _anim: LitAnimatedSprite2D
var _tm_default: LitTileMapLayer
var _inst_a: LitSprite2D
var _inst_b: LitSprite2D
var _light: LitPointLight2D
var _shadow_light: LitPointLight2D

# Mutation-phase state.
var _dup_pooled: LitSprite2D
var _dup_unique: LitSprite2D
var _swap_sprite: LitSprite2D
var _free_sprite: LitSprite2D
var _foreign_a: LitSprite2D
var _foreign_b: LitSprite2D
var _refs_before_frees := 0
var _entry_before_frees: ShaderMaterial


func _ready() -> void:
	_parse_args()
	_fast_shader = load(LitShaderLibrary.ENTRY_PATHS[0])
	_full_shader = load(LitShaderLibrary.ENTRY_PATHS[LitShaderLibrary.F_SELF_EXCL])
	_make_textures()
	_build_environment()
	_build_hud()
	_build_static_exhibits()
	_print_uniforms()
	print("POOLBENCH built %d Lit receiver nodes; pool %s" % [_lit_nodes().size(), _stats_text()])


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"quit":
				_opt_quit = kv[1] == "on" or kv[1] == "1" or kv[1] == "true"
			"capture":
				_opt_capture = kv[1]
				_opt_quit = true


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()


# --- Phases -----------------------------------------------------------------------

func _process(_delta: float) -> void:
	_frame += 1
	_stats.text = "Auto-pooling bench   frame %d   pool: %s      tags: yellow = pooled entry, blue = private material" \
			% [_frame, _stats_text()]
	_update_tags()
	if _finished:
		return
	match _frame:
		3:
			_static_checks()
			_dump_pool("after static build")
			_render_hud()
		4:
			_mutations_a()
			_render_hud()
		8:
			_mutations_b()
			_render_hud()
		12:
			_final()


func _final() -> void:
	_finished = true
	_check("activity_repoint", "cone light off again: shared entry back on the base variant",
			0, LitShaderLibrary.flags_of(_defaults[0].material.shader) & LitShaderLibrary.F_CONE)
	_integrity("final")
	_dump_pool("final")
	_summary()
	_render_hud()
	if _opt_quit:
		_finish()


func _finish() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if _opt_capture != "":
		var img := get_viewport().get_texture().get_image()
		img.save_png(_opt_capture)
		print("POOLBENCH capture=%s" % _opt_capture)
	get_tree().quit()


# --- Static exhibits ----------------------------------------------------------------

func _build_static_exhibits() -> void:
	# 1. Identical defaults: the sharing baseline. Members of this entry are collected
	#    in _default_members so the refcount expectation is explicit.
	var c := _cell("identical defaults x%d\n(all share one material)" % DEFAULT_COUNT)
	for i in DEFAULT_COUNT:
		var s := _sprite("Default%d" % i)
		if i == 0:
			_authored_default = s.material
		_place(s, c, Vector2((i % 5) * 40 - 80, floori(i / 5.0) * 40 - 20), 0.5)
		_defaults.append(s)
		_default_members.append(s)
	for p in SCALAR_SPLITS:
		_default_vals[p] = _defaults[0].material.get_shader_parameter(p)

	# 2. The user's report: same emissive strength, different emissive masks.
	c = _cell("A: emissive 0.5\n+ checker mask")
	_mask_a = _sprite("MaskA")
	_mask_a.emissive_strength = 0.5
	_mask_a.material.set_shader_parameter("emissive_mask", _checker)
	_place(_mask_a, c)
	c = _cell("B: emissive 0.5, NO mask\n(must glow flat, not checkered)")
	_mask_b = _sprite("MaskB")
	_mask_b.emissive_strength = 0.5
	_place(_mask_b, c)
	c = _cell("C: emissive 0.5\n+ stripes mask")
	_mask_c = _sprite("MaskC")
	_mask_c.emissive_strength = 0.5
	_mask_c.material.set_shader_parameter("emissive_mask", _stripes)
	_place(_mask_c, c)

	# 3. The user's exact setup: a tilemap with an emissive mask, then a mobile sprite
	#    with the same emissive strength and no mask.
	c = _cell("tilemap: emissive 0.5\n+ checker mask")
	_tm_mask = _tilemap("TilemapMask", _tileset(false), 5, 3)
	_tm_mask.emissive_strength = 0.5
	_tm_mask.material.set_shader_parameter("emissive_mask", _checker)
	_place(_tm_mask, c, Vector2(-80, -48))
	c = _cell("key: emissive 0.5, NO mask\n(user repro: must not take the map)")
	_key_sprite = _sprite("KeySprite")
	_key_sprite.emissive_strength = 0.5
	_place(_key_sprite, c)

	# 4. One sprite per scalar proxy: each must land in its own entry.
	c = _cell("scalar splits: one sprite per\nproxy param (11 entries)")
	var i := 0
	for p in SCALAR_SPLITS:
		var s := _sprite("Split_" + p)
		s.set(p, SCALAR_SPLITS[p])
		_place(s, c, Vector2((i % 4) * 44 - 66, floori(i / 4.0) * 44 - 40), 0.5)
		_splits[p] = s
		i += 1

	# 5. Texture uniforms set straight on the material (as the inspector does).
	for entry in [["metallic_map", _grad_h], ["roughness_map", _grad_v], ["ao_map", _radial]]:
		c = _cell("only %s set\n(own entry, defaults keep null)" % entry[0])
		var s := _sprite("Map_" + entry[0])
		s.material.set_shader_parameter(entry[0], entry[1])
		_place(s, c)
		_map_sprites[entry[0]] = s

	# 6. Specular map on the CanvasTexture: keyed through has_specular_map.
	c = _cell("specular map on CanvasTexture\n(has_specular_map keyed)")
	_spec_sprite = _sprite("SpecularMap")
	(_spec_sprite.texture as CanvasTexture).specular_texture = _white
	_place(_spec_sprite, c)

	# 7. Opt-outs: Local to Scene, a custom shader, no shader at all.
	c = _cell("resource_local_to_scene\n(opts out: authored stays)")
	_local_sprite = _sprite("LocalToScene")
	_local_sprite.material.resource_local_to_scene = true
	_local_authored = _local_sprite.material
	_place(_local_sprite, c)
	c = _cell("custom shader / null shader\n(never pooled)")
	_custom_sprite = _sprite("CustomShader")
	var sh := Shader.new()
	sh.code = "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(0.2, 0.5, 0.9, 1.0); }\n"
	_custom_mat = ShaderMaterial.new()
	_custom_mat.shader = sh
	_custom_sprite.material = _custom_mat
	_place(_custom_sprite, c, Vector2(-40, 0))
	_nullsh_sprite = _sprite("NullShader")
	_nullsh_mat = ShaderMaterial.new()
	_nullsh_sprite.material = _nullsh_mat
	_place(_nullsh_sprite, c, Vector2(40, 0))

	# 8. Per-node uniforms force a private material: rx mask, owned occluder, occlusion
	#    tiles.
	c = _cell("shadow_ignore_mask = 2\n(unique, rx variant)")
	_rx_sprite = _sprite("RxMask")
	_rx_sprite.shadow_ignore_mask = 2
	_place(_rx_sprite, c)
	c = _cell("child LightOccluder2D\n(unique: self rects)")
	_occ_sprite = _sprite("OwnedOccluder")
	_occ_sprite.add_child(_occluder(Vector2(0, 40)))
	_place(_occ_sprite, c)
	c = _cell("tilemap with occlusion tiles\n(unique: self rects)")
	_tm_occ = _tilemap("TilemapOccluders", _tileset(true), 3, 2)
	_place(_tm_occ, c, Vector2(-48, -32))

	# 9. Sharing that must still happen: unset uniforms equal explicit defaults; two
	#    nodes on one authored resource; the other node classes at default content.
	c = _cell("bare material, no params set\n(shares defaults)")
	_bare_param_sprite = _sprite("BareParams")
	var bare := ShaderMaterial.new()
	bare.shader = _fast_shader
	_bare_param_sprite.material = bare
	_place(_bare_param_sprite, c)
	_default_members.append(_bare_param_sprite)
	c = _cell("two nodes, one authored\nmaterial (share, authored untouched)")
	_shared_authored = ShaderMaterial.new()
	_shared_authored.shader = _fast_shader
	_shared_a = _sprite("SharedAuthoredA")
	_shared_a.material = _shared_authored
	_shared_b = _sprite("SharedAuthoredB")
	_shared_b.material = _shared_authored
	_place(_shared_a, c, Vector2(-40, 0))
	_place(_shared_b, c, Vector2(40, 0))
	_default_members.append(_shared_a)
	_default_members.append(_shared_b)
	c = _cell("default tilemap + animated\n(share with the defaults)")
	_tm_default = _tilemap("TilemapDefault", _tileset(false), 3, 2)
	_place(_tm_default, c, Vector2(-90, -32))
	_anim = LitAnimatedSprite2D.new()
	_anim.name = "Animated"
	var sf := SpriteFrames.new()
	var ct_plain := CanvasTexture.new()
	ct_plain.diffuse_texture = _diffuse
	var ct_spec := CanvasTexture.new()
	ct_spec.diffuse_texture = _diffuse
	ct_spec.specular_texture = _white
	sf.add_frame("default", ct_plain)
	sf.add_frame("default", ct_spec)
	_anim.sprite_frames = sf
	_anim.frame = 0
	_place(_anim, c, Vector2(50, 0))
	_default_members.append(_tm_default)
	_default_members.append(_anim)

	# 10. A plain Sprite2D on a receiver material: bare receivers are not pooled.
	c = _cell("plain Sprite2D + lit material\n(bare receiver, untouched)")
	_bare_sprite = Sprite2D.new()
	_bare_sprite.name = "BareSprite"
	var bct := CanvasTexture.new()
	bct.diffuse_texture = _diffuse
	_bare_sprite.texture = bct
	_bare_mat = ShaderMaterial.new()
	_bare_mat.shader = _fast_shader
	_bare_sprite.material = _bare_mat
	_place(_bare_sprite, c)

	# 11. Authored on the full (self-exclusion) entry shader: the tier is part of the
	#     key, so this sits in its own entry even though it is driven to fast.
	c = _cell("authored on full-tier shader\n(own entry: tier keyed)")
	_full_sprite = _sprite("FullTier")
	_full_sprite.material.shader = _full_shader
	_place(_full_sprite, c)

	# 12. Local to Scene through PackedScene: Godot hands each instance its own copy.
	c = _cell("PackedScene x2, local_to_scene\n(own copies, never pooled)")
	var proto := _sprite("Proto")
	proto.material.resource_local_to_scene = true
	var packed := PackedScene.new()
	packed.pack(proto)
	proto.free()
	_inst_a = packed.instantiate()
	_inst_b = packed.instantiate()
	_place(_inst_a, c, Vector2(-40, 0))
	_place(_inst_b, c, Vector2(40, 0))

	# 13. Subjects for the runtime phases (defaults beyond index 7 are reserved).
	c = _cell("runtime subjects: swap / free /\nforeign-material writes")
	_swap_sprite = _sprite("SwapMaterial")
	_free_sprite = _sprite("FreedLater")
	_foreign_a = _sprite("ForeignA")
	_foreign_a.emissive_strength = 0.11
	_foreign_b = _sprite("ForeignB")
	_place(_swap_sprite, c, Vector2(-70, 0), 0.6)
	_place(_free_sprite, c, Vector2(-23, 0), 0.6)
	_place(_foreign_a, c, Vector2(23, 0), 0.6)
	_place(_foreign_b, c, Vector2(70, 0), 0.6)
	for s in [_swap_sprite, _free_sprite, _foreign_b]:
		_default_members.append(s)


# --- Checks: static ----------------------------------------------------------------

func _static_checks() -> void:
	var d0: ShaderMaterial = _defaults[0].material

	# identical_share
	var all_same := true
	for s in _defaults:
		all_same = all_same and is_same(s.material, d0)
	_check("identical_share", "%d identical sprites hold one material" % DEFAULT_COUNT, true, all_same)
	_check("identical_share", "that material is a pool entry", true, _pooled(d0))
	_check("identical_share", "authored material was replaced, not mutated (different object)", false,
			is_same(_authored_default, d0))
	_check("identical_share", "authored material is not itself in the pool", false, _pooled(_authored_default))
	var members_ok := true
	for m in _default_members:
		members_ok = members_ok and is_same(m.material, d0)
	_check("identical_share", "every default-content node (incl. tilemap, animated, bare-param, shared-authored) shares it",
			true, members_ok)
	_check("identical_share", "default entry refcount == its %d members" % _default_members.size(),
			_default_members.size(), _refs_of(d0))

	# scalar_split
	var distinct := {}
	for p in _splits:
		var s: LitSprite2D = _splits[p]
		_check("scalar_split", "%s=%s sprite is pooled" % [p, str(SCALAR_SPLITS[p])], true, _pooled(s.material))
		_check("scalar_split", "%s=%s sprite does not share the default entry" % [p, str(SCALAR_SPLITS[p])],
				false, is_same(s.material, d0))
		_check("scalar_split", "%s on the split sprite's material" % p, SCALAR_SPLITS[p],
				s.material.get_shader_parameter(p))
		_check("scalar_split", "%s on the default entry unchanged" % p, _default_vals[p],
				d0.get_shader_parameter(p))
		distinct[s.material] = true
	_check("scalar_split", "11 split sprites landed in 11 distinct entries", 11, distinct.size())

	# emissive_mask_split (the user's report)
	_check("emissive_mask_split", "B (0.5, no mask) shares A's (0.5 + checker) material", false,
			is_same(_mask_b.material, _mask_a.material))
	_check("emissive_mask_split", "B's runtime material emissive_mask", null,
			_mask_b.material.get_shader_parameter("emissive_mask"))
	_check("emissive_mask_split", "A's runtime material keeps the checker mask", _checker,
			_mask_a.material.get_shader_parameter("emissive_mask"))
	_check("emissive_mask_split", "C (0.5 + stripes) shares A's (0.5 + checker) material", false,
			is_same(_mask_c.material, _mask_a.material))
	_check("emissive_mask_split", "C's runtime material keeps the stripes mask", _stripes,
			_mask_c.material.get_shader_parameter("emissive_mask"))

	# tilemap_key_repro (the user's exact setup)
	_check("tilemap_key_repro", "key sprite (0.5, no mask) shares the tilemap's (0.5 + mask) material",
			false, is_same(_key_sprite.material, _tm_mask.material))
	_check("tilemap_key_repro", "key sprite's runtime material emissive_mask", null,
			_key_sprite.material.get_shader_parameter("emissive_mask"))
	_check("tilemap_key_repro", "tilemap's runtime material keeps its mask", _checker,
			_tm_mask.material.get_shader_parameter("emissive_mask"))
	_check("tilemap_key_repro", "key sprite and B (same content) share one entry", true,
			is_same(_key_sprite.material, _mask_b.material))

	# texture_uniform_split
	for u in _map_sprites:
		var s: LitSprite2D = _map_sprites[u]
		_check("texture_uniform_split", "sprite with only %s set shares the default entry" % u, false,
				is_same(s.material, d0))
		_check("texture_uniform_split", "default entry's %s" % u, null, d0.get_shader_parameter(u))
		_check("texture_uniform_split", "the %s sprite keeps its map" % u, true,
				s.material.get_shader_parameter(u) != null)

	# has_specular_map_split
	_check("has_specular_map_split", "specular-map sprite shares the default entry", false,
			is_same(_spec_sprite.material, d0))
	_check("has_specular_map_split", "specular-map sprite has_specular_map", true,
			_spec_sprite.material.get_shader_parameter("has_specular_map"))
	_check("has_specular_map_split", "default entry has_specular_map", false,
			d0.get_shader_parameter("has_specular_map"))

	# opt-outs
	_check("local_to_scene_opt_out", "material object unchanged after ready", true,
			is_same(_local_sprite.material, _local_authored))
	_check("local_to_scene_opt_out", "not pooled", false, _pooled(_local_sprite.material))
	_check("custom_shader_opt_out", "material object unchanged after ready", true,
			is_same(_custom_sprite.material, _custom_mat))
	_check("custom_shader_opt_out", "not pooled", false, _pooled(_custom_sprite.material))
	_check("null_shader_opt_out", "material object unchanged after ready", true,
			is_same(_nullsh_sprite.material, _nullsh_mat))
	_check("null_shader_opt_out", "not pooled", false, _pooled(_nullsh_sprite.material))
	_check("bare_receiver", "plain Sprite2D keeps its authored material", true,
			is_same(_bare_sprite.material, _bare_mat))
	_check("bare_receiver", "plain Sprite2D material not pooled", false, _pooled(_bare_mat))

	# per-node uniforms detach
	_check("rx_mask_unique", "rx sprite not pooled", false, _pooled(_rx_sprite.material))
	_check("rx_mask_unique", "rx sprite rx_mask", 2, _int(_rx_sprite.material.get_shader_parameter("rx_mask")))
	_check("rx_mask_unique", "rx sprite on an rx shader variant", true,
			LitShaderLibrary.flags_of(_rx_sprite.material.shader) & LitShaderLibrary.F_RX != 0)
	_check("rx_mask_unique", "default entry rx_mask stays 0", 0, _int(d0.get_shader_parameter("rx_mask")))
	_check("occluder_unique", "occluder sprite not pooled", false, _pooled(_occ_sprite.material))
	_check("occluder_unique", "occluder sprite self_rect_count", 1,
			_int(_occ_sprite.material.get_shader_parameter("self_rect_count")))
	_check("occluder_unique", "default entry self_rect_count stays 0", 0,
			_int(d0.get_shader_parameter("self_rect_count")))
	_check("tile_occluder_unique", "occlusion tilemap not pooled", false, _pooled(_tm_occ.material))
	_check("tile_occluder_unique", "occlusion tilemap self_rect_count > 0", true,
			_int(_tm_occ.material.get_shader_parameter("self_rect_count")) > 0)

	# sharing that must still happen
	_check("null_vs_default", "bare (no params) material joined the default entry", true,
			is_same(_bare_param_sprite.material, d0))
	_check("shared_authored", "two nodes on one authored material share one pooled entry", true,
			is_same(_shared_a.material, _shared_b.material))
	_check("shared_authored", "authored material not pooled", false, _pooled(_shared_authored))
	_check("shared_authored", "authored material not the runtime one", false,
			is_same(_shared_authored, _shared_a.material))
	_check("cross_type_share", "default LitTileMapLayer shares the default entry", true,
			is_same(_tm_default.material, d0))
	_check("cross_type_share", "default LitAnimatedSprite2D (plain frame) shares the default entry", true,
			is_same(_anim.material, d0))
	_check("tier_split", "full-tier authored sprite is pooled", true, _pooled(_full_sprite.material))
	_check("tier_split", "full-tier authored sprite shares the fast-tier default entry (tier keyed: no)",
			false, is_same(_full_sprite.material, d0))
	_check("tier_split", "full-tier sprite without occluders was driven to the fast tier", 0,
			LitShaderLibrary.flags_of(_full_sprite.material.shader) & LitShaderLibrary.TIER_MASK)
	_check("local_to_scene_instances", "two instances hold different materials", false,
			is_same(_inst_a.material, _inst_b.material))
	_check("local_to_scene_instances", "instance A not pooled", false, _pooled(_inst_a.material))
	_check("local_to_scene_instances", "instance B not pooled", false, _pooled(_inst_b.material))

	# key_coverage: every uniform the shader declares is either keyed or known-driven.
	for u in _fast_shader.get_shader_uniform_list():
		var n: String = u.name
		_check("key_coverage", "uniform '%s' is keyed or driven" % n, true,
				LitLightRegistry.pool_is_key_param(n) or POOL_DRIVEN.has(n))
	for n in POOL_DRIVEN:
		_check("key_coverage", "driven uniform '%s' is not in the key" % n, false,
				LitLightRegistry.pool_is_key_param(n))

	_integrity("static")


# --- Checks: runtime mutations ------------------------------------------------------

func _mutations_a() -> void:
	var d0: ShaderMaterial = _defaults[0].material
	var s1: LitSprite2D = _defaults[1]
	var s2: LitSprite2D = _defaults[2]
	var s3: LitSprite2D = _defaults[3]
	var s4: LitSprite2D = _defaults[4]
	var s5: LitSprite2D = _defaults[5]
	var s6: LitSprite2D = _defaults[6]
	var s7: LitSprite2D = _defaults[7]

	# rekey_on_edit
	var refs := _refs()
	var entries := _entries()
	s1.emissive_strength = 0.25
	_check("rekey_on_edit", "s1 left the shared entry after emissive_strength=0.25", false,
			is_same(s1.material, d0))
	_check("rekey_on_edit", "s1 still pooled", true, _pooled(s1.material))
	_check("rekey_on_edit", "s1 material emissive_strength", 0.25,
			s1.material.get_shader_parameter("emissive_strength"))
	_check("rekey_on_edit", "poolmate s0 emissive_strength unchanged", 0.0,
			d0.get_shader_parameter("emissive_strength"))
	_check("rekey_on_edit", "total refs conserved across a re-key", refs, _refs())
	_check("rekey_on_edit", "one new entry", entries + 1, _entries())
	s1.emissive_strength = 0.0
	_check("rekey_on_edit", "s1 rejoined the shared entry after emissive_strength=0.0", true,
			is_same(s1.material, d0))
	_check("rekey_on_edit", "the emptied entry was freed", entries, _entries())

	# rekey_converge
	s2.emissive_strength = 0.7
	_check("rekey_converge", "s2 joined the existing emissive_strength=0.7 entry", true,
			is_same(s2.material, _splits["emissive_strength"].material))
	_check("rekey_converge", "total refs conserved", refs, _refs())
	s2.emissive_strength = 0.0

	# rekey_keeps_textures
	_mask_a.emissive_strength = 0.6
	_check("rekey_keeps_textures", "A re-keyed to 0.6 still carries the checker mask", _checker,
			_mask_a.material.get_shader_parameter("emissive_mask"))
	_check("rekey_keeps_textures", "B untouched by A's re-key (emissive_strength)", 0.5,
			_mask_b.material.get_shader_parameter("emissive_strength"))
	_check("rekey_keeps_textures", "B untouched by A's re-key (no mask)", null,
			_mask_b.material.get_shader_parameter("emissive_mask"))
	_mask_a.emissive_strength = 0.5

	# rx_runtime_detach
	refs = _refs()
	s3.shadow_ignore_mask = 4
	_check("rx_runtime_detach", "s3 left the pool after shadow_ignore_mask=4", false, _pooled(s3.material))
	_check("rx_runtime_detach", "s3 material rx_mask", 4, _int(s3.material.get_shader_parameter("rx_mask")))
	_check("rx_runtime_detach", "default entry rx_mask stays 0", 0, _int(d0.get_shader_parameter("rx_mask")))
	_check("rx_runtime_detach", "refs dropped by one", refs - 1, _refs())
	s3.shadow_ignore_mask = 0
	_check("rx_runtime_detach", "s3 stays private after clearing the mask", false, _pooled(s3.material))
	_check("rx_runtime_detach", "default entry rx_mask still 0", 0, _int(d0.get_shader_parameter("rx_mask")))

	# make_material_unique
	refs = _refs()
	var m := s4.make_material_unique()
	_check("make_material_unique", "returned material is s4's material", true, is_same(m, s4.material))
	_check("make_material_unique", "not pooled", false, _pooled(m))
	_check("make_material_unique", "refs dropped by one", refs - 1, _refs())
	m.set_shader_parameter("emissive_strength", 0.9)
	_check("make_material_unique", "raw write on the private material does not reach s0", 0.0,
			d0.get_shader_parameter("emissive_strength"))
	_check("make_material_unique", "second call returns the same material", true,
			is_same(s4.make_material_unique(), m))

	# specular_runtime_rekey
	refs = _refs()
	(s5.texture as CanvasTexture).specular_texture = _white
	_check("specular_runtime_rekey", "assigning a specular map re-keyed s5 into the specular entry", true,
			is_same(s5.material, _spec_sprite.material))
	(s5.texture as CanvasTexture).specular_texture = null
	_check("specular_runtime_rekey", "clearing it rejoined the default entry", true, is_same(s5.material, d0))
	_check("specular_runtime_rekey", "refs conserved", refs, _refs())

	# exit_reenter
	refs = _refs()
	var parent := s6.get_parent()
	parent.remove_child(s6)
	parent.add_child(s6)
	_check("exit_reenter", "same material after leaving and re-entering the tree", true, is_same(s6.material, d0))
	_check("exit_reenter", "no double acquire (refs unchanged)", refs, _refs())

	# animated_frame_rekey
	refs = _refs()
	_anim.frame = 1
	_check("animated_frame_rekey", "specular frame left the default entry", false, is_same(_anim.material, d0))
	_check("animated_frame_rekey", "specular frame joined the specular entry", true,
			is_same(_anim.material, _spec_sprite.material))
	_anim.frame = 0
	_check("animated_frame_rekey", "plain frame rejoined the default entry", true, is_same(_anim.material, d0))
	_check("animated_frame_rekey", "refs conserved", refs, _refs())

	# duplicate_pooled
	refs = _refs()
	_dup_pooled = _defaults[0].duplicate()
	_dup_pooled.name = "DupOfDefault"
	_dup_pooled.position += Vector2(0, 44)
	_exhibits.add_child(_dup_pooled)
	_tag_for(_dup_pooled)
	_check("duplicate_pooled", "duplicate() of a pooled node shares its entry", true,
			is_same(_dup_pooled.material, d0))
	_check("duplicate_pooled", "refs grew by one", refs + 1, _refs())
	_default_members.append(_dup_pooled)

	# duplicate_unique (evaluated once its occluder cache has rebuilt)
	_dup_unique = _occ_sprite.duplicate()
	_dup_unique.name = "DupOfOccluder"
	_dup_unique.position += Vector2(70, 0)
	_exhibits.add_child(_dup_unique)
	_tag_for(_dup_unique)

	# occluder_added_runtime (evaluated next phase)
	s7.add_child(_occluder(Vector2(0, 24)))

	# foreign_material_write: ForeignB (default entry) is handed ForeignA's pooled
	# material (its own 0.11 entry) by hand, then edited through a proxy. A's entry
	# must keep exactly A's reference, and B's stale hold on the default entry must go.
	var a_mat: ShaderMaterial = _foreign_a.material
	var default_refs := _refs_of(d0)
	_foreign_b.material = a_mat
	_foreign_b.emissive_strength = 0.15
	_check("foreign_material_write", "writing through a hand-assigned pooled material does not reach its owner",
			0.11, a_mat.get_shader_parameter("emissive_strength"))
	_check("foreign_material_write", "owner still on its entry, still pooled", true,
			is_same(_foreign_a.material, a_mat) and _pooled(a_mat))
	_check("foreign_material_write", "owner's entry refcount stays 1", 1, _refs_of(a_mat))
	_check("foreign_material_write", "the writer moved to a material of its own", false,
			is_same(_foreign_b.material, a_mat))
	_check("foreign_material_write", "writer's material emissive_strength", 0.15,
			_foreign_b.material.get_shader_parameter("emissive_strength"))
	_check("foreign_material_write", "writer's stale hold on the default entry released", default_refs - 1,
			_refs_of(d0))
	_default_members.erase(_foreign_b)

	# material_swap_leak + free_releases (evaluated next phase, after the frees land)
	_refs_before_frees = _refs()
	_entry_before_frees = d0
	var swapped := ShaderMaterial.new()
	swapped.shader = _fast_shader
	_swap_sprite.material = swapped
	_swap_sprite.queue_free()
	_free_sprite.queue_free()
	_default_members.erase(_swap_sprite)
	_default_members.erase(_free_sprite)

	# activity_repoint: turn on a cone-traced shadow light (evaluated next phase)
	_shadow_light.shadow_enabled = true


func _mutations_b() -> void:
	var d0: ShaderMaterial = _defaults[0].material
	var s7: LitSprite2D = _defaults[7]

	_check("occluder_added_runtime", "s7 left the pool once it owned an occluder", false, _pooled(s7.material))
	_check("occluder_added_runtime", "s7 self_rect_count", 1, _int(s7.material.get_shader_parameter("self_rect_count")))
	_check("occluder_added_runtime", "default entry self_rect_count stays 0", 0,
			_int(d0.get_shader_parameter("self_rect_count")))
	_default_members.erase(s7)
	_default_members.erase(_defaults[3])
	_default_members.erase(_defaults[4])

	_check("duplicate_unique", "duplicate() of a private (occluder) node got its own material", false,
			is_same(_dup_unique.material, _occ_sprite.material))
	_check("duplicate_unique", "the duplicate is private too", false, _pooled(_dup_unique.material))
	_check("duplicate_unique", "duplicate self_rect_count", 1,
			_int(_dup_unique.material.get_shader_parameter("self_rect_count")))

	# Two frees (the material-swapped one included) plus s7's occluder detach above.
	_check("free_releases", "two frees (swapped one included) + s7's detach dropped the refs by three",
			_refs_before_frees - 3, _refs())
	_check("free_releases", "default entry refcount == live members", _default_members.size(),
			_refs_of(d0))

	_check("activity_repoint", "cone light on: the shared entry moved to the cone variant", true,
			LitShaderLibrary.flags_of(d0.shader) & LitShaderLibrary.F_CONE != 0)
	var all_same := true
	for m in _default_members:
		all_same = all_same and is_same(m.material, d0)
	_check("activity_repoint", "members still share one material after the variant swap", true, all_same)
	_defaults[0].emissive_strength = 0.33
	_check("activity_repoint", "a re-key while the cone variant is active lands on a cone-variant entry", true,
			LitShaderLibrary.flags_of(_defaults[0].material.shader) & LitShaderLibrary.F_CONE != 0)
	_defaults[0].emissive_strength = 0.0
	_check("activity_repoint", "and back to the shared entry", true, is_same(_defaults[0].material, d0))
	_shadow_light.shadow_enabled = false

	_integrity("mutations")


# --- Pool introspection -------------------------------------------------------------

func _integrity(tag: String) -> void:
	var snap: Dictionary = LitLightRegistry.pool_snapshot()
	var by_mat := {}
	var pooled_nodes := 0
	for n in _lit_nodes():
		var mat = n.material
		if _pooled(mat):
			pooled_nodes += 1
			by_mat[mat] = by_mat.get(mat, 0) + 1
	var stats: Dictionary = LitLightRegistry.pool_stats()
	var case_name := "integrity_" + tag
	_check(case_name, "pool refs == pooled Lit nodes in the tree", pooled_nodes, stats.refs)
	_check(case_name, "entries == snapshot size", snap.size(), stats.entries)
	for key in snap:
		var e: Dictionary = snap[key]
		_check(case_name, "entry %s refcount == its holders" % _label(e.material),
				by_mat.get(e.material, 0), e.refs)
	for mat in by_mat:
		var found := false
		for key in snap:
			found = found or is_same(snap[key].material, mat)
		_check(case_name, "held material %s is a live entry" % _label(mat), true, found)


func _dump_pool(title: String) -> void:
	var snap: Dictionary = LitLightRegistry.pool_snapshot()
	print("POOLBENCH ---- pool entries %s: %s ----" % [title, _stats_text()])
	var members := {}
	for n in _lit_nodes():
		if _pooled(n.material):
			if not members.has(n.material):
				members[n.material] = []
			members[n.material].append(n.name)
	var keys := snap.keys()
	keys.sort()
	for key in keys:
		var e: Dictionary = snap[key]
		var mat: ShaderMaterial = e.material
		var flags: int = LitShaderLibrary.flags_of(mat.shader)
		print("POOLBENCH   %s refs=%d variant=%s members=%s" % [_label(mat), e.refs,
				LitShaderLibrary.variant_name(flags), str(members.get(mat, []))])
		print("POOLBENCH     key=%s" % key)


func _summary() -> void:
	var failed := 0
	var by_case := {}
	for r in _results:
		if not r.pass:
			failed += 1
			by_case[r.case] = by_case.get(r.case, 0) + 1
	print("POOLBENCH SUMMARY checks=%d passed=%d failed=%d" % [_results.size(), _results.size() - failed, failed])
	for c in by_case:
		print("POOLBENCH   failing case: %s (%d)" % [c, by_case[c]])


func _print_uniforms() -> void:
	var names := PackedStringArray()
	for u in _fast_shader.get_shader_uniform_list():
		names.append(u.name)
	print("POOLBENCH receiver uniforms (%d): %s" % [names.size(), ", ".join(names)])


# --- Check plumbing ------------------------------------------------------------------

func _check(case_name: String, desc: String, expected, actual) -> bool:
	var ok := _eq(expected, actual)
	_results.append({"case": case_name, "desc": desc, "expected": _fmt(expected), "actual": _fmt(actual), "pass": ok})
	print("POOLBENCH %s %s: %s | expected=%s actual=%s" % ["PASS" if ok else "FAIL", case_name, desc,
			_fmt(expected), _fmt(actual)])
	return ok


func _eq(a, b) -> bool:
	if a is Object or b is Object:
		return is_same(a, b)
	if a == null or b == null:
		return a == null and b == null
	return a == b


func _fmt(v) -> String:
	if v == null:
		return "null"
	if v is ShaderMaterial:
		return _label(v)
	if v is Texture2D:
		return _tex_names.get(v, "texture")
	return str(v)


func _label(mat) -> String:
	if mat == null:
		return "null"
	if not _mat_labels.has(mat):
		_mat_labels[mat] = "M%d" % (_mat_labels.size() + 1)
	return _mat_labels[mat]


func _pooled(mat) -> bool:
	return LitLightRegistry.pool_is_pooled(mat)


func _refs() -> int:
	return LitLightRegistry.pool_stats().refs


func _entries() -> int:
	return LitLightRegistry.pool_stats().entries


func _refs_of(mat: ShaderMaterial) -> int:
	for e in LitLightRegistry.pool_snapshot().values():
		if is_same(e.material, mat):
			return e.refs
	return 0


func _int(v) -> int:
	return 0 if v == null else int(v)


func _stats_text() -> String:
	var s: Dictionary = LitLightRegistry.pool_stats()
	return "entries=%d refs=%d" % [s.entries, s.refs]


func _lit_nodes() -> Array:
	var out: Array = []
	_collect_lit(get_tree().root, out)
	return out


func _collect_lit(node: Node, acc: Array) -> void:
	if node.has_method("make_material_unique") and node is CanvasItem and not node.is_queued_for_deletion():
		acc.append(node)
	for child in node.get_children():
		_collect_lit(child, acc)


# --- Scene building ----------------------------------------------------------------

func _build_environment() -> void:
	var cm := LitCanvasModulate.new()
	cm.color = Color(0.10, 0.10, 0.12)
	add_child(cm)
	_light = LitPointLight2D.new()
	_light.position = Vector2(700, 520)
	_light.range = 1500.0
	_light.energy = 0.7
	_light.height = 300.0
	add_child(_light)
	# Cone-traced shadow light, off until the activity phase; needs an occluder in the
	# scene (the owned-occluder exhibit provides one).
	_shadow_light = LitPointLight2D.new()
	_shadow_light.position = Vector2(300, 900)
	_shadow_light.range = 400.0
	_shadow_light.energy = 0.3
	_shadow_light.shadow_enabled = false
	_shadow_light.shadow_algorithm = LitPointLight2D.ShadowAlgorithm.CONE_TRACED
	add_child(_shadow_light)
	_exhibits = Node2D.new()
	_exhibits.name = "Exhibits"
	add_child(_exhibits)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_stats = Label.new()
	_stats.position = Vector2(20, 12)
	_stats.add_theme_font_size_override("font_size", 18)
	layer.add_child(_stats)
	var panel := PanelContainer.new()
	panel.position = Vector2(HUD_X, 44)
	panel.size = Vector2(1920 - HUD_X - 12, 1080 - 56)
	layer.add_child(panel)
	_hud = RichTextLabel.new()
	_hud.bbcode_enabled = true
	_hud.scroll_active = true
	_hud.fit_content = false
	_hud.add_theme_font_size_override("normal_font_size", 12)
	_hud.text = "[b]Auto-pooling bench[/b]\nbuilding exhibits..."
	panel.add_child(_hud)


func _render_hud() -> void:
	var failed := 0
	for r in _results:
		if not r.pass:
			failed += 1
	var t := "[b]Auto-pooling bench[/b]   checks=%d  [color=#8f8]passed=%d[/color]  [color=#f88]failed=%d[/color]\n" \
			% [_results.size(), _results.size() - failed, failed]
	t += "[color=#aaa]phase: %s[/color]\n\n" % ("final" if _finished else ("mutations" if _frame >= 4 else "static"))
	if failed > 0:
		t += "[b]Failures[/b]\n"
		for r in _results:
			if not r.pass:
				t += "[color=#f88]FAIL[/color] %s: %s\n      expected %s, got %s\n" % [r.case, r.desc, r.expected, r.actual]
		t += "\n"
	t += "[b]Pool entries[/b]\n"
	var members := {}
	for n in _lit_nodes():
		if _pooled(n.material):
			if not members.has(n.material):
				members[n.material] = []
			members[n.material].append(n.name)
	for e in LitLightRegistry.pool_snapshot().values():
		t += "%s refs=%d %s: %s\n" % [_label(e.material), e.refs,
				LitShaderLibrary.variant_name(LitShaderLibrary.flags_of(e.material.shader)),
				", ".join(PackedStringArray(members.get(e.material, [])))]
	t += "\n[b]All checks[/b]\n"
	var last_case := ""
	for r in _results:
		if r.case != last_case:
			last_case = r.case
			t += "[color=#9cf]%s[/color]\n" % r.case
		t += "  %s %s [color=#888](%s / %s)[/color]\n" % ["[color=#8f8]ok[/color]" if r.pass else "[color=#f88]FAIL[/color]",
				r.desc, r.expected, r.actual]
	_hud.text = t


func _cell(title: String) -> int:
	var idx := _cell_index
	_cell_index += 1
	var l := Label.new()
	l.text = title
	l.position = _cell_pos(idx) + Vector2(4, 4)
	l.add_theme_font_size_override("font_size", 12)
	l.modulate = Color(0.85, 0.85, 0.9)
	_exhibits.add_child(l)
	return idx


func _cell_pos(idx: int) -> Vector2:
	return ORIGIN + Vector2(idx % COLS, floori(idx / float(COLS))) * CELL


func _place(node: Node2D, cell: int, offset := Vector2.ZERO, scale_f := 1.0) -> void:
	node.position = _cell_pos(cell) + Vector2(CELL.x * 0.5, CELL.y * 0.5 + 14) + offset
	node.scale = Vector2.ONE * scale_f
	_exhibits.add_child(node)
	_tag_for(node)


func _tag_for(node: Node2D) -> void:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 10)
	l.modulate = Color(1, 0.95, 0.6)
	l.position = node.position + Vector2(-30, 34 * node.scale.x)
	_exhibits.add_child(l)
	_tags.append([node, l])


func _update_tags() -> void:
	for t in _tags:
		var node = t[0]
		var l: Label = t[1]
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			l.text = "freed"
			continue
		var mat = node.material
		var pooled := _pooled(mat)
		l.text = _label(mat) if node.scale.x < 1.0 else "%s %s" % [_label(mat), "pooled" if pooled else "private"]
		l.modulate = Color(1, 0.95, 0.6) if pooled else Color(0.6, 0.9, 1.0)


func _sprite(node_name: String) -> LitSprite2D:
	var s := LitSprite2D.new()
	s.name = node_name
	var ct := CanvasTexture.new()
	ct.diffuse_texture = _diffuse
	s.texture = ct
	return s


func _tilemap(node_name: String, ts: TileSet, w: int, h: int) -> LitTileMapLayer:
	var tm := LitTileMapLayer.new()
	tm.name = node_name
	tm.tile_set = ts
	for y in h:
		for x in w:
			tm.set_cell(Vector2i(x, y), 0, Vector2i.ZERO)
	return tm


func _tileset(with_occluders: bool) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(32, 32)
	if with_occluders:
		ts.add_occlusion_layer()
	var src := TileSetAtlasSource.new()
	src.texture = _tile_tex
	src.texture_region_size = Vector2i(32, 32)
	src.create_tile(Vector2i.ZERO)
	ts.add_source(src, 0)
	if with_occluders:
		var td := src.get_tile_data(Vector2i.ZERO, 0)
		td.add_occluder_polygon(0)
		var poly := OccluderPolygon2D.new()
		poly.polygon = PackedVector2Array([Vector2(-14, -14), Vector2(14, -14), Vector2(14, 14), Vector2(-14, 14)])
		td.set_occluder_polygon(0, 0, poly)
	return ts


func _occluder(offset: Vector2) -> LightOccluder2D:
	var o := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-20, -5), Vector2(20, -5), Vector2(20, 5), Vector2(-20, 5)])
	o.occluder = poly
	o.position = offset
	return o


func _make_textures() -> void:
	_diffuse = _tex(64, func(x, y):
		return Color(0.25, 0.25, 0.3) if x < 3 or y < 3 or x > 60 or y > 60 else Color(0.75, 0.75, 0.8))
	_checker = _tex(64, func(x, y):
		return Color.WHITE if ((x / 16) + (y / 16)) % 2 == 0 else Color.BLACK)
	_stripes = _tex(64, func(_x, y):
		return Color.WHITE if (y / 8) % 2 == 0 else Color.BLACK)
	_grad_h = _tex(64, func(x, _y):
		return Color(x / 63.0, x / 63.0, x / 63.0))
	_grad_v = _tex(64, func(_x, y):
		return Color(y / 63.0, y / 63.0, y / 63.0))
	_radial = _tex(64, func(x, y):
		var d: float = clampf(1.0 - Vector2(x - 32, y - 32).length() / 32.0, 0.0, 1.0)
		return Color(d, d, d))
	_white = _tex(8, func(_x, _y):
		return Color.WHITE)
	_tile_tex = _tex(32, func(x, y):
		return Color(0.3, 0.22, 0.18) if x < 2 or y < 2 or x > 29 or y > 29 else Color(0.6, 0.5, 0.4))
	_tex_names = {_diffuse: "diffuse", _checker: "checker", _stripes: "stripes", _grad_h: "grad_h",
			_grad_v: "grad_v", _radial: "radial", _white: "white", _tile_tex: "tile"}


func _tex(size: int, fn: Callable) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			img.set_pixel(x, y, fn.call(x, y))
	return ImageTexture.create_from_image(img)
