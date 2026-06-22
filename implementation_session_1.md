# Lit — Implementation Session 1 (Summary & Handoff)

Companion to `plan.md`. This records what was actually built in session 1 (Phases 1–3
+ node icons), where the implementation **deviates from `plan.md`**, the gotchas
discovered while testing, and a ready-to-paste prompt to continue from Phase 4.

**Status:** Phases 1, 2, 3 are **code-complete and developer-verified in Godot 4.7
(Forward+)**. Next up: **Phase 4**.

The human (Shawn) does all in-editor testing; the agent cannot run Godot or see
rendered output. `human_steps.md` is the human's per-phase test guide.

---

## 1. What works today (verified)

- **Phase 1** — ambient/darkness via `LitCanvasModulate`, uncapped culled point
  lighting (diffuse + specular + emissive), normal-mapped via `CanvasTexture`,
  `render_mode unshaded`. Light transport = global shader uniforms + a per-frame
  float light-data texture (D1).
- **Phase 2** — per-light soft/hard shadows via IQ penumbra march of the native
  screen-space SDF (`texture_sdf` / `screen_uv_to_sdf`), `shadow_enabled` /
  `shadow_color` / `shadow_hardness`.
- **Phase 3** — `LitDirectionalLight2D` (sun) **and a new `LitSpotLight2D` (cone)**,
  both with shadows. All three light types compose correctly together.
- **Icons** — amber SVG icons for the three light nodes (`@icon`).

---

## 2. Deviations from `plan.md` (READ THIS FIRST)

The plan is the source of truth for intent, but the code intentionally differs here:

1. **A spotlight was added: `LitSpotLight2D`.** Not in `plan.md` at all (the plan only
   specs point + directional). The developer explicitly requested it (stock Godot 2D
   has no spotlight node). It's a point light masked to a cone.
2. **Light-data record is 5 texels/light, not 4** (plan §9.4 says 4). Texel 4 was
   added to carry the spot cone (`aim.xy`, `cos_outer`, `cos_inner`). Point and
   directional lights leave texel 4 zeroed. `TEXELS_PER_LIGHT = 5` in the registry.
3. **`light_mask` reuses the inherited `CanvasItem.light_mask`** on all three light
   nodes rather than a redeclared `@export` (redeclaring collides with the base
   class). The pack already writes it. **Phase 4 must promote this to a proper
   exposed control + add the receiver-side `receiver_mask` matching (§9.5).**
4. **Ambient global defaults to white `(1,1,1,1)` @ energy 1.0** when no
   `LitCanvasModulate` is present (so a Lit sprite looks normal with zero setup).
   `LitCanvasModulate` pushes the dark `#1a1a1a` only when added.
5. **Global shader params are registered two ways** in `lit_plugin.gd`: persisted in
   `ProjectSettings` (`shader_globals/*`, so shaders compile at engine init in editor
   *and* exports with no load-order race) **and** added live via `RenderingServer`
   for the current session. Removed both on deactivation.
