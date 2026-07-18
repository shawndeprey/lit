shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver (self-shadow exclusion) + both physical shadow algorithms, for scenes
// mixing Cone Traced and Stochastic lights.
#define LIT_SELF_EXCLUSION
#define LIT_SHADOW_CONE
#define LIT_SHADOW_STOCH
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
