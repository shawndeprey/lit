# Lit — Human Steps & Per-Phase Test Guide

A companion to `plan.md`. `plan.md` is for the coding agent; **this file is for you.** It covers the Godot-editor work the agent can't do, the setup, and a per-phase checklist of what to put in a test scene and what you should see. The core mindset: **the agent writes code but is blind to rendered output — you are the eyes.** It builds; you look and report back.

---

## 0. Prerequisites

- **Godot 4.4 or newer**, the **standard build** (not the .NET/C# build — this plugin is pure GDScript).
- **VS Code** with **Claude Code**.
- **git** installed.

---

## 1. One-time project setup (do this before involving the agent)

1. Launch Godot, create a new project named e.g. `lit-dev`.
2. When creating it, confirm the renderer is **Forward+** (the default). The whole plan assumes Forward+; Mobile/Compatibility are out of scope.
3. Open the project once so Godot generates `project.godot`, then close Godot.
4. In a terminal at the project folder: `git init`, then commit the empty project. (Working under git matters here — you'll commit after each verified phase so a broken later phase never costs you a working earlier one.)
5. Copy **`plan.md`** and **this file** into the project root.
6. Open the project folder in VS Code and start Claude Code there.

> First agent task, if you don't already have one: ask it to write a **Godot `.gitignore`** (ignoring `.godot/`, `*.import` caches, etc.). Do this before it writes plugin code so your first real commit is clean.

---

## 2. The opening prompt for Claude Code

Paste something like this to start:

> This folder is an empty Godot 4.4+ project (Forward+ renderer). `plan.md` is a complete implementation spec for a 2D lighting plugin called **Lit**. Read it fully first.
>
> Important: you **cannot run Godot or see rendered output**. I will do all in-editor testing and report results back to you — do not pretend to test or assume something renders correctly.
>
> Implement **Phase 1 only** from §11, following the file structure in §6 and the committed decisions in §5. When Phase 1 is code-complete, stop and give me a short checklist of what to do in the Godot editor to verify it before we continue to Phase 2.

Then work **strictly one phase at a time.** Don't let it build all six at once — when something looks wrong in a later phase, you want the earlier phases already confirmed good.

---

## 3. Enabling the plugin (the part first-timers miss)

A Godot plugin lives in `addons/lit/` and is defined by `addons/lit/plugin.cfg`. **None of it works until you enable it:**

- **Project → Project Settings → Plugins → enable "Lit".**

You will re-toggle this (or restart Godot) **whenever the `EditorPlugin` registration code changes**, because Godot caches editor-plugin state. Symptoms that you need to re-toggle or restart:

- The `Lit*` nodes don't appear in the **Add Node** dialog.
- The shader complains about unknown `global uniform`s (the global-shader-parameter registration in `plan.md` D1 runs from the plugin's `_enter_tree`; toggling re-runs it).

**Rule of thumb:** if something that "should exist" doesn't, toggle the plugin off/on first, and if that fails, fully restart Godot, before assuming the code is wrong.

---

## 4. Build your test scene early (and reuse it)

Make one small scene you carry through every phase. Minimum:

- A **`Sprite2D`** whose texture is a **`CanvasTexture`** (not a plain PNG) — see the note below.
- One **`LitPointLight2D`**.
- One **`LitCanvasModulate`**.

### The CanvasTexture / normal-map detail (important)

Normal-mapped lighting only *looks* like anything if the sprite has a normal map. In the Sprite2D's **Texture** slot, create a **`CanvasTexture`**, then:

- **Diffuse Texture** = your base art (any PNG; the Godot icon is fine to start).
- **Normal Texture** = a normal map for that art. If you don't have one, the lighting will still work but look flat/uniform (which is *correct* — flat surface, no surface detail — just undramatic).
- **Specular Texture** (optional) = for shiny highlights later.

If you want to actually see normals doing their job, grab or generate one normal map for your test sprite. A quick option: any "normal map generator" will turn a PNG into a passable normal map. Having one properly-mapped test sprite makes Phases 1–3 far easier to judge.

---

## 5. Per-phase verification checklists

After each phase, the agent should hand you its own checklist; this is your independent version. **Commit to git after each phase passes.**

### Phase 1 — Core lighting (point lights, no shadows)

Setup: the test scene above. Assign the `lit_receiver` shader material to the `Sprite2D` (the agent will tell you how; in Phase 1 it's manual). Set the `LitCanvasModulate` color to a dark grey.

You should see:
- [ ] With the light disabled/removed, the sprite is **dark** (ambient from `LitCanvasModulate`).
- [ ] With a `LitPointLight2D` near it, the sprite is **lit where the light reaches** — light punches *through* the darkness, not crushed by it.
- [ ] **Moving the light** changes which parts are lit; **changing `energy`/`color`** changes intensity/hue.
- [ ] If your sprite has a normal map, the shading is **directional** (the lit side faces the light) and shifts as the light moves around it.
- [ ] **Add 20+ lights** overlapping one sprite — all contribute, **no sudden cutoff or flicker** (this is the uncapped headline; the built-in system would break at ~16).
- [ ] No errors in the Output/Debugger panel.

Likely snags: shader won't compile about `global uniform`s → toggle the plugin (see §3). Sprite fully black with a light on → coordinate-space or material issue; report exactly what you see.

### Phase 2 — Shadows

Setup: add a **`LightOccluder2D`** with an occluder polygon between the light and part of the sprite. Confirm its **SDF Collision** property is enabled (default). Enable `shadow_enabled` on the light.

You should see:
- [ ] The occluder **casts a shadow** across the lit sprite.
- [ ] **`shadow_hardness` near 1** = crisp edges; **near 0** = soft, spread penumbra.
- [ ] `shadow_color` tints the shadowed region.
- [ ] Turning `shadow_enabled` off removes the shadow but keeps the lighting.

Likely snag: no shadow at all → check the occluder's SDF Collision is on, and that **Project Settings → Rendering → 2D → SDF** options exist/are sane (the agent may ask you to raise SDF scale/oversize for quality, per the plan).

### Phase 3 — Directional lights + shadows

Setup: add a **`LitDirectionalLight2D`**.

You should see:
- [ ] **Uniform** lighting across the sprite (no positional falloff — same everywhere).
- [ ] **Rotating the node** changes the light direction (and normal-mapped shading follows).
- [ ] With an occluder + `shadow_enabled`, a **directional (parallel) shadow** is cast.

### Phase 4 — Workflow + editor-live preview

Setup: try a fresh **`LitSprite2D`**; try the **"Make Selected Sprites Lit"** tool on a plain `Sprite2D`; set `light_mask`/receiver masks; try a **Subtract** blend-mode light.

You should see:
- [ ] **Editor-live:** moving a light **relights the scene in the editor viewport** without running the game. (This is the big quality-of-life win — verify it actually updates live.)
- [ ] `LitSprite2D` is lit immediately with no manual material setup.
- [ ] The tool converts a selected plain `Sprite2D` into a working receiver.
- [ ] A light only affects receivers whose **mask shares a bit** with it.
- [ ] A **Subtract** light **darkens** rather than brightens.

Likely snag: editor-live not updating → the `EditorPlugin` editor-side `refresh()` (timer/signals) isn't firing; toggle the plugin, then report.

### Phase 5 — Post-processing

Setup: add a **`LitPostProcess`** node to the scene.

You should see:
- [ ] **Bloom:** bright lit areas bleed a soft glow; `bloom_threshold`/`intensity`/`radius` change it sensibly.
- [ ] **Color grade:** exposure/contrast/saturation/tint visibly affect the whole frame.
- [ ] **Threshold** and **Vignette** toggles do what they say.
- [ ] Each pass can be toggled independently without breaking the others.

### Phase 6 — Packaging

You should see:
- [ ] Disabling then re-enabling the plugin from Project Settings works cleanly (no leftover errors).
- [ ] The included **example scene** opens and looks correct.
- [ ] `plugin.cfg`, icons, and README are present.
- [ ] (Optional dry run) The `addons/lit/` folder is self-contained and could be copied into another project.

---

## 6. Working rhythm with the agent

- **One phase at a time.** Verify, commit, then say "Phase N verified, proceed to Phase N+1."
- **Report what you SEE, not what you think is wrong.** "The sprite is solid black even with a light touching it" is more useful than "the shader's broken." The agent debugs from observations.
- **Screenshots help** if your setup allows pasting them — visual bugs are hard to describe.
- **Keep the same test scene** across phases so you're comparing like with like.
- **When stuck, suspect the plugin-enable/restart cache first** (§3) before assuming logic errors — it's the most common false alarm for first-time plugin authors.

---

## 7. Two values you'll tune by eye (not bugs)

`plan.md` §14 lists tunable defaults. Two are purely aesthetic and can't be "correct" on paper — expect to nudge them once Phases 2 and 1 render:

- The **specular constant `K`** (§9.2) — controls highlight tightness.
- The **penumbra range `mix(8.0, 256.0, hardness)`** (§9.3) — controls how the hardness slider feels.

If shadows or highlights look slightly off but everything else works, these are the dials, not a defect.
