shader_type canvas_item;
render_mode unshaded; // we do our own lighting; skip Godot's built-in canvas light() pass

// OpenGL/Compatibility receiver (the web export path). Twin of
// lit_receiver_fast.gdshader: identical code plus LIT_GL_COMPAT, which makes the
// include chain synthesize the screen->march-space mapping (Godot's 2D SDF built-ins
// don't exist on Compatibility) and replace the shadow march with cheap per-light
// fallbacks (point/spot radial pools; directionals stay fully lit - no occluder data
// on OpenGL). LitShaderLibrary.ensure_gl_materials() repoints authored materials at
// these files on Compatibility builds.
#define LIT_GL_COMPAT
#include "res://addons/lit/shaders/receiver/lit_receiver_common.gdshaderinc"
