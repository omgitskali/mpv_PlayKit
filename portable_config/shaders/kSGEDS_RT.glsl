// 文档 https://github.com/hooke007/MPV_lazy/wiki/4_GLSL

/*

LICENSE:
  --- RAW ver.
  https://github.com/SnapdragonStudios/snapdragon-gsr/blob/main/LICENSE

*/


//!PARAM SHARP
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
0.5

//!PARAM ET
//!TYPE float
//!MINIMUM 32.0
//!MAXIMUM 255.0
64.0


//!HOOK SCALED
//!BIND HOOKED
//!DESC [kSGEDS_RT]
//!WHEN SHARP

vec4 hook() {

	vec2 pos = HOOKED_pos;
	vec2 pt = HOOKED_pt;
	vec4 color = HOOKED_tex(pos);
	vec4 posl;
	posl.x = HOOKED_texOff(vec2(1.0, 1.0)).g;
	posl.y = HOOKED_texOff(vec2(1.0, 0.0)).g;
	posl.z = HOOKED_texOff(vec2(0.0, 0.0)).g;
	posl.w = HOOKED_texOff(vec2(0.0, 1.0)).g;
	float edgeVote = abs(posl.z - posl.y) + abs(color.g - posl.y) + abs(color.g - posl.z);

	if (edgeVote > (ET / 255.0)) {
		vec4 pix_l = HOOKED_tex(pos + vec2(-pt.x, 0));
		vec4 pix_r = HOOKED_tex(pos + vec2(pt.x, 0));
		vec4 pix_u = HOOKED_tex(pos + vec2(0, -pt.y));
		vec4 pix_d = HOOKED_tex(pos + vec2(0, pt.y));
		float laplacian_g = 4.0 * color.g - (pix_l.g + pix_r.g + pix_u.g + pix_d.g);
		float deltaY = SHARP * laplacian_g;
		deltaY = clamp(deltaY, -23.0 / 255.0, 23.0 / 255.0);
		color.rgb += vec3(deltaY);
		color.rgb = clamp(color.rgb, 0.0, 1.0);
	}

	color.a = 1.0;
	return color;

}

