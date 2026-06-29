shader_type canvas_item;
render_mode unshaded, blend_add;

// Tint-buffer writer. A LitTintModifier mirrors a translucent object's sprite into the
// tint SubViewport with THIS shader, so the object stamps its colour + density into the
// screen-space tint buffer at its own screen location. The receiver shader and the beam
// post-pass then sample that buffer to tint light, shadows, and visible shafts.
//
// Output convention (PREMULTIPLIED ADDITIVE), matched by lit_tint_resolve() in the receiver
// and the beam pass:
//   COLOR.rgb = tint * density   (the tint a ray picks up here, premultiplied by density)
//   COLOR.a   = density          (how strongly this pixel tints; 0 = clear)
// The buffer is CLEARED to (0,0,0,0) each frame and uses ADDITIVE blend. So when two glass
// panes overlap on the SAME texel, their premultiplied colours and densities SUM. A reader
// reconstructs the true tint as rgb / a (a density-weighted average of the overlapping
// panes) and reads density straight from a. This is why overlapping gems now composite —
// red over blue lands purple in the overlap — instead of the top one replacing the bottom.
//
// (Previously this used blend_mix, which is last-write-wins: an overlapping stamp REPLACED
// whatever was beneath it for that texel, so only the topmost gem showed. The red->blue->
// purple compositing the feature is named for still also happens along a LIGHT'S path across
// DIFFERENT texels — a ray multiplies the resolved tints it crosses — but now overlap on a
// single texel composites too.)

// The object's own art, sampled in its UV so the tint stays pinned to the sprite shape.
uniform sampler2D source_tex : hint_default_white;

// The tint this object imparts. Reuses the receiver's transmission_color meaning: the hue
// light takes on passing through the body. source_color so it's authored in sRGB.
uniform vec3 tint_color : source_color = vec3(1.0, 0.2, 0.2);

// Packed transmission map, SAME layout the receiver uses:
//   R = transmission / thickness (drives how much light gets through -> density here)
//   G = opacity
//   B = reserved
// White default = full transmission everywhere, so density tracks the sprite alpha alone.
uniform sampler2D transmission_map : hint_default_white;

// Master density scale. 0 disables this writer (stamps nothing); 1 is full. Lets a pane be a
// faint wash or a deep stained glass without re-authoring the map.
uniform float density : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	// Read the sprite's own TEXTURE (set on the mirror to the gem art) for the silhouette
	// alpha, so the stamp is shaped like the gem. source_tex is kept as a uniform alias for
	// callers that prefer to drive it explicitly, but TEXTURE is the authoritative geometry.
	vec4 src = texture(TEXTURE, UV);

	// Thickness from the transmission map's R: thicker -> tints harder. Combined with the
	// sprite's own alpha so transparent edges of the art don't stamp tint into empty space.
	float thickness = texture(transmission_map, UV).r;
	float d = src.a * thickness * density;

	// PREMULTIPLIED ADDITIVE: rgb = tint*d, a = d. Additive blend over the (0,0,0,0) clear
	// means an un-stamped texel stays zero (a no-op for readers, since they gate on a>0) and
	// overlapping stamps sum. Readers divide rgb by a to recover the density-weighted tint.
	COLOR = vec4(tint_color * d, d);
}
