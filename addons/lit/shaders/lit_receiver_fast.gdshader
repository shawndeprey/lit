shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Fast Lit receiver: lit_receiver.gdshader with self-shadow exclusion compiled out.
// Identical output for any material that never populates self_rects; a LitSprite2D
// that owns occluders with self_shadow off needs the full shader (it swaps
// automatically).
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
