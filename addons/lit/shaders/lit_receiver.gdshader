shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Transport: global uniforms plus the per-frame light-data texture, packed by the
// manager. Read via texelFetch (integer coords, no filtering), so the texture's
// filter mode doesn't matter here.
global uniform sampler2D lit_light_data;
global uniform int       lit_light_count;
global uniform int       lit_directional_count;         // directionals occupy rows [0, this)
global uniform vec2      lit_viewport_size;             // pixels
global uniform float     lit_canvas_scale;              // world-to-screen px scale (camera/editor zoom)
global uniform vec4      lit_ambient_color : source_color;
global uniform float     lit_ambient_energy;

// Tiled light culling: the manager bins each positional light into a screen-tile grid
// and uploads a per-tile header (offset + count into the index list) plus a flat index
// list of light rows. A fragment then shades only the lights in its own tile instead of
// looping every light. texelFetch with nearest filtering, same as the data texture.
global uniform sampler2D lit_tile_headers;
global uniform sampler2D lit_tile_indices;
global uniform ivec2     lit_tile_grid;                 // tiles across, tiles down
global uniform int       lit_tile_size;                 // tile edge in pixels

// Optional adaptive shadow march, driven by the lit/quality/* project settings via the
// manager. When scaling is on, a fragment spends march steps in proportion to how far
// it has to march, capped at lit_shadow_steps_max.
global uniform int  lit_shadow_steps_max;
global uniform bool lit_shadow_step_scaling;

// --- Stained-glass tint buffer ----------------------------------------------
// Screen-space buffer published by LitTintBuffer (PREMULTIPLIED ADDITIVE): for any point on
// screen, rgb = tint*density and a = density, summed over every translucent pane covering
// that texel. A reader recovers the tint as rgb/a (the density-weighted hue of all overlapping
// panes) and density from a. The receiver walks this buffer from the fragment toward each
// light, the SAME path it already marches for shadows, and multiplies the light by the tint
// it crosses. So light through a red pane then a blue pane arrives purple, overlapping panes
// composite in their overlap, and the shadow inherits the tint. An all-zero default (no buffer
// published, a==0 everywhere) makes the whole thing a no-op.
global uniform sampler2D lit_tint_buffer : source_color, filter_linear, hint_default_black;

// Per-receiver opt-in. Off by default so receivers in scenes with no translucent glass pay
// nothing. LitSprite2D can proxy this like its other receiver controls.
uniform bool tint_enabled = false;
// How VIVID the coloured light and shadow are. 1 = full stained-glass colour (the tint
// multiplies the light contribution at full saturation); lower values fade the gathered tint
// toward neutral white before it multiplies, so the coloured shadows read as a subtle wash
// rather than a saturated gel. Affects lit colour and the colour of the shadow it throws
// together, since both come from the same tint. ~0.4–0.6 is a restrained look.
uniform float tint_strength : hint_range(0.0, 1.0) = 1.0;
// How many samples to take along the fragment->light path when gathering tint. Cheap (a
// texture read each), independent of the shadow march budget. 8–16 reads smoothly.
uniform int tint_samples : hint_range(2, 32) = 12;

// The index list is stored as a 2D texture this wide, so a flat index maps to
// (idx % WIDTH, idx / WIDTH). Must match INDEX_TEX_WIDTH in the registry.
const int LIT_INDEX_TEX_WIDTH = 2048;

// Compile-time ceiling on the shadow loop so it can be unrolled; lit_shadow_steps_max
// is clamped to this on the CPU.
const int LIT_MAX_SHADOW_STEPS = 256;

uniform float emissive_strength = 0.0;
uniform sampler2D emissive_mask : hint_default_white;   // white default lets strength work alone

// A light affects this receiver only if (light_mask & receiver_mask) != 0. Plain int,
// since shader uniforms have no layers hint; LitSprite2D proxies it with a nicer
// 2D-render-layers control.
uniform int receiver_mask = 1;

uniform float specular_strength = 0.5;
uniform float specular_k = 32.0;

