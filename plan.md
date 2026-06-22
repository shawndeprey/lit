# Lit — A Drop-In 2D Lighting System for Godot 4

## Purpose of this document

This is an **implementation specification**, written to be built top-to-bottom by an automated coding agent (e.g. Claude Code in VS Code). It does not assume the implementer can run Godot, eyeball results, or iterate on feel. Every technique is a **committed decision** with enough detail to build directly. Where a value can only be tuned against real hardware, a known-good default is given and flagged as developer-tunable after the fact.

---

## 1. Overview

**Lit** is an open-source Godot 4 plugin: a drop-in, *alongside* replacement for Godot's built-in 2D lighting system. It removes the limitations that make the built-in system unusable for serious 2D work — chiefly the hardcoded ~15-light-per-CanvasItem cap and the weak shadow options — while preserving the native, node-based, animatable workflow.

**Guiding ethos:** stay inside Godot's grain. Reuse native subsystems (`CanvasTexture`, `LightOccluder2D` + the screen-space SDF, the node/inspector/animation workflow) wherever possible. Only build new machinery where the engine genuinely blocks us. A developer adds a light to a node, configures it, and moves on — exactly as today.

**Targets (fixed):**
- Engine: **Godot 4.4+**.
- Renderer: **Forward+ only.** Mobile and Compatibility (GLES3) are out of scope.
- Distribution: **pure GDScript + shaders**, no GDExtension/C++/engine fork. `addons/`-structured, Godot Asset Library installable. Public open-source repo.

---

## 2. Goals

- **Uncapped lights.** No hardcoded per-object light limit. The developer controls how many lights exist and tunes performance against that number. Off-screen lights cost nothing.
- **Developer-controlled shadows.** Per-light toggle for shadow casting, plus a per-light **hardness slider** spanning hard → soft.
- **Native-feeling nodes** mirroring the built-in property surface as closely as the architecture allows; fully `@export`'d, scriptable, animatable.
- **Native workflow preservation.** Keep `CanvasTexture` (diffuse/normal/specular), keep `LightOccluder2D` for shadow authoring, keep the "add a node, set values, done" gesture.
- **Built-in post-processing.** Bloom, color grade, threshold, and friends, exposed as settings on a single node.
- **Layer-on-top adoption.** Drop the plugin into an existing project and replace built-in lights incrementally.
- **Editor-live preview.** Lighting updates live in the 2D editor viewport while building scenes.

## 3. Non-Goals (v1)

- No Mobile or Compatibility renderer support.
- No deferred/G-buffer renderer; no rebuild of `CanvasTexture`.
- No GDExtension/C++/engine fork.
- No `next_pass` chaining / foreign custom-shader compatibility. **Receivers use our material in the primary `material` slot only.** (A sprite that needs a custom shader is simply not a Lit receiver in v1.)
- No byte-identical reproduction of the built-in passes — the goal is the same effect and better, via our own mechanism.
- No light tiling/binning in build scope. The v1 transport is a direct per-pixel light loop (see §11). Performance optimization is measured and decided by the developer *after* v1 exists; it is not the agent's concern.

---

## 4. Hard Requirements

1. **Uncapped lights** is the non-negotiable headline. The transport must never reintroduce a fixed cap.
2. **Minimal, refined, readable code.** Tiebreaker between competing implementations and a continuous discipline. Governs *how cleanly each piece is written* — distinct from architecture, and never an argument against the uncapped goal. Prefer reusing native subsystems over rebuilding them; prefer the smallest addition that maintains functionality and readability.
3. **Pure GDScript + shaders**, Asset-Library installable, no end-user compile step.
4. **Forward+ / Godot 4.4+.**

---

## 5. Committed Technical Decisions

These are settled. Build to them directly; do not re-litigate or prototype.

**D1 — Light transport: global shader uniforms + a per-frame light-data texture.**
A central manager packs all on-screen lights into a floating-point **light-data texture** and exposes it (plus light count, viewport size, and ambient settings) as **global shader uniforms** (`RenderingServer.global_shader_parameter_set`). Receiver materials declare these as `global uniform` and read them with zero per-material wiring. The texture is the uncapped transport; a fixed-size uniform array is explicitly rejected because it would reintroduce a cap. Encoding in §9.4.
**Registration requirement:** `global uniform` names must exist in the project's Shader Globals before any shader can declare them, or the shader will fail to compile in-editor. On activation, `lit_plugin.gd` registers every `lit_*` global (`RenderingServer.global_shader_parameter_add`, or persisted in `ProjectSettings`) and removes them on deactivation. Set texture filtering on the `ImageTexture` itself rather than via a sampler hint on the global.

