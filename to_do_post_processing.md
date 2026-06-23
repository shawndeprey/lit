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

- [x] **Lens distortion** — barrel / pincushion (fisheye or subtle correction).
  (`shaders/lit_post_lens_distortion.gdshader`; first display pass, after letterbox.
  Signed amount (barrel/pincushion) + zoom-to-fill + bezel color. Distinct from CRT
  curvature; stackable.)
- [x] **Letterbox bars** — animatable cinematic aspect crop (cutscenes).
  (`shaders/lit_post_letterbox.gdshader`; runs at the content/display boundary — after
  outline, before vhs — so the display passes render over the bars. Animate
  `letterbox_size` to ease bars in/out; feather + color configurable.)
- [x] **Halation** — warm red-ish bloom around highlights (film companion to bloom).
  (`shaders/lit_post_halation.gdshader`; runs right after bloom, before grade. Reuses
  bloom's mip-glow, luma-driven, recolored to a warm tint.)
- [x] **Light leaks** — animated colored gradients bleeding from edges (texture-driven).
  (`shaders/lit_post_light_leaks.gdshader`; runs after aberration, before grain. Screen-
  blended, procedural by default with an optional `leaks_texture` override — same
  baked-default + custom-texture pattern as LUT.)
- [x] **Glitch / RGB-shift / datamosh-lite** — animated tearing/blocks (damage/hacking).
  (`shaders/lit_post_glitch.gdshader`; runs before color grade — corrupt the signal,
  then grade/display. Horizontal tear + RGB split + block jumps + flicker, time-quantized.)
- [x] **Soft focus / dream blur** + **Sharpen** — the two ends of the focus dial.
  (`shaders/lit_post_focus.gdshader`; runs last. One signed `focus_amount`: negative =
  dream blur (+ haze), positive = sharpen. Mip-blur reference like bloom.)

## Tier 4 — community favorites (game-feel, atmosphere, painterly, novelty)

Beyond the v1 + cinematic set: effects indie devs reach for constantly. All fit the
single fullscreen `ColorRect` + `hint_screen_texture` pattern (some lean on the same
mip-blur trick as bloom; heavier ones are flagged). Grouped by use, not priority.

### Game-feel / juice (animated, gameplay-driven)

- [ ] **Heat haze / wobble distortion** — animated noise-driven UV warp for heat
  shimmer, underwater, poison/drunk vision. A game-feel staple; trivial, big payoff.
  Often masked to a region. Animated via `TIME`.
- [ ] **Radial / zoom blur + speed lines** — blur/streak from a focal point for
  dashes, impacts, anime "speed" frames. Bright-masked variant = god rays (below).
- [ ] **Directional motion blur** — simple velocity-direction smear; pairs with fast
  movement / camera whips. Single-direction tap blur.
- [ ] **Damage / status vignette pulse** — pulsing colored edge vignette (red = low
  health, green = poison). Tiny shader, ubiquitous in action games. Drive strength
  from script.
- [ ] **Shockwave / ripple from point** — concentric UV ripple expanding from a
  world point (explosions, magic, water drops). Animated radius; one or more impulses.
- [ ] **Frost / freeze / cracked-glass overlay** — texture-driven edge frost or cracks
  creeping in (ice status, screen damage). Same baked-default + custom-texture pattern
  as LUT / light leaks.

### Atmosphere / environment

- [ ] **Underwater** — blue-green tint + caustic light pattern + gentle wobble + edge
  darkening, in one bundle (like CRT bundles its sub-effects). Water levels are everywhere.
- [ ] **Fog / mist overlay** — scrolling layered value-noise haze, optional height/edge
  bias. Cheap screen-space atmosphere without a depth buffer.
- [ ] **God rays / light shafts** — radial blur of a bright-pass from a sun/source point
  (screen-space volumetric). Gorgeous; reuses the bright-pass + radial-blur ideas already
  proven by bloom and zoom blur.
- [ ] **Anamorphic streak / lens flare** — horizontal-only bloom streaks + ghost dots
  from bright points (sci-fi / JJ-Abrams blue lines). Companion to bloom/halation.

### Painterly / artistic (heavier, marquee looks)

- [ ] **Kuwahara / oil-paint / watercolor** — edge-preserving painterly smear (the
  BotW-ish hand-painted look). Marquee stylization. **Heavier** (many taps); still a
  single pass but the costliest on the list — flag for perf testing.
- [ ] **Cross-hatch / sketch / pencil** — luma-thresholded hatching strokes (texture or
  procedural) for an inked-sketch look. Comic/notebook games. Composes with the outline pass.
- [ ] **Gradient map / duotone+** — remap luma through a 2+ stop color ramp (sunset,
  Game-Boy green, blueprint). Generalizes the still-pending duotone; LUT-adjacent but
  authored as a gradient, not a strip.
- [ ] **Hue shift / color cycling** — animated hue rotation or palette cycling (retro
  waterfalls/fire, psychedelic, rainbow). One-liner in HSV; big retro nostalgia.

### Retro / novelty

- [ ] **TV static / no-signal** — full-screen analog static + roll bars + sync tear for
  channel-change / death / transition stings. Quick, very reusable.
- [ ] **Interlace / sub-scanline** — lighter CRT cousin: just field interlacing or
  alternating-line dim, for a subtler tube feel without the full CRT bundle.
- [ ] **Hex / voronoi / triangle mosaic** — non-square pixelate variants for a stylish
  twist on the existing pixelate pass.
- [ ] **ASCII / text-mode render** — quantize luma blocks to characters from a glyph
  atlas. Niche but a reliable wishlist-topper / screenshot magnet.

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