// --- Internal reflections (gem sparkle) -------------------------------------
// A SECOND specular lobe, separate from the surface specular above, meant to read as
// light glinting off facet planes INSIDE the stone rather than off its outer skin. The
// trick: shade it with a different normal than the surface uses, so its highlights point
// in their own directions and skate across the body independently as a light orbits. Pure
// addition on top of everything else; opt-in, off by default (strength 0) so non-gem
// receivers pay nothing. Shaded with a distinct facet normal so its highlights point their
// own way and skate across the body independently as a light orbits.
uniform float internal_strength = 0.0;
// Facet normal map for the INTERNAL planes, in tangent space like any normal map
// (flat default (0.5,0.5,1.0) = facing the viewer, so strength alone does nothing until a
// real map is authored). Sampled in the sprite's own UV so the facets stay pinned to the
// art. Deliberately a distinct sampler from the CanvasTexture normal that drives surface
// shading: the whole point is that internal facets face elsewhere.
uniform sampler2D internal_normal_map : hint_normal;
// Tightness of the internal glints. Higher = smaller, sharper, more sparkle-like hotspots.
// Separate from specular_k so the inside can flash hard while the surface stays soft.
uniform float internal_k = 96.0;

// --- Depth absorption (gem volume / thickness tint) -------------------------
// The body reads as having VOLUME when thicker parts are richer and darker, the way thick
// glass deepens in colour (Beer-Lambert absorption). Shows in a still frame with no motion.
// Driven by the transmission map's B channel: deeper (bright B) absorbs more, so the lit
// colour is pulled toward absorption_color and dimmed in proportion to depth. Off by
// default (strength 0).
uniform float absorption_strength = 0.0;
// The colour the body deepens TOWARD with thickness (a saturated version of the gem hue
// reads best -- e.g. a deep magenta for this stone). source_color so it's authored in sRGB.
uniform vec3  absorption_color : source_color = vec3(0.2, 0.0, 0.15);

// --- Chromatic dispersion (gem fire) ----------------------------------------
// Modifier on the internal lobe above: a real gem splits light into colour at its facet
// edges. Rather than add a term, we sample the internal lobe at three slightly offset
// sharpness thresholds and tint them R/G/B, so the hotspot core stays near-white while its
// fringe fans into spectral colour. amount is the spread; 0 collapses all three onto the
// same threshold (no dispersion, pure internal_strength behaviour). Costs nothing when
// internal_strength is 0, since the whole internal block is gated on that.
uniform float dispersion_amount = 0.0;

// --- Refraction (background bend, "option 2": reuse the internal facet normal) -----
// Fakes a faceted stone bending the scene behind it WITHOUT tracing a view ray. The
// internal facet normal already encodes the facet planes; its xy IS a direction, so we
// push the background sample by it. Facets tilted left pull the background from the left,
// each facet zone samples a different spot, and the seams between facets break the image
// the way a cut stone does. Not physically calibrated -- it's the cheap stand-in for real
// refraction -- but it reads because the offset follows the authored facet geometry.
//
// The background is the already-rendered frame behind this sprite (SCREEN_TEXTURE), so the
// gem must draw AFTER what it refracts and a back buffer must be available (BackBufferCopy
// over the gem, or just rely on Godot's default screen texture). Opt-in, off by default
// (strength 0) so opaque receivers pay nothing -- no screen sample, no extra texture read.
uniform float refraction_strength = 0.0;
// Max background shift in screen-UV units at full facet tilt. Small (0.01-0.05) reads as a
// dense gem; large smears. Scaled by the internal normal's xy magnitude per fragment, so
// flat facets (normal facing the viewer) barely shift and steep facets push hardest.
uniform float refraction_amount = 0.03;
// How much the refracted background tints by the gem's body colour on the way through.
// 0 = the background shows through uncoloured (clear glass); 1 = fully multiplied by albedo
// (deeply tinted stone). The reference magenta wants this fairly high.
uniform float refraction_tint = 0.6;
// The rendered frame behind the sprite. hint_screen_texture gives Godot's screen copy;
// filtered+mipmapped so the offset sample stays smooth. Only ever read when strength > 0.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

