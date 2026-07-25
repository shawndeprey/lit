shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Fast receiver + Stochastic + globally excluded occluder rects.
#define LIT_SHADOW_STOCH
#define LIT_OCC_GX
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
