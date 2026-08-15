shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// OpenGL/Compatibility receiver (the web export path). Twin of
// lit_receiver_ysort.gdshader: full receiver + the y-sort shadow depth test, plus
// LIT_GL_COMPAT (see lit_receiver_fast_gl.gdshader for what that does).
#define LIT_SELF_EXCLUSION
#define LIT_YSORT
#define LIT_GL_COMPAT
#include "res://addons/lit/shaders/receiver/lit_receiver_common.gdshaderinc"
