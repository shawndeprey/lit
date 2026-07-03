shader_type canvas_item;

// Screen "lens" droplets — scattered, varied sizes, occasional trails.
// Fixed the old grid-lattice look by giving each cell a random offset + radius.

uniform float intensity = 0.6;
uniform float pixel_size = 2.0;
uniform vec4  drop_tint : source_color = vec4(0.82, 0.88, 0.98, 0.5);
uniform float density = 40.0;   // cells across screen; higher = more, smaller drops

vec2 hash22(vec2 p){
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}
float hash21(vec2 p){ return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float asp = res.x / res.y;
	vec2 uv = SCREEN_UV;
	uv.x *= asp;                       // square up cells

	vec2 grid = vec2(density);
	vec2 id = floor(uv * grid);
	vec2 f = fract(uv * grid);

	// Refresh droplets in slow waves so they pop in/out, not all at once
	float wave = floor(TIME * 0.8 + hash21(id) * 6.28);
	vec2 rnd = hash22(id + wave);

	// Random position inside the cell + random radius
	vec2 center = vec2(0.2 + rnd.x * 0.6, 0.2 + rnd.y * 0.6);
	float radius = (0.06 + hash21(id + wave + 3.7) * 0.14);

	// Only a fraction of cells are active, scaled by intensity
	float active = step(1.0 - intensity * 0.5, hash21(id + wave + 1.3));

	// Pixelate the droplet edge
	vec2 d = f - center;
	d = floor(d * res / (pixel_size * grid)) * (pixel_size * grid) / res;
	float dist = length(d);
	float dot_mask = smoothstep(radius, radius * 0.4, dist) * active;

	// A little downward trail under some droplets
	float trailCol = step(0.6, rnd.x);
	float trail = smoothstep(0.0, 0.5, f.y - center.y)
	            * smoothstep(radius * 0.6, 0.0, abs(f.x - center.x))
	            * active * trailCol * 0.4;

	float a = max(dot_mask, trail);
	COLOR.rgb = drop_tint.rgb;
	COLOR.a = a * drop_tint.a * intensity;
}
