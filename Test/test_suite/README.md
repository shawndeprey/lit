# Lit test suite

One window, every feature. `TestSuite.tscn` runs each section under this folder back
to back, building its exhibits on screen so the features it checks are visible while
they are verified, and ends on a pass/fail report card of every feature. Run it before
signing off on any change to Lit; when you add a feature, add its checks to the section
it belongs to (or a new section folder).

Run it windowed (the headless renderer never compiles shaders, and most checks read the
rendered frame back):

```
godot --path . res://Test/test_suite/TestSuite.tscn
godot --path . res://Test/test_suite/TestSuite.tscn -- quit=on
godot --path . res://Test/test_suite/TestSuite.tscn -- only=shadows,post_process hold=2
godot --path . res://Test/test_suite/TestSuite.tscn -- quit=on capture=/tmp/report.png
```

Options after `--`:

| option | effect |
|---|---|
| `quit=on` | quit after the report; exit code 1 on any failure (console / CI use) |
| `capture=PATH` | save the report frame as a PNG (implies `quit=on`) |
| `only=a,b` | run only these sections (folder names) |
| `skip=a,b` | skip these sections |
| `model=both\|phong\|pbr` | which lighting model(s) the model-sensitive sections run under; `both` (default) runs them twice and reports the PBR pass as `<section>@pbr` |
| `hold=SECONDS` | keep each finished section on screen that long, for eyeballing |
| `vsync=on` | leave vsync on (off by default so frame waits run at GPU speed) |
| `verbose=on` | also print every passing check while running (off by default: only checks that did not pass are printed, so the console stays short) |

The window stays open on the report by default. Escape quits; C copies every `SUITE`
line of the run to the clipboard, ready to paste into a bug report; the panel text can
also be selected and copied with Ctrl+C; the mouse wheel scrolls it. A full run takes
a couple of minutes cold (the shader library section compiles every variant) and
about 20 seconds warm.

Every section scene (`<section>/<section>_section.tscn`) also runs on its own with the
same HUD and options, which is the quick way to iterate on one feature set.

## Output

Every line starts with `SUITE`. While the run is going, the console gets one line per
section and one line per check that did not pass (nothing for passing checks unless
`verbose=on`):

```
SUITE ENV window=.. viewport_px=.. canvas_units=.. final_scale=.. debugger=.. args=..
SUITE ==== <section>: <title> ====
SUITE FAIL|GAP <section>/<feature>: <what> | expected=.. actual=..
```

The `SUITE ENV` line states the window and viewport the run rendered into. The runner
pins the render to 1920x1080 canvas units = pixels (viewport stretch mode, letterboxed
into whatever window it gets), so a run from the editor's embedded Game tab, a resized
window or the command line all measure the same pixels; `viewport_px=(1920, 1080)
final_scale=1.000` on that line confirms it. Godot on macOS writes every run's console
to `~/Library/Application Support/Godot/app_userdata/Lit/logs/`, which is how an
editor run can be read back later.

The end of the run prints the full report: every passing feature on one list, then
everything that needs a look on another, then the counts.

```
SUITE REPORT
SUITE PASSED FEATURES (n of m)
SUITE   PASS <section>/<feature> (k checks)                          one per passing feature
SUITE NEEDS CHECKING (f failed, g known gaps)
SUITE   FAIL|GAP <section>/<feature>: <what> | expected=.. actual=.. one per check that did not pass
SUITE SECTIONS
SUITE   <section>: k checks, f failed, g known gaps, ms              one per section run
SUITE SUMMARY section_runs=.. features=.. features_passed=.. features_failed=.. features_with_gaps=.. checks=.. passed=.. failed=.. known_gaps=.. model=.. time=..s
SUITE RESULT PASS|FAIL
```

A feature is one `case` name inside a section (`shadows/shadow_algorithms`,
`post_process/fx_bloom`, ...); it passes only if every one of its checks passes. The
HUD shows the running section's checks live, and the final report card has the same
two lists, with what needs checking at the top. A section run on its own prints the
same report for its features.

Sections whose exhibits are shaded by the receiver's lighting model (lights, cookies,
receivers, animated_sprite, tilemap, shadows, shadow_masks, luminance) run once under
Blinn-Phong and once under PBR (`lights` and `lights@pbr` in the report), so every
feature is proven under both models; the `lighting_model` section checks the two
models' own inputs side by side. Numeric expectations go through
`diffuse_scale()` (1 under Blinn-Phong, 0.96 under PBR: a dielectric's Lambert term is
albedo x (1 - F0), and the roughness-1 specular is under 0.006), so one check serves
both passes.

Checks tagged `(known gap)` describe behaviour Lit does not have yet; they fail by
design until the gap is closed, and they are the place to start when one is. A gap
check that passes fails the run as "gap closed, remove the (known gap) label": drop
the label and the check carries on as a plain regression test.

