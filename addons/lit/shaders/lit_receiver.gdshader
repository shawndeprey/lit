shader_type canvas_item;
render_mode unshaded; 

global uniform sampler2D lit_light_data;
global uniform int       lit_light_count;
global uniform int       lit_directional_count;         
global uniform vec2      lit_viewport_size;             
global uniform vec4      lit_ambient_color : source_color;
global uniform float     lit_ambient_energy;

global uniform sampler2D lit_tile_headers;
global uniform sampler2D lit_tile_indices;
global uniform ivec2     lit_tile_grid;                 
global uniform int       lit_tile_size;                 

global uniform int  lit_shadow_steps_max;
global uniform bool lit_shadow_step_scaling;

const int LIT_INDEX_TEX_WIDTH = 2048;

const int LIT_MAX_SHADOW_STEPS = 256;

uniform float emissive_strength = 0.0;
uniform sampler2D emissive_mask : hint_default_white;   

uniform int receiver_mask = 1;

uniform float specular_strength = 0.5;
uniform float specular_k = 32.0;

uniform int   shadow_steps = 64;
uniform float shadow_min_step = 0.2;

uniform float directional_horizontal_scale = 32.0;

uniform float directional_shadow_reach = 1.0;

float lit_shadow(vec2 frag_sdf, vec2 light_sdf, float hardness, int max_steps) {

	if (texture_sdf(frag_sdf) <= 0.0) {
		return 1.0;
	}
	vec2 delta = light_sdf - frag_sdf;
	float maxd = length(delta);
	if (maxd < 0.0001) {
		return 1.0;                          
	}
	vec2 dir = delta / maxd;
	float t = shadow_min_step;
	float res = 1.0;
	float k = mix(8.0, 256.0, hardness);     
	for (int s = 0; s < LIT_MAX_SHADOW_STEPS; s++) {
		if (s >= max_steps || t >= maxd) {
			break;
		}
		float d = texture_sdf(frag_sdf + dir * t);
		if (d < 0.001) {
			return 0.0;                      
		}
		res = min(res, k * d / t);           
		t += max(d, shadow_min_step);
	}
	return clamp(res, 0.0, 1.0);
}

