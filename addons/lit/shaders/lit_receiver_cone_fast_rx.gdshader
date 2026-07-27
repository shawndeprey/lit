shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Fast receiver + Cone Traced + per-receiver exclusion rects (shadow_receiver_mask).
#define LIT_SHADOW_CONE
#define LIT_OCC_RX
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
