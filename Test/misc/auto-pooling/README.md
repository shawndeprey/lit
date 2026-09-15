# Auto-pooling bench

Runtime bench for the receiver material pool (`addons/lit/runtime/registry/material_pool.gd`):
which receiver configurations must get their own runtime material, which are allowed to
share one, and whether the pool's refcounts stay honest through everything a game does at
runtime.

Run it windowed (the headless renderer never compiles shaders):

```
godot --path . res://Test/misc/auto-pooling/auto_pooling_bench.tscn
godot --path . res://Test/misc/auto-pooling/auto_pooling_bench.tscn -- quit=on
godot --path . res://Test/misc/auto-pooling/auto_pooling_bench.tscn -- capture=/tmp/pool.png
```

Every check prints one `POOLBENCH PASS|FAIL <case>: <what> | expected=.. actual=..` line, the
pool's compiled entries (material label, refcount, variant, member nodes, key) are dumped
after the static build and at the end, and `POOLBENCH SUMMARY` closes the run. The HUD on the
right shows the same, and every exhibit carries a live tag (`M3 pooled`, `M9 private`) so the
sharing can be watched on screen. Escape quits.

## What it covers

Static (built at ready, checked on frame 3):

- identical defaults share one entry; the authored material is replaced, never mutated
- one sprite per scalar proxy: 11 distinct entries, no bleed into the default entry
- the user report: equal `emissive_strength`, different `emissive_mask` textures (sprite vs
  sprite, and the exact tilemap-with-mask vs mobile-sprite-without setup)
- `metallic_map` / `roughness_map` / `ao_map` set only on the material
- `has_specular_map` via the CanvasTexture specular slot
- opt-outs: `resource_local_to_scene`, custom shader, null shader, bare `Sprite2D`
- per-node uniforms detach: `shadow_ignore_mask`, an owned `LightOccluder2D`, occlusion tiles
- sharing that must survive: unset uniforms vs explicit defaults, two nodes on one authored
  resource, `LitTileMapLayer` / `LitAnimatedSprite2D` at default content, the full-tier
  authored shader (own entry, tier keyed), `PackedScene` instances with a local-to-scene material
- key coverage: every uniform the receiver shader declares is either keyed or known-driven

Runtime (frames 4 and 8):

- proxy edit re-keys (leave, rejoin, converge onto an existing entry), refs conserved
- a re-key keeps texture uniforms
- `shadow_ignore_mask` set at runtime, `make_material_unique()`, a specular map assigned at
  runtime, leaving and re-entering the tree, `LitAnimatedSprite2D` frame changes
- `duplicate()` of a pooled node and of a private (occluder) node
- an occluder added at runtime
- a node handed another node's pooled material by hand, then edited through a proxy
- a runtime `material` swap followed by `queue_free`, plus a plain free
- a cone-traced shadow light toggled on and off (variant re-pointing on shared entries)
- refcount integrity after every phase: refs == pooled nodes, per-entry refs == holders