**D2 — Receiver lighting runs in `fragment()`, with `render_mode unshaded`.**
All Lit lighting is computed in the receiver shader's `fragment()`. The shader declares `render_mode unshaded`, which disables Godot's built-in canvas light pass for that material. Consequence (this is the layer-on-top mechanism): **a Lit sprite is lit only by Lit; a non-Lit sprite is lit only by built-in `Light2D`.** The two systems coexist deterministically at the scene level with no double-lighting. Migration = convert objects area by area.

**D3 — Normals & specular come from `CanvasTexture` built-ins.**
The receiver reads the engine-provided `NORMAL` (auto-populated from the CanvasTexture normal map; defaults to facing-out when absent) and `SPECULAR_SHININESS` / `SPECULAR_SHININESS_TEXTURE`. We do not rebuild CanvasTexture; we consume what it exposes. *(Implementer: confirm against Godot 4.4 that `NORMAL` and `SPECULAR_SHININESS` are readable in `fragment()` with `render_mode unshaded` — `unshaded` disables only the `light()` pass, so `fragment()` and its built-ins remain active; the whole receiver depends on this holding.)*

**D4 — Shadows: per-light raymarch of the native screen-space SDF, with IQ soft shadows.**
Shadows use Godot's auto-generated screen-space signed distance field (`texture_sdf`, fed by `LightOccluder2D` nodes with SDF Collision enabled — the default). For each shadow-casting light, the receiver marches from the fragment toward the light through the SDF. Soft shadows use the Inigo Quilez penumbra method (track the running minimum of `hardness * d / t` along the march). The per-light **hardness** property maps to that sharpness factor: high = crisp, low = soft. Algorithm in §9.3. Defaults: 64 steps, min-step 0.2 (developer-tunable advanced uniforms).

**D5 — Directional lights and directional shadows are both in v1.**
Directional lights share the receiver code path via a type flag in the light-data texture (uniform direction, no positional falloff). Directional shadows march a fixed direction across the SDF (a simpler case than the point-light march; shares the same code).

**D6 — Emissive is handled inside the receiver shader.**
Emissive is a lighting behavior ("these pixels ignore the dark"), implemented as an input in the receiver shader (strength + optional mask channel), not as a stacked pass. Composes correctly with ambient and lights by construction.

**D7 — Darkness/ambient: `LitCanvasModulate`, a value source, replacing native `CanvasModulate`.**
`LitCanvasModulate` feeds ambient color/energy to the receiver as global uniforms. Lights resolve *with* ambient inside the shader, so they always punch through darkness by construction. It is a replacement for, not a companion to, the native `CanvasModulate`: a live native `CanvasModulate` would multiply our already-correct output and double-darken. The node warns at runtime/edit time if a live native `CanvasModulate` is detected.

**D8 — Post-processing: one `CanvasLayer` node with a chain of `ColorRect` passes.**
`LitPostProcess` reads the screen via `hint_screen_texture` and applies a chain of fullscreen `ColorRect` passes (with `BackBufferCopy` between passes that need the prior result), exposing bloom / color grade / threshold / etc. as settings. No viewport/Environment dependency. Bloom is LDR threshold-based (downsample → blur → upsample → composite), the 2D standard.

---

## 6. Plugin File Structure

```
addons/lit/
  plugin.cfg
  lit_plugin.gd            # EditorPlugin: registers nodes, drives editor-live gather
  nodes/
    lit_point_light_2d.gd
    lit_directional_light_2d.gd
    lit_canvas_modulate.gd
    lit_sprite_2d.gd
    lit_post_process.gd
  runtime/
    lit_manager.gd         # autoloaded; per-frame gather/cull/pack at runtime
    lit_light_registry.gd  # shared gather/cull/pack logic (used by both manager and editor plugin)
  shaders/
    lit_receiver.gdshader  # the receiver lighting shader (D2–D6)
    lit_post_bloom.gdshader
    lit_post_grade.gdshader
    lit_post_threshold.gdshader
    # …one shader per post pass
  icons/                   # editor icons for the custom nodes
```

All node scripts use `@tool` and `class_name` so they appear in the Create-Node dialog and run at edit time.

