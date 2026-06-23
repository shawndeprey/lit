# Lit — Post-Processing Filter Backlog

Running agenda of post-processing passes for `LitPostProcess` beyond the v1
baseline. The v1 baseline (Phase 5, **done**) is **Threshold, Bloom, Color Grade,
Vignette**. Everything below is post-v1 / developer-driven (plan §13) — a wishlist,
not a commitment, ordered by impact-vs-effort.

All of these fit the current architecture: a single fullscreen `ColorRect` per pass
reading the screen via `hint_screen_texture`, optionally animated with `TIME`,
chained via per-pass CanvasLayers (no `BackBufferCopy`). Passes that need a texture
input (LUT, light leaks) or are multi-scale (already proven by bloom's mip trick)
are still single-pass-friendly.

Status key: `[ ]` todo · `[~]` in progress · `[x]` done

---

## Tier 1 — high impact, low effort (do first)

- [x] **LUT color grading** — remap colors through a 256×16 neutral-LUT strip. Ships
  with 8 baked-in presets (`addons/lit/luts/`) selectable via a **dropdown**
  (`lut_preset`); assigning a **`lut_custom`** texture overrides the preset. The
  "social-media filter engine": infinite looks from one pass. (Generator script was
  removed once the pack was baked; recoverable from git history if more presets are
  wanted.)
- [x] **CRT** — barrel curvature + scanlines + aperture/shadow mask + edge vignette
  + slight chroma. Bundles several sub-effects into one node.
  (`shaders/lit_post_crt.gdshader`; runs after lut, before vignette.)
- [~] **VHS** — chroma bleed/smear, tracking-noise lines, color-channel shift, tape
  wobble/jitter, scanline roll. Animated via `TIME`.
  (`shaders/lit_post_vhs.gdshader`; runs before crt — tape signal -> glass.)
- [x] **Film grain** — animated noise; pairs with everything. Trivial, big vibe.
  (`shaders/lit_post_grain.gdshader`; runs after crt, before vignette. Mono/colored,
  luminance-responsive.)
- [x] **Chromatic aberration** — RGB split growing toward screen edges. Cheap, lens-y.
  (`shaders/lit_post_aberration.gdshader`; runs after crt, before grain. Radial,
  edge-falloff shaped, center stays sharp.)

## Tier 2 — stylize (retro / indie)

- [x] **Pixelate / mosaic** — quantize UVs for a chunky downscaled look.
  (`shaders/lit_post_pixelate.gdshader`; runs first in the stylize cluster — after lut,
  before posterize/outline — so they read the blocky image. `pixel_size` in px.)
- [x] **Dither** — ordered Bayer dithering + palette quantize (Game Boy / PICO-8 /
  1-bit aesthetics). (`shaders/lit_post_dither.gdshader`; runs after halftone, before
  letterbox. 4x4 Bayer + per-channel levels, monochrome/1-bit option, scale + strength.
  Pair with the LUT pass for a fixed palette.)
- [x] **Posterize** — hard color-step. (`shaders/lit_post_posterize.gdshader`; runs
  after lut, before outline — flatten color then ink for the comic look. Configurable
  levels + strength.) Duotone two-tone map still TODO.
- [x] **Halftone / dot screen** — comic-book dots.
  (`shaders/lit_post_halftone.gdshader`; runs after outline, before letterbox. Rotated
  ink-dot grid sized by luma; configurable size/angle/amount/ink/paper.)
- [x] **Edge outline (Sobel)** — ink/cel/comic outlines.
  (`shaders/lit_post_outline.gdshader`; runs after lut, before vhs — crisp edges
  before any tube/tape warp. Luma Sobel, configurable ink color/thickness/threshold.)

## Tier 3 — cinematic / photographic

- [ ] **Lens distortion** — barrel / pincushion (fisheye or subtle correction).
- [x] **Letterbox bars** — animatable cinematic aspect crop (cutscenes).
  (`shaders/lit_post_letterbox.gdshader`; runs at the content/display boundary — after
  outline, before vhs — so the display passes render over the bars. Animate
  `letterbox_size` to ease bars in/out; feather + color configurable.)
- [x] **Halation** — warm red-ish bloom around highlights (film companion to bloom).
  (`shaders/lit_post_halation.gdshader`; runs right after bloom, before grade. Reuses
  bloom's mip-glow, luma-driven, recolored to a warm tint.)
- [ ] **Light leaks** — animated colored gradients bleeding from edges (texture-driven).
- [ ] **Glitch / RGB-shift / datamosh-lite** — animated tearing/blocks (damage/hacking).
- [ ] **Soft focus / dream blur** + **Sharpen** — the two ends of the focus dial.

---

## Recommended build order

LUT → CRT → VHS → Film grain → Chromatic aberration, then cherry-pick Tier 2/3.
Rationale: LUT is a force multiplier; CRT/VHS are crowd-pleasers already requested;
grain + aberration are quick wins that make CRT/VHS sing.

## Architecture heads-up (revisit at ~8+ passes)

Two things will want attention as the pass count grows — not blockers now:

1. **Inspector length.** The single `LitPostProcess` inspector gets long with one
   group per pass. May want sub-resources or a cleaner UI eventually.
2. **Fixed canonical order.** Passes currently run in a hardcoded order
   (threshold → bloom → grade → lut → vignette …). Some effects want flexible
   placement (grain usually *after* CRT; glitch *before* color). When this bites,
   consider a small **pass-list resource** the developer can reorder, replacing the
   hardcoded sequence.

## Also still pending (v1 finish line)

- **Phase 6 packaging:** example scene, README, node icons (`LitCanvasModulate`,
  `LitSprite2D`, `LitPostProcess`), `plugin.cfg` cleanup, Asset Library metadata.
  Worth doing before piling on too many post filters, so v1 is shippable.
