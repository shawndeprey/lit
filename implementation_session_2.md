# Lit — Implementation Session 2 (Summary & Handoff)

Companion to `plan.md` and `implementation_session_1.md`. This records everything
built in session 2 — **Phase 4 (workflow + editor-live)** and **Phase 5
(post-processing)**, plus the first post-v1 filter (**LUT**) and a filter backlog —
with the deviations, decisions, and gotchas, and a ready-to-paste prompt to continue.

**Status:** Phases **1–5** are **code-complete and developer-verified in Godot 4.7
(Forward+)**. A post-v1 post-processing filter backlog has started
(`to_do_post_processing.md`). **Next:** either more post filters (CRT is queued) or
**Phase 6 packaging** to make v1 shippable.

The human (Shawn) does all in-editor testing; the agent cannot run Godot or see
rendered output. `human_steps.md` is the human's per-phase test guide.

---

## 1. What was built in session 2

### Phase 4 — Workflow + editor-live preview (verified)
- **Light-mask system (§9.5):** per-material `receiver_mask` uniform on
  `lit_receiver.gdshader`; in the light loop a light is skipped unless
  `(light_mask & receiver_mask) != 0`, before any per-light work. Lights reuse the
  inherited `CanvasItem.light_mask` ("Visibility" inspector group).
- **Subtract blend mode:** `subtractive` flag (flags bit 1) now consumed
  (`lit -= contribution`).
- **`LitSprite2D`** (`nodes/lit_sprite_2d.gd`): a `Sprite2D` that pre-wires its own
  `ShaderMaterial` + `CanvasTexture` in `_init()` (deserializer overrides saved
  values), and proxies `emissive_strength` + `receiver_mask`
  (`@export_flags_2d_render`) to its own material.
- **"Make Selected Sprites Lit" tool** (`lit_plugin.gd`): Project → Tools menu item;
  assigns a fresh receiver material + wraps a plain texture in a `CanvasTexture` per
  selected `Sprite2D`. Undoable via `get_undo_redo()`.
- **Editor-live preview:** the EditorPlugin owns a `LitLightRegistry` and drives the
  same shared `refresh()` on a throttled `_process` (~30 Hz), packing against
  `EditorInterface.get_editor_viewport_2d()`. Lights, shadows, masks, subtract all
  preview live in the 2D viewport.

### Phase 5 — Post-processing (verified)
- **`LitPostProcess`** (`nodes/lit_post_process.gd`, extends `CanvasLayer`): builds an
  ordered chain of fullscreen passes as **internal** children and rebuilds it from
  the enabled-pass toggles. See §5 for the architecture (read it before adding more
  passes).
- **Passes shipped:** **Threshold** (luma gate), **Bloom** (single-pass multi-scale
  mip glow), **Color Grade** (exposure/contrast/saturation/tint), **Vignette**.
  Shaders in `shaders/lit_post_*.gdshader`.
- **LUT (post-v1):** `shaders/lit_post_lut.gdshader` + 8 baked presets in
  `addons/lit/luts/`, chosen via a `lut_preset` dropdown, with a `lut_custom` texture
  override. The "social-media filter engine."

---

## 2. Deviations / decisions this session (READ THIS)

**Phase 4**
1. **Editor-live = throttled poll, not per-node signals.** Polling from
   `lit_plugin.gd::_process` (~30 Hz) is the smaller, more robust path and is the
   only thing that catches *editor camera pan/zoom*, which the position/shadow math
   needs. Continuous redraw while active is the intended tradeoff; dirty-tracking is
   post-v1 (plan §13).
2. **`receiver_mask` is a plain `int` uniform** (shader uniforms have no layers hint);
   `LitSprite2D` proxies it with `@export_flags_2d_render`. The shared
   `lit_receiver_material.tres` masks all its sprites together — use `LitSprite2D` or
   the tool for independent masks.

**Phase 5**
3. **No `BackBufferCopy` — chaining via nested CanvasLayers** (deviation from plan D8,
   which specified `BackBufferCopy` between passes). Sampling `hint_screen_texture`
   reads the screen as drawn so far, and a **per-pass CanvasLayer boundary** forces
   each pass to re-read the accumulated result, so passes compose in order. This is
   the human's proven, shipped pattern; same result, simpler.
