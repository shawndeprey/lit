shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver + Cone Traced + Stochastic + y-sort + per-light shadow-mask exclusion.
#define LIT_SELF_EXCLUSION
#define LIT_SHADOW_CONE
#define LIT_SHADOW_STOCH
#define LIT_YSORT
#define LIT_OCC_MASKS
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
