shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver + Stochastic + per-receiver exclusion rects (shadow_receiver_mask).
#define LIT_SELF_EXCLUSION
#define LIT_SHADOW_STOCH
#define LIT_OCC_RX
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
