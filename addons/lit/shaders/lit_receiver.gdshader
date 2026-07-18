shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full Lit receiver: every feature, including self-shadow exclusion. Receivers that
// never use exclusion should use lit_receiver_fast.gdshader instead (identical output,
// faster); LitSprite2D picks the right variant automatically.
#define LIT_SELF_EXCLUSION
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
