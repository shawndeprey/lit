# LitLineLight2D review: issue walkthroughs (PR #107)

One narrated walkthrough scene per issue found while reviewing `feat-line-light`, plus an
automated check for each in `checks/`.

## Walkthroughs (open these first)

Run a scene (F6 in the editor, or from the command line, windowed):

```
godot --path . res://Test/integration_tests/line_light_review/01_gate_cone_miss.tscn
```

Each walkthrough is a sequence of steps that advance on their own (about 60 to 90 s each).
A caption at the bottom explains what you are looking at and what to watch for. Panels are
tagged **EXPECTED** (a reference setup behaving correctly) or **ACTUAL (BUG)**. Changes are
shown as **BEFORE -> AFTER**, and the key motion is slowed down, with live readouts and graphs.

Keys: **Space** pause, **Left / Right** previous / next step, **R** restart,
**1-4** speed 0.5x / 1x / 2x / 4x, **Esc** quit.

| Scene | What it shows |
|---|---|
| `01_gate_cone_miss` | **Straight line light, Cone Traced / Stochastic shadows.** It draws the 32 shadow rays and the early-out "gate" cone, and shows why rays to the tube's near end fall outside the gate. A blocker beside the near end then leaves the straight tube's pixel at 100% while a 3 px-bent reference drops to ~72%. In slow motion the blocker circles P, with a live graph of both. Finally, a blocker on the gate's axis turns the straight tube's pixel black (1% vs 73%), with zoomed before/after crops. |
| `02_stale_cull_bounds` | **Off-screen curved light, Path2D moved or curve replaced.** The light nodes sit off screen while their Path2D children slide the rings on screen. The left light is told about each move (a simulated fix) and lights up. The right one never draws, and a live minimap shows the cull box it is still being tested against. Then one unrelated `Node` joins the tree and the ring pops on. Replacing `path.curve` shows the same bug, healed by `range = range`. |
| `03_biarc_close_blowup` | **close_mode BIARC.** The end directions of an open S-curve slowly turn parallel. SYMMETRIC stays small, while BIARC's loop grows to ~117,000 px (log graph, plus a minimap of the whole loop). The world shadow-map texel grows from 2 to 69 px, and an unrelated point light's shadows turn into blobs or disappear. Then it flips back and forth between before and after. |
| `04_precompile_ramp_twin` | **Precompile dedupe.** A live table shows which variants the precompiler builds and which `dedupe()` folds away. After the real silent precompile pass, turning on a `shadow_ramp` puts the floor on a folded variant: a "compiled mid-game" warning (shown in an on-screen console) plus a frame spike. The same switch with the twin built (a simulated fix) prints no warning. A final step shows why regenerating the config can't help. |
| `05_raymarch_curved_samples` | **Curved line light on Raymarched.** A mock inspector, built from the real property list, shows `shadow_samples` hidden on Raymarched. Stepping that hidden value 1 -> 32 leaves the straight lights' GPU time flat and makes the curved lights' climb (~1.5 -> 3.8 ms here). Then 1 <-> 32 flips with zoomed crops to show it changes the look too. |

Command-line options (after `--`): `speed=N`, `shots=DIR` (saves a PNG at the middle and end
of every step) and `quit=on` (quits after the last step).

## Checks (`checks/`)

Fast, automated versions for regression testing. Every check states the **correct**
behaviour, so while an issue is open its checks fail and the run ends on `SUITE RESULT FAIL`.
Once the issue is fixed they pass. Checks marked `(reference)` should pass either way. Each
check prints one line:

```
REPRO <id>: REPRODUCED | NOT REPRODUCED - <numbers>
```

```
godot --path . res://Test/integration_tests/line_light_review/checks/01_gate_cone_miss_check.tscn -- quit=on
```

None of these scenes are in the test suite's `SECTIONS` list, so the default suite run is
unaffected.

## Files

- `demo_base.gd`: shared walkthrough machinery (steps, captions, keys, panels, graph, zoom insets).
- `checks/review_section.gd`: shared check helpers (built on the suite's `LitSuiteSection`).
