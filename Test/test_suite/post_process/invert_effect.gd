@tool
extends LitPostEffect

## Suite fixture: a custom post effect that overrides _shader() with an inline inverting
## shader and mirrors one export through _param_map(). @tool only because LitPostEffect
## is a tool script; it is never placed in a scene.

static var _sh: Shader
func _shader() -> Shader:
	if _sh == null:
		_sh = Shader.new()
		_sh.code = "shader_type canvas_item;\nuniform sampler2D screen : hint_screen_texture;\n" \
				+ "uniform float amount = 1.0;\nvoid fragment() { vec4 c = texture(screen, SCREEN_UV);\n" \
				+ "COLOR = vec4(mix(c.rgb, 1.0 - c.rgb, amount), 1.0); }\n"
	return _sh
var amount := 1.0
func _param_map() -> Dictionary:
	return {"amount": "amount"}
