shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver + y-sort + per-light shadow-mask exclusion + per-receiver exclusion rects.
#define LIT_SELF_EXCLUSION
#define LIT_YSORT
#define LIT_OCC_MASKS
#define LIT_OCC_RX
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