// Translucency: light reaching this fragment from a light on the FAR side of the
// surface, tinted and shaped like it passed through the body of the sprite. Opt-in,
// off by default (strength 0) so opaque receivers pay nothing. Where diffuse uses
// max(dot(N, L), 0), transmission uses the back-facing lobe dot(-N, L), wrapped so the
// whole body glows rather than only the rim directly facing away from the light.
uniform float transmission_strength = 0.0;
uniform vec3  transmission_color : source_color = vec3(1.0);
// Thickness / where light gets through. Sampled in the sprite's own UV (not screen UV)
// so it stays pinned to the art. White default lets strength work with no map authored.
// Packed transmission map. Channels carry independent signals, ORM-style:
//   R = transmission / thickness  (how much light glows through; 1 = full, 0 = opaque metal)
//   G = opacity                   (per-pixel alpha; 1 = solid, 0 = fully see-through)
//   B = reserved                  (future: per-pixel occlusion-opacity / IOR / roughness)
// Sampled in the sprite's own UV so it stays pinned to the art. White default (1,1,1,1)
// is the identity case: full transmission where strength is on, fully opaque, so existing
// sprites are unchanged on upgrade.
uniform sampler2D transmission_map : hint_default_white;
// How strongly the map's G channel drives per-pixel alpha. 0 = ignore G, sprite keeps its
// own texture alpha (old behavior); 1 = G fully controls opacity. Lets a sprite opt into
// per-pixel transparency without forcing it.
uniform float transmission_alpha_amount = 0.0;
// 0.0 = only the rim facing away from the light glows; 1.0 = the entire body glows
// evenly. Mid values give a gem-like falloff brightest opposite the light.
uniform float transmission_wrap = 0.5;

uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

// Horizontal reach of a directional light's shading vector relative to its `height`;
// elevation is atan(height / scale). The default gives about 27 degrees at height 16,
// so the direction reads clearly. Larger is more grazing.
uniform float directional_horizontal_scale = 32.0;

// How far a directional shadow marches across the SDF before it counts as open sky,
// in screen diagonals. Scaling to screen size keeps the fixed step budget
// well-sampled; a fixed huge distance would under-sample the penumbra.
uniform float directional_shadow_reach = 1.0;

// Soft-shadow march of Godot's screen-space SDF (the IQ technique). Works in SDF
// space, marching from the fragment toward the light and tracking the running minimum
// of k * d / t for the penumbra. Returns 1 fully lit, 0 occluded. max_steps lets the
// caller spend fewer iterations on short marches; the loop bound stays constant so it
// can unroll.
float lit_shadow(vec2 frag_sdf, vec2 light_sdf, float hardness, int max_steps) {
	// Screen-space SDF has no notion of 2D draw order. A fragment sitting inside
	// an occluder's footprint is treated as on top of it, so a sprite drawn over
	// an occluder stays lit instead of self-shadowing. (Distinct occluders that
	// lie between this fragment and the light still cast normally.)
	if (texture_sdf(frag_sdf) <= 0.0) {
		return 1.0;
	}
	vec2 delta = light_sdf - frag_sdf;
	float maxd = length(delta);
	if (maxd < 0.0001) {
		return 1.0;                          // light is on the fragment
	}
	vec2 dir = delta / maxd;
	float t = shadow_min_step;
	float res = 1.0;
	float k = mix(8.0, 256.0, hardness);     // low hardness is soft, high is crisp
	for (int s = 0; s < LIT_MAX_SHADOW_STEPS; s++) {
		if (s >= max_steps || t >= maxd) {
			break;
		}
		float d = texture_sdf(frag_sdf + dir * t);
		if (d < 0.001) {
			return 0.0;                      // fully occluded
		}
		res = min(res, k * d / t);           // penumbra accumulation
		t += max(d, shadow_min_step);
	}
	return clamp(res, 0.0, 1.0);
}

// Walk the tint buffer in screen-UV from the fragment toward the light, multiplying the
// tint of every translucent texel crossed. Returns the colour multiplier light arriving at
// this fragment has picked up: (1,1,1) if the path is clear, tinted if it passed through
// stained glass, compounding (red then blue -> purple) across multiple panes. `to_light_uv`
// is the screen-UV vector from fragment to light (already direction*reach for a directional).
// Mirrors the beam pass's accumulation so a lit surface and the shaft above it agree.
vec3 lit_tint_along(vec2 frag_uv, vec2 to_light_uv) {
	vec3 tint = vec3(1.0);
	float steps_f = float(tint_samples);
	for (int s = 0; s < 32; s++) {
		if (s >= tint_samples) {
			break;
		}
		float t = (float(s) + 0.5) / steps_f;
		vec2 p = frag_uv + to_light_uv * t;
		if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) {
			break;
		}
		vec4 tb = texture(lit_tint_buffer, p);
		// Fail-safe: an UNSET global sampler (no LitTintBuffer in the scene yet) reads all-zero,
		// and a genuinely clear texel is also (0,0,0,0). Both have a<=0, so skip — no tint, and
		// crucially no divide-by-zero in the reconstruct below.
		if (tb.a <= 0.0) {
			continue;
		}
		// Buffer is PREMULTIPLIED ADDITIVE: rgb = tint*density summed over every pane on this
		// texel, a = density summed. tb.rgb/tb.a is the density-weighted AVERAGE hue of the panes
		// — but averaging two hues pulls toward grey at the dense overlap centres (red+blue
		// averages to muddy grey), which washed the centre of overlaps out. Stained glass should
		// MULTIPLY: red then blue gets darker and more saturated, not greyer.
		vec3 avg_tint = tb.rgb / tb.a;
		// Recover "how many panes' worth of glass" as the total density, and apply the average
		// hue once PER unit of density via pow. One pane (a≈1) tints once; two stacked panes
		// (a≈2) tint twice — the hue multiplies in again, deepening and saturating toward the
		// product instead of averaging toward grey. clamp the exponent so a huge stack stays sane.
		float layers = clamp(tb.a, 0.0, 4.0);
		tint *= pow(avg_tint, vec3(layers));
	}
	return tint;
}