6. **Specular** uses a sharpened **N·L** lobe (per §9.2's literal formula) **tinted by
   `light_color`** — NOT Blinn N·H. (Blinn was tried and caused whole-object blowout
   because every camera-facing pixel caught a highlight from every light.)
7. **Directional shadow march distance is self-calibrating** (screen-diagonal in SDF
   units × `directional_shadow_reach`), not a fixed constant. A fixed large distance
   under-sampled the penumbra and made `shadow_hardness` look like it did nothing.

---

## 3. Gotchas discovered (don't re-learn these the hard way)

- **Adding a new `class_name` requires `Project → Reload Current Project`.** Re-toggling
  the plugin is NOT enough to register a new global class. Critically: the autoloaded
  `LitManager` preloads `lit_light_registry.gd`, which references the light classes by
  `class_name`. If a newly-added light class isn't registered yet, the registry fails
  to compile → the autoload silently doesn't run → **all lights die** while ambient
  still works (because `LitCanvasModulate` sets its globals directly). Symptom looked
  like "everything broke, no errors." Fix = reload the project.
- `ImageTexture.get_size()` returns **Vector2**; `Image.get_size()` returns **Vector2i**.
  Comparing them directly is a runtime error — cast to one type.
- The light-data texture is read with `texelFetch` (integer coords), which **bypasses
  filtering** entirely, so the sampler's filter mode is irrelevant to correctness.
- **Screen-space SDF has no 2D draw-order / z-index.** A fragment inside an occluder's
  footprint is treated as "on top" (`lit_shadow` returns 1 if `texture_sdf(frag) <= 0`)
  so a sprite drawn over an occluder isn't self-shadowed. True z-ordered shadows are
  not possible with this technique.
- `SPECULAR_SHININESS.rgb` **defaults to white** when no specular map is set — specular
  must be multiplied by `light_color` or highlights blow out to white.
- `screen_uv_to_sdf()` and `texture_sdf()` **do work inside `fragment()`** (confirmed),
  not just `light()`. `screen_uv_to_sdf` is affine, so a direction in SDF space can be
  obtained by offsetting the UV and subtracting.
- `NORMAL` and `SPECULAR_SHININESS` **are readable in `fragment()` under
  `render_mode unshaded`** (confirmed) — `unshaded` only disables the `light()` pass.

---

## 4. Current file structure

```
addons/lit/
  plugin.cfg
  lit_plugin.gd                         # EditorPlugin: registers lit_* globals + adds LitManager autoload
  materials/
    lit_receiver_material.tres          # ready-made ShaderMaterial (drag onto any Sprite2D)
  nodes/
    lit_point_light_2d.gd               # LitPointLight2D  (Node2D)
    lit_directional_light_2d.gd         # LitDirectionalLight2D (Node2D, "sun")
    lit_spot_light_2d.gd                # LitSpotLight2D (Node2D, cone)  [NOT in plan]
    lit_canvas_modulate.gd              # LitCanvasModulate (Node2D, ambient source)
  runtime/
    lit_manager.gd                      # autoload; per-frame refresh() at runtime
    lit_light_registry.gd               # LitLightRegistry: gather/cull/pack (shared)
  shaders/
    lit_receiver.gdshader               # the receiver lighting shader
  icons/
    lit_point_light_2d.svg
    lit_directional_light_2d.svg
    lit_spot_light_2d.svg
```

Not yet created (Phase 4–6): `nodes/lit_sprite_2d.gd`, `nodes/lit_post_process.gd`,
post shaders, more icons.

---

## 5. Light-data texture encoding (CURRENT — 5 texels/light, `FORMAT_RGBAF`)

Width = `TEXELS_PER_LIGHT` (5), height = light count. Read with
`texelFetch(lit_light_data, ivec2(col, i), 0)`.

| Texel | r | g | b | a |
|---|---|---|---|---|
| 0 | uv.x **or** dir.x | uv.y **or** dir.y | range | energy |
| 1 | color.r | color.g | color.b | height |
| 2 | shadow_color.r | shadow_color.g | shadow_color.b | shadow_hardness |
| 3 | type | flags | light_mask | falloff |
| 4 | aim.x | aim.y | cos_outer | cos_inner | *(spot only; else 0)* |

- **type** (texel 3.r): `0 = point`, `1 = directional`, `2 = spot`. Decode `int(round(x))`.
- **flags** (texel 3.g): `float(shadow_enabled) + 2.0*float(subtractive)`. Decode
  `int f = int(round(g)); shadow = (f&1)!=0; subtract = (f&2)!=0;`. **Subtract is
  packed but NOT yet consumed in the shader (Phase 4).**
- **Position space:** point/spot pack a **screen-UV position** in texel 0; directional
  packs a **unit screen-space direction toward the light** (= `-node_+X`, via the canvas
  basis). Spot's aim (texel 4) = `node_+X` in screen space (direction the cone shines).
- **Cone:** `cos_outer = cos(spot_angle)`, `cos_inner = cos(spot_angle*(1-spot_softness))`,
  with `cos_inner` nudged strictly above `cos_outer`. Shader does
  `smoothstep(cos_outer, cos_inner, dot(aim, dir_light_to_frag))`.
- **Zero-light case:** count 0 + a 1×1 dummy texture (never a `5×0` image).

---

## 6. Global shader uniforms (registered by `lit_plugin.gd`)

| Name | Type | Notes |
|---|---|---|
| `lit_light_data` | sampler2D | the per-frame light texture |
| `lit_light_count` | int | default 0 |
| `lit_viewport_size` | vec2 | pixels |
| `lit_ambient_color` | color (vec4 : source_color) | default white |
| `lit_ambient_energy` | float | default 1.0 |

## 7. Per-material receiver uniforms (`lit_receiver.gdshader`)

`emissive_strength` (0), `emissive_mask` (hint_default_white), `specular_strength`
(0.5), `specular_k` (32), `shadow_steps` (64), `shadow_min_step` (0.2),
`directional_horizontal_scale` (32 — elevation feel), `directional_shadow_reach`
(1.0 — directional shadow length, in screen-diagonals).

---

## 8. Coordinate spaces (the one source of truth)

Canonical space = **normalized screen UV** (`SCREEN_UV`). Manager converts each light's
world position via `get_canvas_transform()` → screen px → `/viewport_size` → UV.
Diffuse math runs in **pixels** (`UV delta * lit_viewport_size`); shadows run in **SDF
space** (`screen_uv_to_sdf`). Directions for directional/spot are converted via the
canvas **basis** (`basis_xform`) so camera rotation/zoom carries through.

---

## 9. Node property summaries

- **LitPointLight2D** (Node2D): enabled, color, energy, range(256), falloff(1),
  texture/texture_scale *(inert in v1)*, height(16), shadow_enabled/shadow_color/
  shadow_hardness(0.5), blend_mode{Add,Subtract}. Group `lit_lights`.
- **LitDirectionalLight2D** (Node2D): enabled, color, energy, height(16),
  shadow_*, blend_mode. Rotation = direction the light travels/aims. Group `lit_lights`.
- **LitSpotLight2D** (Node2D): enabled, color, energy, range(256), falloff(1),
  spot_angle(30°, half-angle), spot_softness(0.5), height(16), shadow_*, blend_mode.
  Rotation = cone aim. Group `lit_lights`.
- **LitCanvasModulate** (Node2D): color(`#1a1a1a`), ambient_energy(1). Writes
  `lit_ambient_color`/`lit_ambient_energy` globals on enter/change (works at edit time
  too). Warns if a native `CanvasModulate` is present or if multiple instances exist.
  Group `lit_canvas_modulate`.

All light nodes reuse the inherited `CanvasItem.light_mask` for now (Phase 4 work).

---

## 10. Remaining work

**Phase 4 — Workflow + editor-live (NEXT):**
- `LitSprite2D` (Sprite2D pre-wired with the receiver material + a CanvasTexture).
- "Make Selected Sprites Lit" editor tool (batch-assign material, wrap texture in
  CanvasTexture) on `lit_plugin.gd`.
- **Light mask system (§9.5):** promote `light_mask` to a real exposed control on all
  light nodes; add a per-material `receiver_mask` uniform on the receiver; pack/compare
  `(light_mask & receiver_mask) != 0` in-shader (the `light_mask` field is already in
  texel 3.b — just needs the receiver side + in-loop skip).
- **Subtract blend mode:** the `subtractive` flag is already packed (flags bit 1); wire
  it in the receiver loop (`lit -= contribution` instead of `+=`).
- **Editor-live preview:** drive `LitLightRegistry.refresh()` from `lit_plugin.gd` on a
  short timer + `NOTIFICATION_TRANSFORM_CHANGED`/property signals, so moving a light
  relights the 2D viewport without running the game. (Autoloads don't run in-editor; the
  EditorPlugin is the editor-side driver. `refresh()` is already written to be shared.)

**Phase 5 — Post-processing:** `LitPostProcess` (CanvasLayer) with a ColorRect pass
chain (bloom/grade/threshold/vignette), `BackBufferCopy` between passes (D8).

**Phase 6 — Packaging:** finalize `plugin.cfg`, icons for `LitCanvasModulate`/
`LitSprite2D`/`LitPostProcess`, README, example scene(s), Asset Library metadata.
Update `plan.md` (or note in README) to reflect the spotlight + 5-texel encoding.

---

## 11. Working rhythm

- One phase (or sub-step) at a time. The human verifies in-editor, then commits, then
  says proceed. Report findings as observations; the agent debugs from those.
- After any `class_name` change, the human must **reload the project**.
- Keep edits surgical; the receiver shader and the registry are the two hot files.

---

## 12. Prompt to give the next agent

> This is a Godot 4.7 (Forward+) project implementing **Lit**, a drop-in 2D lighting
> plugin. Read **`plan.md`** in full first (the original implementation spec), then read
> **`implementation_session_1.md`** (what's actually been built so far and where it
> deviates from the plan). `human_steps.md` is my in-editor test guide.
>
> Phases 1–3 are complete and verified: ambient/darkness, uncapped point lights,
> SDF soft shadows, directional ("sun") lights, and a spotlight (added beyond the
> plan — see the deviations section). The light-data texture is now 5 texels/light.
>
> Important constraints:
> - **You cannot run Godot or see rendered output.** I do all in-editor testing and
>   report back — never assume something renders correctly or claim you tested it.
> - Work **one phase (or sub-step) at a time**, stop, and give me a short in-editor
>   verification checklist before continuing.
> - Honor the committed decisions in `plan.md §5` and the deviations already made in
>   `implementation_session_1.md §2` — don't re-litigate or silently undo them.
> - After any change that adds/renames a `class_name`, remind me to reload the project.
>
> Start **Phase 4** from `plan.md §11` (workflow + editor-live preview), using the
> Phase-4 breakdown in `implementation_session_1.md §10`. I'd suggest doing it in two
> sub-steps: (a) light-mask system + Subtract blend mode + `LitSprite2D` + the "Make
> Selected Sprites Lit" tool, then (b) editor-live preview. Begin when ready.
