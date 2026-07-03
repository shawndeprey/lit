shader_type canvas_item;
render_mode blend_add;

// Full-screen procedural pixel-art rain streaks.
// Put this on a screen-space ColorRect covering the viewport.
// No texture needed — streaks are drawn and animated in-shader.

uniform float intensity = 0.6;            // 0..1 density + opacity
uniform vec4  streak_color : source_color = vec4(0.72, 0.82, 1.0, 0.85);
uniform float pixel_size = 2.0;           // chunky pixel grid
uniform float fall_speed = 1.6;           // higher = faster
uniform float slant = 0.18;               // horizontal lean (wind)
uniform float streak_len = 0.055;         // length of each streak (UV)
uniform vec2  columns = vec2(90.0, 1.0);  // number of rain columns across
uniform float aspect = 1.777;             // viewport w/h, set from script

float hash11(float p){ return fract(sin(p * 127.1) * 43758.5453); }
float hash21(vec2 p){ return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	// Pixelate the sampling coordinate to a chunky grid
	vec2 uv = floor(SCREEN_UV * res / pixel_size) * pixel_size / res;

	// Apply slant so streaks lean with the wind
	uv.x += uv.y * slant;

	// Divide screen into vertical columns of falling drops
	float col = floor(uv.x * columns.x);
	float colFrac = fract(uv.x * columns.x);

	// Each column gets its own phase, speed and horizontal jitter
	float seed = hash11(col);
	float speed = fall_speed * (0.6 + seed * 0.9);
	float phase = seed * 10.0;

	// Vertical position of this column's streak, scrolling downward
	float y = fract(uv.y * 3.0 + TIME * speed + phase);

	// Random gaps: only some cells actually have a drop this cycle
	float cell = floor(uv.y * 3.0 + TIME * speed + phase);
	float present = step(1.0 - intensity, hash21(vec2(col, cell)));

	// Distance to the streak center line within the column
	float lineDist = abs(colFrac - 0.5);
	float lineMask = smoothstep(0.14, 0.0, lineDist);

	// The streak itself: a short vertical segment with a bright head
	float head = smoothstep(streak_len, 0.0, y);          // bright tip
	float body = smoothstep(streak_len * 2.2, 0.0, y);    // main streak
	float tail = smoothstep(streak_len * 4.0, 0.0, y) * 0.4;
	float streak = max(max(head, body * 0.7), tail) * lineMask * present;

	COLOR.rgb = streak_color.rgb;
	COLOR.a = streak * streak_color.a * clamp(intensity * 1.4, 0.0, 1.0);
}
