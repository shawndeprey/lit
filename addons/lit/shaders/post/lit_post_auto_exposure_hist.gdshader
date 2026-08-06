shader_type canvas_item;

// One fragment per (bin, row group): sums the center-weighted mass of its row
// group's reduce texels landing in its bin, so no thread scans more than RH/GROUPS
// rows and the adapt pass reads small pre-binned partials. 24-bit RGB fixed point
// over [0, RW * RH]; the adapt pass sums groups in order, preserving the exact
// per-bin float summation order of a full sequential scan.
uniform sampler2D reduce_tex : hint_default_black, filter_nearest;
uniform float center_weight = 0.6;

const int RW = 64;                 // must match the node's _REDUCE_SIZE
const int RH = 36;
const int BINS = 64;               // must match the adapt shader
const int GROUPS = 6;              // must match the adapt shader and _HIST_SIZE.y

void fragment() {
	int b = int(SCREEN_UV.x * float(BINS));
	int g = int(SCREEN_UV.y * float(GROUPS));
	float mass = 0.0;
	for (int y = g * (RH / GROUPS); y < (g + 1) * (RH / GROUPS); y++) {
		for (int x = 0; x < RW; x++) {
			int k = int(texelFetch(reduce_tex, ivec2(x, y), 0).r * float(BINS - 1) + 0.5);
			if (k == b) {
				vec2 n = (vec2(float(x), float(y)) + 0.5) / vec2(float(RW), float(RH)) - 0.5;
				mass += mix(1.0, exp(-12.0 * dot(n, n)), center_weight);
			}
		}
	}
	float v = clamp(mass / float(RW * RH), 0.0, 1.0) * 16777215.0;
	float hi = floor(v / 65536.0);
	float mid = floor((v - hi * 65536.0) / 256.0);
	COLOR = vec4(vec3(hi, mid, floor(v - hi * 65536.0 - mid * 256.0)) / 255.0, 1.0);
}
