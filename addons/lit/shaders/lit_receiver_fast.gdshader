shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Fast Lit receiver: identical to lit_receiver.gdshader except the self-shadow
// exclusion feature is compiled out (LIT_SELF_EXCLUSION undefined), which measurably
// speeds up the shadow marches for every receiver. Output is identical for any
// receiver whose material never gets self_rects populated - which is everything
// except a LitSprite2D that owns LightOccluder2Ds with self_shadow off; those need
// lit_receiver.gdshader. LitSprite2D swaps between the variants automatically, and
// the self_* uniforms are still declared here so the swap preserves parameters.
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
