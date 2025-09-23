// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- PAPER ver.
  https://nlpr.ia.ac.cn/2012papers/gjkw/gk46.pdf

*/


//!PARAM T
//!TYPE float
//!MINIMUM 1.0
//!MAXIMUM 2.0
1.15

//!PARAM K
//!TYPE float
//!MINIMUM 1.0
//!MAXIMUM 10.0
5.0


//!HOOK MAIN
//!BIND HOOKED
//!SAVE DCCI_PRE
//!DESC [DCCI_RT] pre
//!WIDTH HOOKED.w 2 *
//!HEIGHT HOOKED.h 2 *
//!WHEN OUTPUT.w HOOKED.w 1.200 * > OUTPUT.h HOOKED.h 1.200 * > *

float cubic_kernel(float s) {
	s = abs(s);
	if (s < 1.0) {
		return (1.5 * s - 2.5) * s * s + 1.0;
	} else if (s < 2.0) {
		return ((-0.5 * s + 2.5) * s - 4.0) * s + 2.0;
	} else {
		return 0.0;
	}
}

vec3 cci1d(ivec2 pos_px, vec2 dir, float dist) {
	vec3 sum = vec3(0.0);
	for (int i = -1; i <= 2; i++) {
		ivec2 sample_pos = pos_px + ivec2(round(float(i) * dir));
		vec3 pixel_val_rgb = linearize(texelFetch(HOOKED_raw, sample_pos, 0)).rgb;
		sum += pixel_val_rgb * cubic_kernel(float(i) - dist);
	}
	return sum;
}

vec4 hook() {

	vec2 hr_pos_float = HOOKED_pos * HOOKED_size * 2.0 - 0.5;
	ivec2 hr_coord = ivec2(round(hr_pos_float));

	bvec2 is_odd = bvec2(mod(hr_coord, 2));
	if (is_odd.x && is_odd.y) {
		ivec2 lr_coord = (hr_coord - 1) / 2;
		return vec4(texelFetch(HOOKED_raw, lr_coord, 0).rgb, 1.0);
	}
	if (!is_odd.x && !is_odd.y) {
		ivec2 lr_center = hr_coord / 2;

		float G1 = 0.0;
		float G2 = 0.0;
		for (int m = -3; m <= 3; m += 2) {
			for (int n = -3; n <= 3; n += 2) {
				ivec2 p1 = lr_center + ivec2(m, -n);
				ivec2 p2 = lr_center + ivec2(m - 1, -n + 1);
				if (p1.x >= 0 && p1.y >= 0 && p2.x >= 0 && p2.y >= 0) {
					vec4 v1 = texelFetch(HOOKED_raw, p1, 0);
					vec4 v2 = texelFetch(HOOKED_raw, p2, 0);
					if (v1.a > 0.0 && v2.a > 0.0) {
						G1 += abs(linearize(v1).r - linearize(v2).r);
					}
				}
				ivec2 p3 = lr_center + ivec2(m, n);
				ivec2 p4 = lr_center + ivec2(m - 1, n - 1);
				if (p3.x >= 0 && p3.y >= 0 && p4.x >= 0 && p4.y >= 0) {
					vec4 v3 = texelFetch(HOOKED_raw, p3, 0);
					vec4 v4 = texelFetch(HOOKED_raw, p4, 0);
					if (v3.a > 0.0 && v4.a > 0.0) {
						G2 += abs(linearize(v3).r - linearize(v4).r);
					}
				}
			}
		}

		ivec2 lr_top_left = lr_center - 1;
		vec3 p1_linear = cci1d(lr_top_left, vec2(1.0, 1.0), 0.5);
		vec3 p2_linear = cci1d(lr_top_left + ivec2(1, 0), vec2(-1.0, 1.0), 0.5);
		vec3 final_color_linear;
		if ((1.0 + G1) / (1.0 + G2) > T) {
			final_color_linear = p2_linear;
		} else if ((1.0 + G2) / (1.0 + G1) > T) {
			final_color_linear = p1_linear;
		} else {
			float w1 = pow(1.0 / (1.0 + G1), K);
			float w2 = pow(1.0 / (1.0 + G2), K);
			final_color_linear = (w2 * p1_linear + w1 * p2_linear) / (w1 + w2);
		}

		return delinearize(vec4(final_color_linear, 1.0));
	}
	return vec4(vec3(0.0), 1.0);

}

