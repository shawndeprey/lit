// Unit: Cook-Torrance BRDF helpers: lit_d_ggx(), lit_g_smith(), lit_f_schlick().

// --- PBR helpers (Cook-Torrance microfacet BRDF) ------------------------------------
// Trowbridge-Reitz / GGX normal distribution.
float lit_d_ggx(float n_dot_h, float roughness) {
	float a = roughness * roughness;
	float a2 = a * a;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	return a2 / max(LIT_PI * d * d, 1e-6);
}

// Smith geometry term (Schlick-GGX) using the direct-lighting k remap.
float lit_g_smith(float n_dot_v, float n_dot_l, float roughness) {
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;
	float gv = n_dot_v / (n_dot_v * (1.0 - k) + k);
	float gl = n_dot_l / (n_dot_l * (1.0 - k) + k);
	return gv * gl;
}

// Schlick Fresnel approximation.
vec3 lit_f_schlick(float v_dot_h, vec3 f0) {
	return f0 + (1.0 - f0) * pow(clamp(1.0 - v_dot_h, 0.0, 1.0), 5.0);
}

