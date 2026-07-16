shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full Lit receiver: every feature, including self-shadow exclusion (the self_rects
// march that keeps a sprite's own occluders from shadowing it). Carrying that path
// costs real GPU time even on receivers that never use it, so materials that don't
// need it should use lit_receiver_fast.gdshader instead - identical output, faster.
// LitSprite2D picks the right variant automatically. The entire implementation lives
// in lit_receiver_common.gdshaderinc; this file just selects the variant.
#define LIT_SELF_EXCLUSION
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
