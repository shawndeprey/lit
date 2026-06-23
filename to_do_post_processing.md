# Lit — Post-Processing Filter Backlog

## Game-feel / juice (animated, gameplay-driven)

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

## Atmosphere / environment

- [ ] **Underwater** — blue-green tint + caustic light pattern + gentle wobble + edge
  darkening, in one bundle (like CRT bundles its sub-effects). Water levels are everywhere.
- [ ] **Fog / mist overlay** — scrolling layered value-noise haze, optional height/edge
  bias. Cheap screen-space atmosphere without a depth buffer.
- [ ] **God rays / light shafts** — radial blur of a bright-pass from a sun/source point
  (screen-space volumetric). Gorgeous; reuses the bright-pass + radial-blur ideas already
  proven by bloom and zoom blur.
- [ ] **Anamorphic streak / lens flare** — horizontal-only bloom streaks + ghost dots
  from bright points (sci-fi / JJ-Abrams blue lines). Companion to bloom/halation.

## Painterly / artistic (heavier, marquee looks)

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

## Retro / novelty

- [ ] **TV static / no-signal** — full-screen analog static + roll bars + sync tear for
  channel-change / death / transition stings. Quick, very reusable.
- [ ] **Interlace / sub-scanline** — lighter CRT cousin: just field interlacing or
  alternating-line dim, for a subtler tube feel without the full CRT bundle.
- [ ] **Hex / voronoi / triangle mosaic** — non-square pixelate variants for a stylish
  twist on the existing pixelate pass.
- [ ] **ASCII / text-mode render** — quantize luma blocks to characters from a glyph
  atlas. Niche but a reliable wishlist-topper / screenshot magnet.