Three Lit fallbacks are deliberately left unexercised because reaching them makes Lit
push a warning, and a green run is meant to leave the editor's Errors tab empty: a cookie
larger than `lit/quality/cookie_atlas_max_size` (analytic falloff), a receiver material
shared by two occluder-owning bare receivers (skipped by the driver), and a precompile
config naming a missing shader or unknown variant (entries skipped).

## Sections

| folder | covers |
|---|---|
| `harness` | probe calibration; LitCanvasModulate ambient colour / energy / last-wins / native-modulate conflict |
| `lights` | point, spot and directional lights against the shading formula; masks; negative lights; 70 lights at once |
| `cookies` | light textures: alpha shaping, tint, NATIVE / FIT_RANGE, scale, offset, rotation, spot composition, atlas |
| `receivers` | LitSprite2D pre-wiring and proxies, emissive + mask, receiver mask, normal maps (and their rotation), specular, bare Sprite2D / Polygon2D receivers, make_material_unique |
| `animated_sprite` | LitAnimatedSprite2D: lighting per frame (CanvasTexture and AtlasTexture-over-sheet frames), playback, specular-flag tracking, owned occluders, shadow_ignore_mask |
| `tilemap` | LitTileMapLayer: proxies, lighting, tileset occluder shadows, own-tile self-exclusion, cell edits, occlusion-layer masks |
| `shadows` | enable/colour/length, the three algorithms and their penumbra dials, gates, footprint darkening, directional and spot shadows, quality settings |
| `shadow_masks` | self-shadow exclusion, shadow_mask vs occluder mask tiers (per-light, global, SDF culling), shadow_ignore_mask, exclude_scene_occluders, y-sorted depth |
| `camera` | Camera2D zoom, roll and pan: point / spot / directional shading, normal maps and shadows read the same at the same world points |
| `lighting_model` | Blinn-Phong vs PBR switched live; metallic / roughness / AO inputs; inspector gating of inert exports |
| `luminance` | LitManager.sample_luminance and LitSprite2D.get_luminance against lights, cookies, masks, shadows, and the rendered frame |
| `post_process` | every built-in post effect on a fixed base image, chain order, rank slotting, host visibility, parameter persistence, custom effects, auto exposure |
| `auto_pooling` | the receiver material pool bench (moved here from Test/misc/auto-pooling; see its README) |
| `registry` | light cache, bare-receiver driving, activity flags and the automatic variant swap, the rx registry |
| `shader_library` | variant matrix gates, every variant compiled and rendered, entry shaders, world SDF pipeline, precompiler statics and overlay |
| `migration` | schema lock: migration files, lit_version stamps, live stored properties vs the locked baseline |
| `update_tool` | "Update Project to Lit" on the Test/.update_tool_bench fixtures (scratch copy): conversions, scripts, reports, idempotency |
| `splash` | LitSplashScreen playback, skip, finished signal, auto_free |

Every section run starts from a fresh-launch registry state (the light-mask latch is
reset) and only once the world SDF's warm-up window has closed, so SDF staleness
checks behave the same whichever section runs first.

## Writing a section

Extend `LitSuiteSection` (`suite_section.gd`), override `run()` and register the script
in `SECTIONS` in `test_suite.gd`. The base gives you:

- `check` / `check_true` / `check_approx` / `check_gt` / `check_lt` / `check_between`
  (`case_name`, description, expected, actual) - one `case` per feature;
- `frames(n)` and `capture()` to wait for rendered frames and read one back;
  `probe` / `lum` / `peak` / `image_mean` / `image_diff` / `image_variance` to measure it
  at logical (1920 x 1080) coordinates;
- scene builders: `env`, `point_light`, `spot_light`, `directional_light`,
  `floor_receiver`, `box_receiver`, `lit_sprite`, `occluder`, `marker`, `group`, `label`,
  the `cell` grid, texture helpers (`tex_solid`, `tex_fn`, `tex_normal`, `canvas_tex`);
- `set_setting` for project settings, restored when the section ends;
- `model` / `model_name()` / `diffuse_scale()`: the pinned lighting model of this run.
  Mark a section `"pbr": true` in `SECTIONS` if its exhibits are lit by receivers, and
  write direct-light expectations as `ambient + contribution * diffuse_scale()`.

Keep exhibits left of x = 1400 (the HUD panel) and below y = 60 (the status bar). Give
every light-driven exhibit room: a light's range must not reach a neighbouring exhibit's
probes, and a directional light shadows along the whole screen. Occluders that must not
count as a receiver's own go under a wrapper `Node2D` (a receiver owns its descendants
and direct siblings).