---

## 7. Node Specifications

All numeric properties are `@export`, animatable, and grouped sensibly in the inspector. Defaults below.

### 7.1 `LitPointLight2D` (extends `Node2D`)

| Property | Type | Default | Notes |
|---|---|---|---|
| `enabled` | bool | `true` | If false, excluded from gather. |
| `color` | Color | white | Light color. |
| `energy` | float | `1.0` | Intensity multiplier. |
| `range` | float | `256.0` | Radius of influence, pixels. Used for attenuation + AABB cull. |
| `falloff` | float | `1.0` | Attenuation curve exponent (see §9.2). |
| `texture` | Texture2D | null | Optional cookie/shape mask; when null, analytic round falloff is used. |
| `texture_scale` | float | `1.0` | Scales the cookie. |
| `height` | float | `16.0` | Z-height above the surface; drives normal-mapped shading. |
| `shadow_enabled` | bool | `false` | Whether this light casts shadows. |
| `shadow_color` | Color | black | Color multiplied into shadowed regions. |
| `shadow_hardness` | float | `0.5` | 0 = very soft, 1 = hard. Maps to IQ penumbra sharpness (§9.3). |
| `blend_mode` | enum {Add, Subtract} | Add | Subtract = negative light. |
| `light_mask` | int (bitmask) | `1` | Affects only receivers whose mask shares a bit (§9.5). |

On `_enter_tree` add to group `lit_lights`; on `_exit_tree` remove. Setting any property requests a gather refresh (see §8).

### 7.2 `LitDirectionalLight2D` (extends `Node2D`)

Same as `LitPointLight2D` except: no `range`/`falloff`/`texture_scale` (no positional attenuation); the node's rotation defines light direction; `height` still contributes to the normal-shading vector. Type flag in the data texture marks it directional.

| Property | Type | Default |
|---|---|---|
| `enabled` | bool | `true` |
| `color` | Color | white |
| `energy` | float | `1.0` |
| `height` | float | `16.0` |
| `shadow_enabled` | bool | `false` |
| `shadow_color` | Color | black |
| `shadow_hardness` | float | `0.5` |
| `blend_mode` | enum {Add, Subtract} | Add |
| `light_mask` | int (bitmask) | `1` |

### 7.3 `LitCanvasModulate` (extends `Node2D`, conceptually scene-global)

| Property | Type | Default | Notes |
|---|---|---|---|
| `color` | Color | `#1a1a1a` (dark grey) | Ambient/darkness color. |
| `ambient_energy` | float | `1.0` | Ambient multiplier. |

Behavior: on entering the tree (and on property change), writes `lit_ambient_color` and `lit_ambient_energy` global shader uniforms. Warns (push_warning + a configuration-warning in the editor) if a live native `CanvasModulate` is found in the tree. Only one active `LitCanvasModulate` is expected; if multiple, last-in-tree wins and a warning is emitted. Also the natural home for any future scene-global lighting settings.

### 7.4 `LitSprite2D` (extends `Sprite2D`)

A convenience receiver. On creation, ships with a `ShaderMaterial` using `lit_receiver.gdshader` already assigned to its `material`, and a `CanvasTexture` already assigned to `texture` (so the diffuse/normal/specular slots are immediately visible in the inspector). Exposes the receiver shader's per-instance parameters (e.g. `emissive_strength`) as convenient `@export`s that proxy to the material. Pure shortcut — equivalent to assigning the material to a plain `Sprite2D` by hand or via the editor tool (§10).

### 7.5 `LitPostProcess` (extends `CanvasLayer`)

Holds an ordered chain of fullscreen `ColorRect` children, one per enabled pass, each with its own pass shader, plus `BackBufferCopy` nodes where a pass must read the previous pass's output. Rebuilds its child chain when pass toggles change. Exposed settings (all `@export`, grouped):

- **Bloom:** `bloom_enabled` (bool), `bloom_threshold` (float, 1.0), `bloom_intensity` (float, 0.5), `bloom_radius` (float, 4.0).
- **Color grade:** `grade_enabled` (bool), `exposure` (float, 1.0), `contrast` (float, 1.0), `saturation` (float, 1.0), `tint` (Color).
- **Threshold:** `threshold_enabled` (bool), `threshold_cutoff` (float).
- **Vignette:** `vignette_enabled` (bool), `vignette_strength` (float), `vignette_softness` (float).