vec3 lit_shade(int i, vec3 albedo, vec3 N, vec3 spec_shin, float shininess,
		vec2 frag_uv, vec2 frag_sdf, float sdf_diag) {

	vec4 t0 = texelFetch(lit_light_data, ivec2(0, i), 0); 

	int type = int(round(t0.x));
	bool is_directional = type == 1;
	bool is_spot = type == 2;
	int flags = int(round(t0.y));
	bool shadow_enabled = (flags & 1) != 0;
	bool subtractive = (flags & 2) != 0;
	float falloff = t0.w;

	int light_mask = int(round(t0.z));
	if ((light_mask & receiver_mask) == 0) {
		return vec3(0.0);
	}

	vec4 t1 = texelFetch(lit_light_data, ivec2(1, i), 0); 
	vec4 t2 = texelFetch(lit_light_data, ivec2(2, i), 0); 

	vec2 light_uv = t1.xy;
	float range = t1.z;
	float energy = t1.w;
	vec3 light_color = t2.rgb;
	float height = t2.w;

	vec3 Ldir;
	float atten;
	vec2 shadow_dir_uv = vec2(0.0);          

	if (is_directional) {

		vec2 dir_px = t1.xy;
		Ldir = normalize(vec3(dir_px * directional_horizontal_scale, height));
		atten = 1.0;
		shadow_dir_uv = dir_px / lit_viewport_size; 
	} else {

		vec2 to_light_px = (light_uv - frag_uv) * lit_viewport_size;
		float dist = length(to_light_px);
		if (dist > range) {
			return vec3(0.0);                
		}
		Ldir = normalize(vec3(to_light_px, height));
		atten = pow(clamp(1.0 - dist / range, 0.0, 1.0), falloff);

		if (is_spot) {
			vec4 t4 = texelFetch(lit_light_data, ivec2(4, i), 0); 
			vec2 dir_to_frag = (dist > 0.0001) ? (-to_light_px / dist) : t4.xy;
			float cone = smoothstep(t4.z, t4.w, dot(t4.xy, dir_to_frag));
			atten *= cone;
		}
	}

	if (atten <= 0.0) {
		return vec3(0.0);
	}

	float ndotl = max(dot(N, Ldir), 0.0);

	vec3 diffuse = albedo * light_color * energy * ndotl * atten;

	vec3 specular = vec3(0.0);
	if (specular_strength > 0.0 && dot(spec_shin, spec_shin) > 0.0) {
		specular = light_color * spec_shin * energy * atten * pow(ndotl, 1.0 + shininess * specular_k) * specular_strength;
	}

	vec3 contribution = diffuse + specular;

	if (max(contribution.r, max(contribution.g, contribution.b)) < 0.004) {
		return vec3(0.0);
	}

	if (shadow_enabled) {
		vec4 t3 = texelFetch(lit_light_data, ivec2(3, i), 0); 
		vec2 light_sdf;
		if (is_directional) {

			vec2 dir_sdf = normalize(screen_uv_to_sdf(frag_uv + shadow_dir_uv) - frag_sdf);
			light_sdf = frag_sdf + dir_sdf * sdf_diag * directional_shadow_reach;
		} else {

			light_sdf = screen_uv_to_sdf(light_uv);
		}

		int steps = shadow_steps;
		if (lit_shadow_step_scaling) {
			float march_len = length(light_sdf - frag_sdf);
			float frac = clamp(march_len / max(sdf_diag, 0.0001), 0.0, 1.0);
			steps = int(ceil(frac * float(lit_shadow_steps_max)));
			steps = clamp(steps, 16, lit_shadow_steps_max);
		}

		float s = lit_shadow(frag_sdf, light_sdf, t3.w, steps);
		contribution *= mix(t3.rgb, vec3(1.0), s);
	}

	return subtractive ? -contribution : contribution;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	vec3 albedo = tex.rgb * COLOR.rgb;
	vec3 N = normalize(NORMAL);                  
	vec3 spec_shin = SPECULAR_SHININESS.rgb;
	float shininess = SPECULAR_SHININESS.a;

	vec3 lit = albedo * lit_ambient_color.rgb * lit_ambient_energy;

	vec2 frag_uv = SCREEN_UV;                     
	vec2 frag_sdf = screen_uv_to_sdf(SCREEN_UV);  

	float sdf_diag = length(screen_uv_to_sdf(vec2(1.0)) - screen_uv_to_sdf(vec2(0.0)));

	bool tiling_valid = lit_tile_grid.x > 0 && lit_tile_grid.y > 0 && lit_tile_size > 0;

	if (tiling_valid) {

		for (int i = 0; i < lit_directional_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, frag_uv, frag_sdf, sdf_diag);
		}

		ivec2 tile = ivec2(SCREEN_UV * lit_viewport_size) / lit_tile_size;
		tile = clamp(tile, ivec2(0), lit_tile_grid - ivec2(1));
		vec4 header = texelFetch(lit_tile_headers, tile, 0); 
		int offset = int(round(header.x));
		int count = int(round(header.y));
		for (int j = 0; j < count; j++) {
			int flat_idx = offset + j;
			ivec2 icoord = ivec2(flat_idx % LIT_INDEX_TEX_WIDTH, flat_idx / LIT_INDEX_TEX_WIDTH);
			int li = int(round(texelFetch(lit_tile_indices, icoord, 0).x));
			lit += lit_shade(li, albedo, N, spec_shin, shininess, frag_uv, frag_sdf, sdf_diag);
		}
	} else {

		for (int i = 0; i < lit_light_count; i++) {
			lit += lit_shade(i, albedo, N, spec_shin, shininess, frag_uv, frag_sdf, sdf_diag);
		}
	}

	vec3 emissive = albedo * emissive_strength * texture(emissive_mask, UV).r;

	COLOR = vec4(lit + emissive, tex.a * COLOR.a);
}