4. **Bloom is single-pass multi-scale mip glow** (not a multi-pass downsample/blur/
   upsample chain). It reads the screen with `filter_linear_mipmap` and sums a
   soft-thresholded bright-pass across several `textureLod` mip levels. Mips ARE the
   downsample/blur; the weighted sum is the upsample/composite; added onto the
   original. Fits the single-ColorRect architecture and gives the wide fantasy glow.
5. **Bloom `threshold` defaults to 0.7, not plan's 1.0.** The screen is LDR (0..1), so
   1.0 catches almost nothing; useful range is ~0.4–0.8.
6. **LUT is post-v1**, beyond plan scope. Dropdown-of-baked-presets + custom-texture
   override (no `use_custom_lut` boolean — a custom texture's presence is the switch).

**Carried from Phase 4 fixes (also in §3 gotchas):** the `global_canvas_transform`
editor-transform fix and the EditorPlugin lifecycle split (churn fix).

---

## 3. Gotchas discovered (don't re-learn these the hard way)

- **Editor view pan/zoom lives in `global_canvas_transform`, NOT `canvas_transform`.**
  A Viewport applies `global_canvas_transform * canvas_transform` to canvas items. At
  runtime the camera is in `canvas_transform` (global part identity); in the editor
  the view transform is in `global_canvas_transform`. `lit_light_registry.gd` uses the
  **product** `viewport.get_global_canvas_transform() * viewport.get_canvas_transform()`
  — correct in both. Symptom of getting this wrong: lights correct in-game, offset in
  the editor and drifting with zoom.
- **`EditorPlugin._enter_tree`/`_exit_tree` fire on every editor open/close**, not just
  enable/disable. Doing unconditional `project.godot` writes there churns the file on
  every close. Fix: persistent writes (autoload + `shader_globals/*`) go in
  `_enter_tree` but **guarded** (write only if missing); removal lives in
  `_disable_plugin`. `_exit_tree` does session-only teardown. Self-healing, no churn.
- **Screen-texture mipmaps work in Godot 4.7** (editor *and* runtime): a canvas
  `hint_screen_texture` with `filter_linear_mipmap` gives blurred downsamples via
  `textureLod`. This is what makes single-pass bloom possible. (If a future engine
  version drops this, fall back to explicit multi-tap blur or a SubViewport chain.)
- **Generated/helper children should be INTERNAL** (`add_child(n, false,
  Node.INTERNAL_MODE_BACK)`) so they're not saved to the scene and don't clutter the
  Scene dock; rebuild them from state. `LitPostProcess` does this for its passes.
- **A fullscreen post `ColorRect` must be `MOUSE_FILTER_IGNORE`** or it eats all UI
  input.
- **LUT textures corrupt under VRAM compression / mipmaps.** Import LUT strips as
  Filter on, Mipmaps off, Repeat disabled, Compress Mode = Lossless. The "neutral"
  LUT must come back identity — that's the sanity check. (Filter/repeat are also
  forced in-shader, so compression is the usual culprit.)
- Editor-only APIs used: `EditorInterface.get_editor_viewport_2d()`,
  `EditorInterface.get_selection().get_selected_nodes()`, `get_undo_redo()`
  (`EditorUndoRedoManager`), and `EditorScript._run()` + `Image.save_png()` (the LUT
  generator — used once, then deleted; recoverable from git history).

---

## 4. File structure (additions this session)

```
addons/lit/
  lit_plugin.gd                 # +tool menu, +editor-live _process, lifecycle split
  nodes/
    lit_sprite_2d.gd            # NEW — LitSprite2D
    lit_post_process.gd         # NEW — LitPostProcess (post-processing chain)
  runtime/
    lit_light_registry.gd       # canvas_xform = global_canvas_transform * canvas_transform
  shaders/
    lit_receiver.gdshader       # +receiver_mask + mask skip + subtract blend
    lit_post_threshold.gdshader # NEW
    lit_post_bloom.gdshader     # NEW
    lit_post_grade.gdshader     # NEW
    lit_post_vignette.gdshader  # NEW
    lit_post_lut.gdshader       # NEW
  luts/
    lit_lut_*.png (+ .import)    # NEW — 8 baked LUT presets (generator deleted)
```

New `class_name`s this session: `LitSprite2D`, `LitPostProcess` (both already
project-reloaded). `LutPreset` is an internal enum (no reload).

---

## 5. LitPostProcess architecture (read before adding post filters)

- Extends `CanvasLayer`. Its inherited `layer` is configurable; default sits above
  world content. Set it to e.g. 99 to reserve high layers for post (the human's
  convention) — pass child-layers increment from it.
