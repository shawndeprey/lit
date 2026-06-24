shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform float wobble_strength = 2.0;   
uniform float wobble_speed = 4.0;      
uniform float chroma_shift = 2.0;      
uniform float bleed = 0.5;             
uniform float grain = 0.12;            
uniform float tracking_strength = 0.6; 
uniform float tracking_speed = 0.2;    
uniform float roll_strength = 0.1;     

const int BLEED_TAPS = 4;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	float t = TIME;

	float band_pos = fract(-t * tracking_speed);
	float band = smoothstep(0.12, 0.0, abs(SCREEN_UV.y - band_pos)) * tracking_strength;

	float line_id = floor(SCREEN_UV.y / px.y);
	float jitter = hash21(vec2(line_id, floor(t * wobble_speed * 8.0))) - 0.5;
	float drift = sin(SCREEN_UV.y * 6.0 + t * wobble_speed) * 0.3;
	float shift_px = (jitter * 2.0 + drift) * (wobble_strength + band * 24.0);

	vec2 uv = SCREEN_UV;
	uv.x += shift_px * px.x;

	float cs = (chroma_shift + band * 6.0) * px.x;
	vec3 col;
	col.r = texture(screen_texture, uv + vec2(cs, 0.0)).r;
	col.g = texture(screen_texture, uv).g;
	col.b = texture(screen_texture, uv - vec2(cs, 0.0)).b;

	vec3 smear = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < BLEED_TAPS; i++) {
		float w = 1.0 - float(i) / float(BLEED_TAPS);
		smear += texture(screen_texture, uv - vec2(float(i) * 2.0 * px.x, 0.0)).rgb * w;
		wsum += w;
	}
	smear /= max(wsum, 0.0001);
	col = mix(col, smear, bleed);

	float n = hash21(floor(SCREEN_UV / px) + vec2(fract(t) * 113.0, fract(t) * 57.0));
	col += (n - 0.5) * (grain + band * 0.5);

	float bar = sin((SCREEN_UV.y + t * 0.1) * TAU);
	col *= 1.0 + roll_strength * bar * 0.5;
	col += band * 0.15;

	COLOR = vec4(col, 1.0);
}
