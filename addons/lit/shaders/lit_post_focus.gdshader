shader_type canvas_item;

// Focus post pass (post-v1, to_do_post_processing.md). The two ends of one focus dial:
// negative `amount` = soft / dream blur, positive = sharpen. Both work off a blurred
// reference (cheap mip blur, same trick as bloom): the blur side blends toward it, the
// sharpen side unsharp-masks against it. `dream` screen-blends the blurred image back
// in for the hazy highlight glow on the soft side. Runs last (final lens focus).
//
// Depends on screen-texture mipmaps for filter_linear_mipmap (works in Godot 4.7).
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

uniform float amount = -0.5;   // < 0 = soft/dream blur, > 0 = sharpen, 0 = off
uniform float radius = 2.0;    // blur reach (mip level): sharpen ~1, dream blur ~2-4
uniform float dream = 0.2;     // soft side only: hazy highlight glow (screen blend)

void fragment() {
	vec3 original = texture(screen_texture, SCREEN_UV).rgb;
	vec3 blurred = textureLod(screen_texture, SCREEN_UV, radius).rgb;

	vec3 col;
	if (amount < 0.0) {
		// Soft focus: blend toward the blurred image, then screen-blend a little of the
		// blur back in for a dreamy haze.
		col = mix(original, blurred, -amount);
		col = 1.0 - (1.0 - col) * (1.0 - blurred * dream);
	} else {
		// Sharpen (unsharp mask): amplify the difference from the blurred reference.
		col = original + (original - blurred) * amount;
	}

	COLOR = vec4(col, 1.0);
}
