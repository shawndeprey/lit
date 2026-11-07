# LitLineLight2D review: issue walkthrough (PR #107)

One narrated walkthrough scene for the issue still open from the `feat-line-light` review,
plus an automated check for it in `checks/`. The other four issues from the review are fixed
and their regression checks live in the test suite (line_path and shader_library sections);
this folder goes away once issue 1 is fixed the same way.

## Walkthrough

Run the scene (F6 in the editor, or from the command line, windowed):

```
godot --path . res://Test/integration_tests/line_light_review/01_gate_cone_miss.tscn
```

The walkthrough is a sequence of steps that advance on their own (about 60 to 90 s).
A caption at the bottom explains what you are looking at and what to watch for. Panels are
tagged **EXPECTED** (a reference setup behaving correctly) or **ACTUAL (BUG)**. Changes are
shown as **BEFORE -> AFTER**, and the key motion is slowed down, with live readouts and graphs.

Keys: **Space** pause, **Left / Right** previous / next step, **R** restart,
**1-4** speed 0.5x / 1x / 2x / 4x, **Esc** quit.

| Scene | What it shows |
|---|---|
| `01_gate_cone_miss` | **Straight line light, Cone Traced / Stochastic shadows.** It draws the 32 shadow rays and the early-out "gate" cone, and shows why rays to the tube's near end fall outside the gate. A blocker beside the near end then leaves the straight tube's pixel at 100% while a 3 px-bent reference drops to ~72%. In slow motion the blocker circles P, with a live graph of both. Finally, a blocker on the gate's axis turns the straight tube's pixel black (1% vs 73%), with zoomed before/after crops. |

Command-line options (after `--`): `speed=N`, `shots=DIR` (saves a PNG at the middle and end
of every step) and `quit=on` (quits after the last step).

## Check (`checks/`)

A fast, automated version for regression testing. It states the **correct** behaviour, so
while the issue is open its checks fail and the run ends on `SUITE RESULT FAIL`. Once the
issue is fixed they pass. Checks marked `(reference)` should pass either way. It prints one
line:

```
REPRO <id>: REPRODUCED | NOT REPRODUCED - <numbers>
```

```
godot --path . res://Test/integration_tests/line_light_review/checks/01_gate_cone_miss_check.tscn -- quit=on
```

The scene is not in the test suite's `SECTIONS` list, so the default suite run is unaffected.

## Files

- `demo_base.gd`: walkthrough machinery (steps, captions, keys, panels, graph, zoom insets).
- `checks/review_section.gd`: check helpers (built on the suite's `LitSuiteSection`).