//!HOOK MAIN
//!BIND DCCI_PRE
//!BIND HOOKED
//!DESC [DCCI_RT] fin
//!WIDTH HOOKED.w 2 *
//!HEIGHT HOOKED.h 2 *
//!WHEN OUTPUT.w HOOKED.w 1.200 * > OUTPUT.h HOOKED.h 1.200 * > *

vec3 get_mixed_grid_pixel(ivec2 coord) {
	bvec2 is_odd = bvec2(mod(coord, 2));
	if (is_odd.x && is_odd.y) {
		return linearize(texelFetch(HOOKED_raw, (coord - 1) / 2, 0)).rgb;
	} else {
		return linearize(texelFetch(DCCI_PRE_raw, coord, 0)).rgb;
	}
}

vec4 hook() {

	vec2 hr_pos_float = HOOKED_pos * HOOKED_size * 2.0 - 0.5;
	ivec2 hr_coord = ivec2(round(hr_pos_float));

	bvec2 is_odd = bvec2(mod(hr_coord, 2));
	if (is_odd.x == is_odd.y) {
		return vec4(texelFetch(DCCI_PRE_raw, hr_coord, 0).rgb, 1.0);
	}

	float G1 = 0.0;
	float G2 = 0.0;

	for (int m = -1; m <= 1; m += 2) {
		for (int n = 0; n <= 2; n += 2) {
			vec3 p1 = get_mixed_grid_pixel(hr_coord + ivec2(m, -n));
			vec3 p2 = get_mixed_grid_pixel(hr_coord + ivec2(m, -n + 2));
			G1 += abs(p1.r - p2.r);
		}
	}

	for (int m = 0; m <= 2; m += 2) {
		vec3 p1 = get_mixed_grid_pixel(hr_coord + ivec2(m, -1));
		vec3 p2 = get_mixed_grid_pixel(hr_coord + ivec2(m, 1));
		G1 += abs(p1.r - p2.r);
	}

	for (int n = -1; n <= 1; n += 2) {
		for (int m = 0; m <= 2; m += 2) {
			vec3 p1 = get_mixed_grid_pixel(hr_coord + ivec2(-m, n));
			vec3 p2 = get_mixed_grid_pixel(hr_coord + ivec2(-m + 2, n));
			G2 += abs(p1.r - p2.r);
		}
	}

	for (int n = 0; n <= 2; n += 2) {
		vec3 p1 = get_mixed_grid_pixel(hr_coord + ivec2(-1, n));
		vec3 p2 = get_mixed_grid_pixel(hr_coord + ivec2(1, n));
		G2 += abs(p1.r - p2.r);
	}

	const float W0 = -0.0625;
	const float W1 = 0.5625;
	vec3 h_p0 = get_mixed_grid_pixel(hr_coord + ivec2(-3, 0));
	vec3 h_p1 = get_mixed_grid_pixel(hr_coord + ivec2(-1, 0));
	vec3 h_p2 = get_mixed_grid_pixel(hr_coord + ivec2( 1, 0));
	vec3 h_p3 = get_mixed_grid_pixel(hr_coord + ivec2( 3, 0));
	vec3 v_p0 = get_mixed_grid_pixel(hr_coord + ivec2(0, -3));
	vec3 v_p1 = get_mixed_grid_pixel(hr_coord + ivec2(0, -1));
	vec3 v_p2 = get_mixed_grid_pixel(hr_coord + ivec2(0,  1));
	vec3 v_p3 = get_mixed_grid_pixel(hr_coord + ivec2(0,  3));
	vec3 p1_linear = h_p0 * W0 + h_p1 * W1 + h_p2 * W1 + h_p3 * W0;
	vec3 p2_linear = v_p0 * W0 + v_p1 * W1 + v_p2 * W1 + v_p3 * W0;

	vec3 final_color_linear;
	if ((1.0 + G2) / (1.0 + G1) > T) {
		final_color_linear = p1_linear;
	} else if ((1.0 + G1) / (1.0 + G2) > T) {
		final_color_linear = p2_linear;
	} else {
		float w1 = pow(1.0 / (1.0 + G1), K);
		float w2 = pow(1.0 / (1.0 + G2), K);
		final_color_linear = (w1 * p1_linear + w2 * p2_linear) / (w1 + w2);
	}

	return delinearize(vec4(final_color_linear, 1.0));

}