(Exact final pass set is a developer choice; bloom/grade/threshold/vignette are the v1 baseline.)

---

## 8. Gather / Cull / Pack (the manager)

Shared logic lives in `lit_light_registry.gd`; it is driven by `lit_manager.gd` (autoload) at runtime and by `lit_plugin.gd` (EditorPlugin) at edit time. Both call the same `refresh()`.

Per refresh:
1. Collect nodes in group `lit_lights` where `enabled`.
2. Determine the visible world rect from the active `Camera2D` / viewport (`get_viewport().get_visible_rect()` transformed into world space).
3. **AABB cull:** drop any point light whose `range`-expanded AABB does not intersect the visible rect. Directional lights are never positionally culled.
4. Convert each surviving light's world position to **normalized screen UV** (§9.0) via the viewport canvas transform, and pack all lights into the light-data `Image` (§9.4). Update the backing `ImageTexture`.
5. Set global shader uniforms: `lit_light_data` (the texture), `lit_light_count` (int), `lit_viewport_size` (vec2, pixels), plus ambient values from `LitCanvasModulate`.

Refresh cadence:
- **Runtime:** every frame in `_process` (cheap; the cost is the pack, not the per-pixel work). Dirty-tracking is a future optimization, not v1.
- **Editor:** the EditorPlugin triggers `refresh()` on a short timer and on relevant `NOTIFICATION_TRANSFORM_CHANGED` / property-change signals, so moving a light relights the viewport live. Autoloads do not run in the editor, which is exactly why the EditorPlugin is the editor-side driver.

---

## 9. Shader & Math Specifications

### 9.0 Coordinate spaces (read first — everything below depends on this)

There is **one canonical space for light positions: normalized screen UV** (origin top-left, `(0,0)`–`(1,1)`), the same space `SCREEN_UV` and the SDF helpers (`screen_uv_to_sdf`) use. Both the diffuse math and the shadow march operate from this, so lights and their shadows stay aligned.

- **Manager side (pack):** convert each light's world position to screen UV with the viewport's canvas transform: `screen_px = get_viewport().get_canvas_transform() * world_pos`, then `light_uv = screen_px / viewport_pixel_size`. Pack `light_uv` into texel 0 (§9.4). Directional lights pack a normalized direction instead.
- **Manager side (globals):** also publish `lit_viewport_size` (a `vec2`, pixels) as a global uniform so the shader can convert UV deltas back into pixel distances for attenuation.
- **Shader side (diffuse, §9.2):** work in pixels. `frag_uv = SCREEN_UV`; `to_light_uv = light_uv - frag_uv`; `to_light_px = to_light_uv * lit_viewport_size`; `dist = length(to_light_px)`. The shading direction is `vec3(to_light_px, height)` (so `dist`, `range`, and `height` are all in consistent pixel units).
- **Shader side (shadows, §9.3):** work in SDF space. `frag_sdf = screen_uv_to_sdf(SCREEN_UV)`; `light_sdf = screen_uv_to_sdf(light_uv)`.

This keeps one source of truth (screen UV), derives pixels from it for distance math, and derives SDF coords from it for shadows — no ambiguity for the implementer to guess at.

### 9.1 Receiver shader skeleton (`lit_receiver.gdshader`)

```
shader_type canvas_item;
render_mode unshaded;                 // D2: disable built-in light pass

global uniform sampler2D lit_light_data;                   // D1 transport; filtering set on the ImageTexture
global uniform int   lit_light_count;
global uniform vec2  lit_viewport_size;                    // §9.0, pixels
global uniform vec4  lit_ambient_color : source_color;     // D7
global uniform float lit_ambient_energy;

// per-instance (D6)
uniform float emissive_strength = 0.0;
uniform sampler2D emissive_mask : hint_default_white;      // white default → strength alone works; a mask restricts it

// advanced shadow tuning (D4)
uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    vec3 albedo = tex.rgb * COLOR.rgb;
    vec3 N = normalize(NORMAL);                 // D3, auto from CanvasTexture normal map
    vec3 spec_shin = SPECULAR_SHININESS.rgb;    // D3
    float shininess = SPECULAR_SHININESS.a;

    vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy;   // D7 ambient

    for (int i = 0; i < lit_light_count; i++) {
        // read_light unpacks the 4-texel record (§9.4)
        // skip if light_mask doesn't share a bit with this receiver's mask (§9.5)
        // compute diffuse + specular contribution (§9.2)
        // multiply by shadow factor (§9.3) if shadow_enabled
        // add (Add) or subtract (Subtract) per blend_mode
    }

    vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;  // D6
    COLOR = vec4(lit + emissive, tex.a * COLOR.a);
}
```

