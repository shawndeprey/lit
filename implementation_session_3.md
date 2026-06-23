# Lit — Implementation Session 3 (Summary & Handoff)

Companion to `plan.md`, `implementation_session_1.md`, and `implementation_session_2.md`.
This session was mostly **post-processing filter expansion** (15 new passes, finishing
Tiers 1–3 of `to_do_post_processing.md`) plus a **TileMapLayer shadow finding**. Kept
intentionally brief — the per-shader detail lives in `to_do_post_processing.md` and the
shader headers themselves.

**Status:** Phases **1–5 + the full post-processing backlog (Tiers 1–3)** are
code-complete and developer-verified in Godot 4.7 (Forward+). **Next:** a Tier 4 wishlist
exists but is parked; the real remaining work is **Phase 6 packaging**.

The human (Shawn) does all in-editor testing; the agent cannot run Godot.

---

## 1. What was built/learned this session

### TileMapLayer shadows (no code)
- TileMapLayer tiles already **receive** Lit light (receiver material). To also **cast**
  Lit shadows, the TileSet's occlusion layer just needs **SDF Collision enabled** — that
  flag is what feeds TileMap occluders into the screen-space SDF the shadow march reads.
  No addon change required; documented for the Phase 6 README. (Was the original ask this
  session; resolved by a checkbox.)

### Post-processing: 15 new passes
All are new `shaders/lit_post_*.gdshader` files wired into `LitPostProcess`
(`nodes/lit_post_process.gd`) via the §5 "add a pass" recipe — no new `class_name`, no
new nodes. Added this session:

- **Tier 1:** CRT, VHS, Film grain, Chromatic aberration.
- **Tier 2:** Posterize, Pixelate, Halftone, Dither, Edge outline (Sobel).
- **Tier 3:** Halation, Letterbox, Lens distortion, Light leaks, Glitch, Focus
  (soft/dream blur ↔ sharpen on one signed dial).

`LitPostProcess` now drives **20 passes** total (these 15 + the Phase-5 threshold/bloom/
grade/vignette + LUT). Still no `BackBufferCopy`; still the internal per-pass CanvasLayer
chain from Session 2.

---

## 2. Deviations / decisions this session

1. **Effects bundled, not atomized.** CRT/VHS each bundle several sub-effects into one
   pass (curvature+scanlines+mask+…, wobble+chroma+tracking+…). Focus is one signed dial
   covering both blur and sharpen. Fewer passes, fewer toggles.
2. **Procedural-with-texture-override pattern reused.** Light leaks default to procedural
   and accept an optional `leaks_texture` override — same baked-default + custom-texture
   idea as the LUT pass (`has_texture` bool driven from GDScript).
3. **Canonical order is now a deliberate content→display pipeline.** Full order:
   `threshold → bloom → halation → glitch → grade → lut → pixelate → posterize → outline
   → halftone → dither → letterbox → lens → vhs → crt → aberration → leaks → grain →
   vignette → focus`. Rationale lives in the `LitPostProcess` class docstring. Notable
   placements:
   - **Glitch before color** (corrupt the signal, then grade/display) — honoring the
     backlog's own hint.
   - **Posterize/pixelate before outline; halftone/dither after outline** so the comic/
     pixel-art stack composes (flatten → ink → screen) and edge detection stays clean.
   - **Letterbox at the content/display boundary** (moved from dead-last after the human
     reasoned it should matte the content *before* CRT/VHS render over the bars). See §3.
   - **Focus last** (final lens), **grain after CRT** (film over the tube).
4. **Tier 4 added to the backlog** (community favorites: heat haze, god rays, damage
   vignette, gradient map, Kuwahara, TV static, ASCII, etc.) — parked, not built. Duotone
   also still pending (folded into the posterize line).

---

## 3. Gotchas discovered (don't re-learn these)

- **Godot shading-language compile traps** (hit while writing the CRT shader, now avoided
  everywhere): **no `return` in `fragment()`** (guard the body in an `if` instead); **no
  nested ternary** returning a vec3 (use `if/else`); **`TAU`/`PI` are built-in constants**
  — don't redefine; const arrays use brace init (`const float BAYER[16] = { … }`, fine).
- **Post passes are screen-space and have no "game frame" in the editor.** Position-keyed
  effects (letterbox bars) look wrong/zoom-dependent in the editor 2D preview but are
  correct at runtime — verify those at **runtime (F5)**, not in the live preview. Radial/
  uniform passes don't expose this; letterbox did. (Memory: `post-passes-editor-screenspace`.)
- **Mip-based passes** (bloom, halation, focus) rely on screen-texture mipmaps
  (`filter_linear_mipmap`), confirmed working in 4.7. If a blur/glow stops widening, that's
  the mips-missing signal.

---

## 4. File structure (additions this session)

```
addons/lit/
  nodes/
    lit_post_process.gd            # +15 passes wired (groups, members, _rebuild, _apply_params)
  shaders/
    lit_post_crt.gdshader          # NEW   (+ vhs, grain, aberration, outline, halation,
    …                              #        letterbox, posterize, pixelate, halftone, dither,
    …                              #        lens_distortion, light_leaks, glitch, focus)
to_do_post_processing.md           # Tiers 1–3 marked done; Tier 4 wishlist added
implementation_session_3.md        # this file
```

No `.gd`/`class_name` changes beyond `lit_post_process.gd`; no node/icon/plugin changes.

---

## 5. Remaining work

- **Phase 6 — Packaging (the real next step):** example scene(s), README (incl. the
  TileMapLayer SDF-collision note and the editor-preview caveat), node icons
  (`LitCanvasModulate`, `LitSprite2D`, `LitPostProcess`), `plugin.cfg` cleanup (still says
  "Phase 1"), Asset Library metadata, and reconciling `plan.md` with as-built reality
  (spotlight, 5-texel encoding, editor-live polling, the full 20-pass post set).
- **Post backlog:** duotone (pending) + Tier 4 wishlist (parked).
- **Architecture watch (now relevant at 20 passes):** the fixed canonical order + one
  inspector group per pass is getting long; the long-flagged **reorderable pass-list
  resource** is the eventual cleanup (see `to_do_post_processing.md`). Not blocking.

---

## 6. Working rhythm (unchanged)

- One filter/sub-step at a time; human verifies in-editor, commits, says proceed. Report
  findings as observations; the agent debugs from those.
- Post passes are node-script edits on `LitPostProcess`: **no project reload**, just
  re-select the node (and run the scene for animated/position-keyed effects). Reload only
  on `class_name` changes; re-toggle the plugin on EditorPlugin changes.
- Hot file: `lit_post_process.gd` (and the relevant `lit_post_*.gdshader`).
