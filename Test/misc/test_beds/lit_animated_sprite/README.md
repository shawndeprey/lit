# LitAnimatedSprite2D probe

Exploratory test bed for the LitAnimatedSprite2D feature assessment (2026-09-13).

`probe.gd` opens a window, builds one white `LitPointLight2D` far to the left of a
row of bare `AnimatedSprite2D` nodes that carry the Lit receiver material, and
samples the rendered brightness at each sprite's center to answer one question:
does the receiver shader read `CanvasTexture` normal maps out of `SpriteFrames`
frames, for every frame shape the SpriteFrames panel produces?

| Sprite | Frame texture | Expected |
|---|---|---|
| A | plain `ImageTexture` | flat mid brightness |
| B | `CanvasTexture`, normal facing the light | brighter than A |
| C | `CanvasTexture`, normal facing away | darker than A |
| D | `AtlasTexture` whose `atlas` is a `CanvasTexture` sheet (right half) | equals C |
| E | `CanvasTexture` whose diffuse/normal slots are `AtlasTexture`s into sheets | equals C |

Every shape also gets a hidden `Sprite2D` twin at the identical position; a second
capture with the rows swapped must match the first shape-for-shape.

Run from the repo root (needs the real renderer, so no `--headless`):

```
/Applications/Godot.app/Contents/MacOS/Godot --path . --script res://Test/misc/test_beds/lit_animated_sprite/probe.gd
```

Writes `probe_out_animated.png` and `probe_out_sprite2d.png` beside this file and
prints `PROBE RESULT: PASS|FAIL`, plus a `note:` line reporting whether shape E honors
its atlas region (it does not; that is an engine limitation that applies to `Sprite2D`
as well, so per-frame `CanvasTexture`s wrapping `AtlasTexture`s are not a usable
sprite-sheet workflow - use `AtlasTexture` frames over one `CanvasTexture` sheet).
