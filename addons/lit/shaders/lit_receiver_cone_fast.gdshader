shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Fast receiver + the Cone Traced shadow algorithm. Used automatically (LitSprite2D)
// when some light selects Cone Traced and none selects Stochastic.
#define LIT_SHADOW_CONE
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
