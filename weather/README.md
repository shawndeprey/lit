# Pixel-Art Rain System (Godot 4.x) — v2

Stylized top-down rain for 3/4-perspective games. **Now fully screen-space and
procedural** — streaks, droplets, and fog are all drawn in shaders on
full-screen ColorRects, so everything renders reliably regardless of camera
position (the v1 particle streaks could spawn off-screen). One `intensity`
value (0.0–1.0) drives it all.

## Install

1. Copy the whole `weather/` folder into your project's `res://` root. Keep the
   folder named `weather` (scenes use paths like `res://weather/...`).
2. Open `res://weather/DemoRain.tscn` and press Play.

## The demo — automated weather showcase

`DemoRain.tscn` now runs a looping weather cycle that fades every effect in and
out to show them together:

  Clear skies → Mist rolling in → Light drizzle → Steady rain →
  STORM PEAK (lightning + strong wind) → Gusting over → Easing off → Clearing

Intensity and wind interpolate smoothly between phases via tweens, the current
phase name is shown top-center, and lightning fires automatically at the peak
(with a small camera kick on each strike).

Controls (registered in code, so they always work):

- **M** — toggle between AUTO cycle and MANUAL control
- **WASD** — move the yellow player (walk into the shelter on the right)
- In MANUAL mode: **E / Q** intensity, **← / →** wind, **Space** lightning

## Using it in your game

1. Instance `RainSystem.tscn` anywhere (it's a CanvasLayer, draws over the world).
2. Drive intensity: `$RainSystem.intensity = 0.8`
3. Adjust `wind` (streak lean, -0.6..0.6) and `fall_speed` as desired.

## Tuning cheatsheet

Rain (`rain_streak.gdshader` params, editable on the Rain ColorRect material):
- `intensity` — density + opacity (driven by RainSystem)
- `streak_color`, `pixel_size` — look & chunkiness
- `fall_speed`, `slant` (wind), `streak_len`, `columns` (drops across screen)

Droplets (`droplet_overlay.gdshader`):
- `density` — how many drops (higher = more, smaller)
- `drop_tint`, `pixel_size`

Fog (`fog.gdshader`):
- `fog_color`, `drift_speed`, `pixel_size`

Lightning (RainSystem): `lightning_interval` (min/max seconds), `lightning_enabled`.

## About shelters / occlusion — READ THIS

`RainZone.tscn` currently reduces **global** intensity when the player enters
(the whole screen dries up, not just the area under the roof). That's the
honest tradeoff of a screen-space approach: it can't spatially mask rain to a
world region cheaply.

If you need **true localized occlusion** (rain stops only under the roof while
still falling everywhere else), you have two options:
1. **World-space particle layer** for the streaks (the v1 approach) with roof
   tiles carved out via emission masks — spatially correct but the streaks are
   fiddlier to keep on-screen.
2. **A masked SubViewport**: render the screen-space rain, then multiply it by a
   world-aligned mask texture where roofs punch holes. More setup, best result.

Tell me which you want and I'll wire it up. For many top-down games the global
fade actually reads fine (walking indoors = the rain you *see* stops), which is
why it's the default.

## Files

| File | Purpose |
|------|---------|
| `RainSystem.gd/.tscn` | Main controller + screen-space shader layers |
| `RainZone.gd/.tscn` | Shelter areas (global intensity fade — see note above) |
| `DemoRain.gd/.tscn` | Playable test scene |
| `rain_streak.gdshader` | Procedural falling streaks (full-screen) |
| `droplet_overlay.gdshader` | Scattered screen droplets |
| `fog.gdshader` | Drifting mist |
| `splash.gdshader` | Ripple shader (kept for the particle path if you go world-space) |
| `textures/*.png` | Streak + splash sprites (only needed for the particle path) |

## Notes

- All rain shaders use `SCREEN_UV`, so they cover the viewport at any camera
  position and auto-handle window resizing (RainSystem pushes aspect ratio in).
- `pixel_size` controls chunkiness — match it to your art's pixel scale.
- Low-end mobile: lower `columns` on the rain shader and `density` on droplets,
  or disable fog.
