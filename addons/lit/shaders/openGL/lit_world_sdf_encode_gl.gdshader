shader_type canvas_item;
render_mode unshaded, blend_disabled;

// OpenGL/Compatibility encode twin (the web export path). The Forward+ encoder copies
// Godot's native 2D SDF into this viewport's color target as signed distance in world
// pixels; Compatibility has no native 2D SDF (texture_sdf / screen_uv_to_sdf are
// unavailable), so there is nothing to copy. The Compatibility receivers never sample
// this texture - lit_sdf_sample short-circuits to "no occluders" - so the encoder
// writes a flat sentinel that compiles everywhere. screen_to_world is kept for
// parameter parity with the Forward+ encoder.
uniform float screen_to_world = 1.0;

void fragment() {
	COLOR = vec4(1.0, 0.0, 0.0, 1.0);
}
