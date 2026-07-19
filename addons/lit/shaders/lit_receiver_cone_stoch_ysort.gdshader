shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver (self-shadow exclusion) + both physical shadow algorithms +
// Y-sort shadow ordering (lit/render/y_sort).
#define LIT_SELF_EXCLUSION
#define LIT_SHADOW_CONE
#define LIT_SHADOW_STOCH
#define LIT_YSORT
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