### 9.2 Lighting contribution (per light)

For a point light, in screen/pixel space:
- `Lvec = vec3(light_screen_pos - frag_screen_pos, height)`; `dist = length(Lvec.xy)`.
- If `dist > range` → contribution 0 (early-out).
- `Ldir = normalize(Lvec)`.
- `ndotl = max(dot(N, Ldir), 0.0)`.
- Attenuation: `atten = pow(clamp(1.0 - dist / range, 0.0, 1.0), falloff)`. If a `texture` cookie is set, multiply by the cookie sample instead of / in addition to analytic falloff.
- Diffuse: `albedo * light_color * energy * ndotl * atten`.
- Specular (Blinn-ish, optional per spec map): `spec_shin * energy * atten * pow(ndotl, 1.0 + shininess * K)` — exact form tunable; goal is parity with built-in specular intent.
- Multiply the whole contribution by the shadow factor (§9.3).

For a directional light: `Ldir = normalize(vec3(rotation_dir, height))`, no `dist`, no attenuation.

Accumulate with `+=` (Add) or `-=` (Subtract). Acceptance test is visual parity-or-better with the built-in look; the developer is the judge and tunes constants like `K`.

### 9.3 Soft shadow march (IQ penumbra)

Operates in SDF space. `frag_sdf = screen_uv_to_sdf(SCREEN_UV)`, `light_sdf = screen_uv_to_sdf(light_uv)` (where `light_uv` is texel 0, per §9.0).

```
float lit_shadow(vec2 frag_sdf, vec2 light_sdf, float hardness) {
    vec2  dir = normalize(light_sdf - frag_sdf);
    float maxd = length(light_sdf - frag_sdf);
    float t = shadow_min_step;
    float res = 1.0;
    float k = mix(8.0, 256.0, hardness);   // low hardness = soft, high = crisp
    for (int s = 0; s < shadow_steps; s++) {
        if (t >= maxd) break;
        float d = texture_sdf(frag_sdf + dir * t);
        if (d < 0.001) return 0.0;          // fully occluded
        res = min(res, k * d / t);          // penumbra accumulation
        t += max(d, shadow_min_step);
    }
    return clamp(res, 0.0, 1.0);
}
```

Result multiplies the light's contribution; in shadow, blend toward `shadow_color`. Directional shadows use the same routine with a fixed `dir` and a large fixed `maxd`.

### 9.4 Light-data texture encoding

Float-format texture (`Image.FORMAT_RGBAF`), size `4 × light_count` (4 RGBA texels = 16 floats per light), read with `texelFetch(lit_light_data, ivec2(col, i), 0)`:

| Texel | r | g | b | a |
|---|---|---|---|---|
| 0 | uv.x / dir.x | uv.y / dir.y | range | energy |
| 1 | color.r | color.g | color.b | height |
| 2 | shadow_color.r | shadow_color.g | shadow_color.b | shadow_hardness |
| 3 | type (0=point,1=dir) | flags | light_mask | falloff |

Position (texel 0) is in **normalized screen UV** for point lights, or a normalized direction for directional lights (§9.0).

**Integer fields are stored as plain floats and decoded with `int(...)` in-shader, not via bit-reinterpretation** (avoids relying on `floatBitsToInt` being exposed):
- `flags`: store `float(shadow_enabled) + 2.0 * float(subtractive)`; decode `int f = int(round(texel.g)); bool shadow = (f & 1) != 0; bool subtract = (f & 2) != 0;`.
- `light_mask`: store the bitmask as a float integer (e.g. `5.0` = bits 1+4); decode `int m = int(round(texel.b));` then `(m & receiver_mask) != 0` (§9.5).

Manager rewrites the `Image` each refresh and updates the `ImageTexture`; set nearest filtering, no mipmaps, on the `ImageTexture`. **Zero-light case:** when `lit_light_count == 0`, set the count global to 0 and bind a 1×1 dummy texture (do not allocate a `4 × 0` image); the receiver's light loop then runs zero iterations.

### 9.5 Light mask / layer

