shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Fast receiver + the Stochastic shadow algorithm. Used automatically (LitSprite2D)
// when some light selects Stochastic and none selects Cone Traced.
#define LIT_SHADOW_STOCH
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