- Each enabled pass = an **internal child `CanvasLayer`** (for ordering + the per-pass
  screen re-read, see §2.3) holding a fullscreen `ColorRect` (`PRESET_FULL_RECT`,
  `MOUSE_FILTER_IGNORE`) with the pass `ShaderMaterial`.
- Pass child-layer = `layer + index + 1`; an editor-only `_process` re-syncs if the
  base `layer` is edited live.
- **Fixed canonical order:** threshold → bloom → grade → lut → vignette. Lower layers
  render first, so each pass reads the prior result.
- `_rebuild()` (called on enable/disable toggles) tears down the internal children and
  regenerates them; `_apply_params()` (called on parameter edits) pushes uniforms to
  the live materials without rebuilding.

**To add a new pass:** (1) write `shaders/lit_post_<name>.gdshader` —
`shader_type canvas_item;`, `uniform sampler2D screen_texture : hint_screen_texture,
filter_linear[_mipmap];`, do the effect, `COLOR = vec4(result, 1.0);`. (2) `preload`
it. (3) add an `@export_group` with an `<name>_enabled` bool (setter → `_rebuild`) and
parameter exports (setters → `_apply_params`). (4) add a `_<name>_material` member.
(5) slot it into `_rebuild()` in canonical order. (6) push its uniforms in
`_apply_params()`. Animate with `TIME` for grain/VHS/glitch.

**Note (flagged for ~8+ passes):** the hardcoded order and growing inspector will want
a reorderable pass-list resource eventually (see `to_do_post_processing.md`).

---

## 6. Remaining work

- **Post-processing filter backlog:** `to_do_post_processing.md` — tiered wishlist
  (CRT, VHS, film grain, chromatic aberration, dither, pixelate, etc.). Recommended
  next: **CRT**, then VHS.
- **Phase 6 — Packaging:** example scene(s), README, node icons
  (`LitCanvasModulate`, `LitSprite2D`, `LitPostProcess`), `plugin.cfg` cleanup (its
  description still says "Phase 1"), Asset Library metadata. Worth doing before piling
  on too many filters so v1 is shippable. Also reconcile `plan.md` with as-built
  reality (spotlight, 5-texel encoding, editor-live via polling, post-processing set,
  LUT).

---

## 7. Working rhythm (unchanged)

- One phase (or sub-step) at a time. The human verifies in-editor, commits, then says
  proceed. Report findings as observations; the agent debugs from those.
- After any `class_name` change, the human must **reload the project**; after
  EditorPlugin changes, **re-toggle the plugin**. Node-script export changes just need
  the node re-selected.
- Keep edits surgical. Hot files: `lit_receiver.gdshader`, `lit_light_registry.gd`,
  `lit_post_process.gd`.

---

## 8. Prompt to give the next agent

> This is a Godot 4.7 (Forward+) project implementing **Lit**, a drop-in 2D lighting
> plugin. Read **`plan.md`** in full first (the original spec), then
> **`implementation_session_1.md`** and **`implementation_session_2.md`** (what's
> actually built and where it deviates from the plan), and skim
> **`to_do_post_processing.md`** (the post-processing filter backlog).
>
> Phases 1–5 are complete and verified: ambient/darkness, uncapped point lights, SDF
> soft shadows, directional + spot lights, light masks, subtractive blend,
> `LitSprite2D`, the "Make Selected Sprites Lit" tool, editor-live preview, and a
> `LitPostProcess` chain (threshold, bloom, color grade, vignette) plus a LUT pass
> with 8 baked presets + custom override. The light-data texture is 5 texels/light.
>
> Constraints:
> - **You cannot run Godot or see rendered output.** The human does all in-editor
>   testing and reports back — never assume something renders or claim you tested it.
> - Work **one phase / sub-step / filter at a time**, stop, and give a short in-editor
>   verification checklist before continuing.
> - Honor the committed decisions in `plan.md §5` and the deviations in
>   `implementation_session_1.md §2` and `implementation_session_2.md §2`. Don't
>   re-litigate or silently undo them.
> - After any `class_name` change, remind me to reload the project; after EditorPlugin
>   changes, remind me to re-toggle the plugin.
>
> To add post-processing filters, follow the "add a new pass" recipe in
> `implementation_session_2.md §5`. Next up is your choice with me: **CRT** (top of the
> backlog) or the **Phase 6 packaging** pass to make v1 shippable. Ask me which to
> start, then begin.
