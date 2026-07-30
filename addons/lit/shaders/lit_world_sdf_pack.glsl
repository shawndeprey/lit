#[compute]
#version 450

// Packs the world-SDF encode target's R channel into an R16F texture, quartering the
// bytes receiver marches pull per sample. Values are copied bit-exact (both are f16).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	imageStore(dst, p, vec4(texelFetch(src, p, 0).r));
}
