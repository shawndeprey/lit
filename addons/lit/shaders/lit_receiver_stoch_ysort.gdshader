shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Y-sort receiver + the Stochastic shadow algorithm.
#define LIT_SELF_EXCLUSION
#define LIT_YSORT
#define LIT_SHADOW_STOCH
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
