shader_type canvas_item;
render_mode blend_add;

// Expanding ring ripple. Particle lifetime progress is delivered through the
// particle's per-instance color alpha (set via a ParticleProcessMaterial
// Alpha curve going 0 -> 1 over lifetime).
uniform vec4 ring_color : source_color = vec4(0.75, 0.85, 1.0, 0.6);
uniform float pixel_size = 2.0;

void fragment() {
	vec2 c = UV - vec2(0.5);
	// Snap to a pixel grid (texture assumed ~32-64px quad)
	float px = pixel_size / 64.0;
	c = floor(c / px) * px;
	float d = length(c);

	// COLOR.a arrives as lifetime progress 0->1 from the particle system
	float t = clamp(COLOR.a, 0.0, 1.0);
	float r = 0.08 + t * 0.34;          // ring grows outward
	float ring = smoothstep(0.035, 0.0, abs(d - r));
	float fade = 1.0 - t;               // fades as it expands

	COLOR.rgb = ring_color.rgb;
	COLOR.a = ring * fade * ring_color.a;
}