vec3 lit_shade(int i, vec3 albedo, vec3 N, vec3 internal_N, vec3 spec_shin, float shininess,
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag, vec2 model_uv) {
	// Texel 0 carries the cheap fields (type | flags | mask | falloff) so masked-out
	// lights bail after a single fetch, before any position/color/shadow texels.
	vec4 t0 = texelFetch(lit_light_data, ivec2(0, i), 0);

	// type: 0 = point, 1 = directional, 2 = spot. flags bit 0 = shadow_enabled,
	// bit 1 = subtractive.
	int type = int(round(t0.x));
	bool is_directional = type == 1;
	bool is_spot = type == 2;
	int flags = int(round(t0.y));
	bool shadow_enabled = (flags & 1) != 0;
	bool subtractive = (flags & 2) != 0;
	float falloff = t0.w;

	// Skip lights this receiver's mask doesn't share a bit with, before paying for
	// any of the work below.
	int light_mask = int(round(t0.z));
	if ((light_mask & receiver_mask) == 0) {
		return vec3(0.0);
	}

	vec4 t1 = texelFetch(lit_light_data, ivec2(1, i), 0); // uv.xy / dir.xy | range | energy
	vec4 t2 = texelFetch(lit_light_data, ivec2(2, i), 0); // color.rgb | height

	vec2 light_uv = t1.xy;
	float range = t1.z;
	float energy = t1.w;
	vec3 light_color = t2.rgb;
	float height = t2.w;

	vec3 Ldir;
	float atten;
	vec2 shadow_dir_uv = vec2(0.0);          // toward-light dir in screen-UV space (directional only)

	if (is_directional) {
		// t1.xy is a unit screen-space direction toward the light. No position, no
		// attenuation; `height` sets the elevation.
		vec2 dir_px = t1.xy;
		Ldir = normalize(vec3(dir_px * directional_horizontal_scale, height));
		atten = 1.0;
		shadow_dir_uv = dir_px / lit_viewport_size; // pixel dir to UV dir
	} else {
		// Point or spot: work in screen pixels. `range` and `height` are authored in
		// world units, so scale them by the world-to-screen factor (camera/editor zoom)
		// into the same space as to_light_px below. The factor cancels in both dist/range
		// and the Ldir normalize, so point/spot shading is identical at any zoom.
		float range_px = range * lit_canvas_scale;
		float height_px = height * lit_canvas_scale;
		vec2 to_light_px = (light_uv - frag_uv) * lit_viewport_size;
		float dist = length(to_light_px);
		if (dist > range_px) {
			return vec3(0.0);                // beyond range
		}
		Ldir = normalize(vec3(to_light_px, height_px));
		atten = pow(clamp(1.0 - dist / range_px, 0.0, 1.0), falloff);

		// A spot is a point light masked to a cone (texel 4): aim.xy is the
		// screen-space direction it points. The fragment is lit if it falls inside
		// the cone, with a soft edge between the inner and outer angle.
		if (is_spot) {
			vec4 t4 = texelFetch(lit_light_data, ivec2(4, i), 0); // aim.xy | cos_outer | cos_inner
			vec2 dir_to_frag = (dist > 0.0001) ? (-to_light_px / dist) : t4.xy;
			float cone = smoothstep(t4.z, t4.w, dot(t4.xy, dir_to_frag));
			atten *= cone;
		}
	}

	// Fully attenuated (out of range, or outside a spot's cone): nothing to add
	// and no shadow to march.
	if (atten <= 0.0) {
		return vec3(0.0);
	}

	float ndotl = max(dot(N, Ldir), 0.0);

	vec3 diffuse = albedo * light_color * energy * ndotl * atten;

	// Sharpened N.L lobe, tight and only where the surface tilts toward the light.
	// Tinted by light_color so the highlight takes the light's hue instead of blowing
	// out to white. Skipped entirely when there's no specular map or strength.
	vec3 specular = vec3(0.0);
	if (specular_strength > 0.0 && dot(spec_shin, spec_shin) > 0.0) {
		specular = light_color * spec_shin * energy * atten * pow(ndotl, 1.0 + shininess * specular_k) * specular_strength;
	}

	vec3 contribution = diffuse + specular;

	// Internal reflections: a second, tighter specular lobe shaded by the INTERNAL facet
	// normal instead of the surface normal, so its glints point their own way and walk
	// across the body independently as the light moves -- the cut-stone read. Gated on
	// strength so non-gem receivers skip it entirely (and with it the dispersion work).
	if (internal_strength > 0.0) {
		// Use the Blinn-Phong HALF-VECTOR, not raw dot(N, L). In 2D the view direction is
		// straight at the screen, V = (0,0,1); Ldir for a point light is nearly flat
		// (its xy is in screen pixels, hundreds of units, while its z/height is small), so
		// a raw dot against a viewer-facing (+z) facet normal stays tiny and the lobe never
		// lights. The half-vector H = normalize(L + V) tilts the comparison toward the
		// viewer, so a +z facet catching a glancing light still scores a high dot(N, H).
		// This is the correct reflection model and makes internal_k a predictable sharpness.
		vec3 H = normalize(Ldir + vec3(0.0, 0.0, 1.0));
		float in_dot = max(dot(internal_N, H), 0.0);
		// The internal lobe gets its OWN sharpness from internal_k, independent of the
		// surface specular's per-pixel shininess. internal_k IS the exponent: higher =
		// smaller, sharper, more sparkle-like hotspots.
		float in_exp = max(internal_k, 1.0);

		if (dispersion_amount > 0.0) {
			// Gem fire: split the lobe into R/G/B by raising it to three offset exponents.
			// A sharper exponent gives a smaller, more concentrated hotspot, so the three
			// channels peak at slightly different tightnesses -- the core stays near-white
			// where they overlap and the fringe fans into spectral colour. Spread is a
			// fraction of the base exponent (up to ~40% at amount 1.0) so it stays a fringe
			// rather than blowing the channels apart now that in_exp is large.
			float spread = in_exp * dispersion_amount * 0.4;
			float gr = pow(in_dot, max(in_exp - spread, 1.0));   // red: broadest fringe
			float gg = pow(in_dot, in_exp);                      // green: the base lobe
			float gb = pow(in_dot, in_exp + spread);             // blue: tightest core
			vec3 fire = vec3(gr, gg, gb);
			// Still tinted by the light's hue so a coloured light doesn't read as a flat
			// rainbow; the dispersion is a fringe ON the light colour, not a replacement.
			contribution += light_color * fire * energy * atten * internal_strength;
		} else {
			// No dispersion: a single monochrome internal glint, tinted by the light.
			float glint = pow(in_dot, in_exp);
			contribution += light_color * glint * energy * atten * internal_strength;
		}
	}

	// Translucency: the back-facing lobe. dot(-N, Ldir) is large where the surface
	// faces AWAY from the light, i.e. light entering the far side and emerging here.
	// The wrap remap lifts the whole body out of hard darkness so a gem reads as a
	// solid glowing mass, not just a bright back edge. Tinted by transmission_color
	// (the gem's internal hue) and the light, attenuated like any other contribution,
	// and gated by the thickness mask sampled in the sprite's own UV.
	if (transmission_strength > 0.0) {
		float back = dot(-N, Ldir);
		float t_lobe = max((back + transmission_wrap) / (1.0 + transmission_wrap), 0.0);
		float thickness = texture(transmission_map, model_uv).r;
		vec3 transmission = albedo * transmission_color * light_color * energy
			* t_lobe * atten * thickness * transmission_strength;
		contribution += transmission;
	}

	// Negligible contribution: bail before the expensive SDF shadow march. Below this
	// the result is indistinguishable from black anyway.
	if (max(contribution.r, max(contribution.g, contribution.b)) < 0.004) {
		return vec3(0.0);
	}

	// Stained-glass tint: gather the colour this light picked up crossing translucent
	// objects between the fragment and the light, and multiply the whole contribution by
	// it. Applied BEFORE the shadow march so the shadow term (which scales contribution
	// below) inherits the tint too — a red-then-blue path lights the surface purple AND
	// throws a purple shadow. Gated on tint_enabled so non-glass scenes pay nothing.
	if (tint_enabled) {
		vec2 to_light_uv;
		if (is_directional) {
			// Directional light is at infinity; reuse the shadow direction, marched a screen
			// reach along the incoming direction (same convention as the shadow block).
			to_light_uv = shadow_dir_uv * directional_shadow_reach;
		} else {
			to_light_uv = light_uv - frag_uv;
		}
		// Fade the gathered tint toward neutral white by tint_strength, so the coloured light
		// and the shadow it throws can be dialled from full stained-glass to a subtle wash
		// without touching the gems themselves.
		vec3 gathered = lit_tint_along(frag_uv, to_light_uv);
		contribution *= mix(vec3(1.0), gathered, tint_strength);
	}

	// Marched only for shadow-casting lights, so a light with shadows off pays nothing
	// here, not even the texel-3 fetch. In shadow the contribution is tinted by
	// shadow_color (black blocks the light entirely). Factor 1 is lit, 0 is occluded.
	if (shadow_enabled) {
		vec4 t3 = texelFetch(lit_light_data, ivec2(3, i), 0); // shadow_color.rgb | shadow_hardness
		vec2 light_sdf;
		if (is_directional) {
			// March a fixed direction across the SDF. screen_uv_to_sdf is affine, so
			// the SDF-space direction comes from offsetting the fragment UV along the
			// toward-light dir; the distance scales with the screen.
			vec2 dir_sdf = normalize(screen_uv_to_sdf(frag_uv + shadow_dir_uv) - frag_sdf);
			light_sdf = frag_sdf + dir_sdf * sdf_diag * directional_shadow_reach;
		} else {
			// Point and spot both march toward the light's screen position.
			light_sdf = screen_uv_to_sdf(light_uv);
		}

		// Adaptive step budget: shorter marches need fewer steps to stay well-sampled.
		// Scale by the march length as a fraction of the screen diagonal; keep a floor
		// so very short marches still resolve a penumbra. Off by default (fixed budget).
		int steps = shadow_steps;
		if (lit_shadow_step_scaling) {
			float march_len = length(light_sdf - frag_sdf);
			float frac = clamp(march_len / max(sdf_diag, 0.0001), 0.0, 1.0);
			steps = int(ceil(frac * float(lit_shadow_steps_max)));
			steps = clamp(steps, 16, lit_shadow_steps_max);
		}

		float s = lit_shadow(frag_sdf, light_sdf, t3.w, steps);
		contribution *= mix(t3.rgb, vec3(1.0), s);
	}

	// Subtract mode is negative light: it carves darkness below ambient, and the
	// final COLOR clamps at display.
	return subtractive ? -contribution : contribution;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 albedo = tex.rgb * COLOR.rgb;
	vec3 N = normalize(NORMAL);                  // from the CanvasTexture normal map; faces out when absent
	vec3 spec_shin = SPECULAR_SHININESS.rgb;
	float shininess = SPECULAR_SHININESS.a;

	// Internal facet normal for the gem-sparkle lobe, decoded from tangent-space [0,1] to
	// [-1,1] like any normal map. Sampled in the sprite's own UV (not SCREEN_UV) so the
	// facets stay pinned to the art. Flat default map = (0,0,1), harmless since lit_shade
	// only uses this when internal_strength > 0.
	vec3 internal_N = normalize(texture(internal_normal_map, UV).xyz * 2.0 - 1.0);

	// Ambient base: albedo lit by the (dark) ambient term.
	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy;

	vec2 frag_uv = SCREEN_UV;                     // canonical screen-UV space
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  // shadow-march space

	// Screen diagonal in SDF units: the natural scale for a directional shadow's march
	// distance, keeping the step budget well-sampled at any resolution.
	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	// Tiling is only used once the manager has published a grid; until then (and in the
	// zero-light case) fall back to looping every light.
	bool tiling_valid = lit_tile_grid.x > 0 && lit_tile_grid.y > 0 && lit_tile_size > 0;

	if (tiling_valid) {
		// Directional lights cover the whole screen, so they're never tiled: shade the
		// leading directional rows for every fragment.
		for (int i = 0; i < lit_directional_count; i++) {
			lit += lit_shade(i, albedo, N, internal_N, spec_shin, shininess, frag_uv, frag_sdf, sdf_diag, UV);
		}

		// Positional lights: look up this fragment's tile and shade only the lights
		// binned into it. The header gives the offset/count into the flat index list.
		ivec2 tile = ivec2(SCREEN_UV * lit_viewport_size) / lit_tile_size;
		tile = clamp(tile, ivec2(0), lit_tile_grid - ivec2(1));
		vec4 header = texelFetch(lit_tile_headers, tile, 0); // offset | count
		int offset = int(round(header.x));
		int count = int(round(header.y));
		for (int j = 0; j < count; j++) {
			int flat_idx = offset + j;
			ivec2 icoord = ivec2(flat_idx % LIT_INDEX_TEX_WIDTH, flat_idx / LIT_INDEX_TEX_WIDTH);
			int li = int(round(texelFetch(lit_tile_indices, icoord, 0).x));
			lit += lit_shade(li, albedo, N, internal_N, spec_shin, shininess, frag_uv, frag_sdf, sdf_diag, UV);
		}
	} else {
		// Fallback: no tile grid published, so iterate every light.
		for (int i = 0; i < lit_light_count; i++) {
			lit += lit_shade(i, albedo, N, internal_N, spec_shin, shininess, frag_uv, frag_sdf, sdf_diag, UV);
		}
	}

	// Emissive ignores the dark and composes with ambient and lights by construction.
	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	// Depth absorption: thicker parts of the body deepen toward absorption_color and dim,
	// giving the stone visible volume in a still frame. Depth is the transmission map's B
	// channel (1 = deepest). The mix pulls lit colour toward the absorption tint and the
	// (1 - depth*strength) factor darkens with thickness, Beer-Lambert style.
	if (absorption_strength > 0.0) {
		float depth = texture(transmission_map, UV).b;
		float a = depth * absorption_strength;
		lit = mix(lit, lit * absorption_color, a) * (1.0 - a * 0.5);
	}

	// Refraction ("option 2"): bend the background behind the gem using the internal facet
	// normal we already decoded above. internal_N.xy is the facet's in-plane tilt; pushing
	// the screen sample by it makes each facet zone pull the background from its own spot,
	// with hard breaks at the facet seams -- the cut-stone read, no view ray required.
	// Gated on strength so non-gem receivers never sample the screen texture.
	if (refraction_strength > 0.0) {
		vec2 refr_offset = internal_N.xy * refraction_amount;
		vec3 bg = texture(screen_tex, SCREEN_UV + refr_offset).rgb;
		// Tint the bent background toward the body hue WITHOUT a second full multiply: mix
		// toward a luminance-only version of the tint so an already-coloured background
		// (post-process, halation) can't compound into deep red. luminance keeps the bent
		// scene's brightness while refraction_tint pulls its hue toward the stone.
		float bg_lum = dot(bg, vec3(0.299, 0.587, 0.114));
		vec3 tinted_bg = mix(bg, bg_lum * albedo, refraction_tint);
		// SEE-THROUGH compose: mix the gem's lit body TOWARD the bent background, so the stone
		// is genuinely transparent to the distorted scene behind it (you see the wall, bent),
		// not merely brightened by it. refraction_strength is how see-through the body is.
		// Then add the gem's own specular/internal glints back on top at full strength so the
		// sparkle still sits over the glass -- those are bright, additive, and read as surface
		// reflections regardless of how transparent the body is. (The lit-body diffuse is what
		// we make transparent; the glints ride on top.)
		lit = mix(lit, tinted_bg, refraction_strength);
	}

	// Per-pixel opacity from the packed map's G channel, blended in by alpha_amount so
	// it's strictly opt-in: at 0 the sprite keeps its own texture alpha (old behavior),
	// at 1 the G channel fully drives opacity. mix toward G means metal (G=1) stays solid
	// and glass (low G) goes see-through.
	float opacity = mix(1.0, texture(transmission_map, UV).g, transmission_alpha_amount);

	COLOR = vec4(lit + emissive, tex.a * COLOR.a * opacity);
}