Replaces the engine's `range_*` / `*_item_cull_mask` properties (which are tied to engine culling we don't use). Each light has `light_mask`; each receiver has a matching `receiver_mask` (per-instance uniform on the receiver material, default `1`). A light affects a receiver only if `(light_mask & receiver_mask) != 0`. Same authoring intent ("this light only affects these things"), our plumbing.

---

## 10. Editor Integration

`lit_plugin.gd` (EditorPlugin):
- Registers all custom nodes (via `class_name`; icons from `icons/`).
- On `_enter_tree`: registers the `lit_*` global shader parameters (D1) and adds the `LitManager` autoload via `add_autoload_singleton("LitManager", "res://addons/lit/runtime/lit_manager.gd")`. On `_exit_tree`: removes both.
- Drives the editor-side `refresh()` (timer + transform/property signals) so lighting is live in the 2D viewport.
- Adds a tool (toolbar button or context menu) **"Make Selected Sprites Lit"**: for each selected `Sprite2D`, assigns the `lit_receiver` `ShaderMaterial` to its `material` slot (and a `CanvasTexture` wrapping its current texture if it isn't already one). This is the batch path for converting existing art; `LitSprite2D` is the from-scratch path.

---

## 11. Implementation Phases (build order)

Each phase is independently verifiable by the developer running Godot.

**Phase 1 — Core lighting, point lights, no shadows.**
`lit_light_registry` + `lit_manager` (autoload) + global-uniform plumbing + light-data texture pack/cull + `lit_receiver.gdshader` (ambient + point diffuse + specular + emissive, D2/D3/D6/D7) + `LitPointLight2D` + `LitCanvasModulate`. Manual material assignment on a plain `Sprite2D`. **Deliverable:** uncapped, culled, normal-mapped point lighting that punches through `LitCanvasModulate` darkness.

**Phase 2 — Shadows.**
Add the SDF march (§9.3) to the receiver; wire `shadow_enabled`, `shadow_color`, `shadow_hardness`. `LightOccluder2D` authoring (document enabling SDF Collision). **Deliverable:** per-light soft/hard shadows.

**Phase 3 — Directional lights + shadows.**
`LitDirectionalLight2D`, directional branch in shader and pack, directional shadow march (D5). **Deliverable:** directional lighting + shadows.

**Phase 4 — Workflow + editor-live.**
`LitSprite2D`, the "Make Selected Sprites Lit" tool, the light mask/layer system, subtractive blend mode, and the EditorPlugin editor-live `refresh()` (§10). **Deliverable:** native-feeling authoring with live preview.

**Phase 5 — Post-processing.**
`LitPostProcess` with the bloom/grade/threshold/vignette pass chain (D8). **Deliverable:** configurable look-and-feel layer.

**Phase 6 — Packaging.**
`plugin.cfg`, icons, README, example scene(s), Asset Library metadata. **Deliverable:** installable plugin.

---

## 12. Naming (locked)

| Name | Role |
|---|---|
| `LitPointLight2D` | Point light |
| `LitDirectionalLight2D` | Directional light |
| `LitSprite2D` | Convenience receiver (material + CanvasTexture pre-wired) |
| `LitCanvasModulate` | Ambient/darkness value source + scene-global settings |
| `LitPostProcess` | Post-processing chain |
| `LitManager` *(internal autoload)* | Runtime gather driver |
| `lit_receiver.gdshader` | Receiver lighting shader |

The `Lit` prefix is a double entendre — *lit* as in illuminated, *lit* as in excellent — and groups the nodes together in the Create-Node dialog next to the natives they mirror.

---

## 13. Developer Decisions After v1 (not the agent's concern)

These are measured and decided by the human once v1 runs; the agent should **not** build them speculatively:
- Whether the direct per-pixel light loop needs replacing with tiled/clustered light culling (depends on measured performance at the developer's real light counts and resolution).
- Dirty-tracking the gather instead of full per-frame repack.
- HDR light accumulation + Environment-based bloom, only if LDR threshold bloom proves insufficient.
- Per-light individual cookie/shape settings beyond the v1 set.

---

## 14. Tunable Defaults Summary

Known-good starting values the developer adjusts against real content: `shadow_steps = 64`, `shadow_min_step = 0.2`, point `range = 256`, `falloff = 1.0`, `height = 16`, `shadow_hardness = 0.5`, ambient `#1a1a1a @ 1.0`, bloom `threshold 1.0 / intensity 0.5 / radius 4.0`. None of these are correctness-critical; they are look/perf tuning.
