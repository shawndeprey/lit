shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// Full receiver + the y-sort shadow depth test, for participating receivers only.
#define LIT_SELF_EXCLUSION
#define LIT_YSORT
#include "res://addons/lit/shaders/lit_receiver_common.gdshaderinc"
