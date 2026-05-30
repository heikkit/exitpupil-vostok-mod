shader_type spatial;
render_mode unshaded;

uniform sampler2D viewport : source_color, filter_linear;	// the scope's sub-viewport texture
uniform bool active = true;
uniform float blur_radius = 0.0;	// set by Likho's WeaponRig; 0.0 = no blur (zoom 1 or no Likho)
// Declaring blur_radius is also what signals Likho's Optic.gd to leave this shader alone —
// it checks for this property before deciding whether to swap in its own PIP_NVG.gdshader.
uniform float exit_pupil = 7.0;	// mm, driven per-scope per-zoom by pbobs.gd
uniform float ambient_lum = 0.5;	// smoothed sun/moon energy from pbobs.gd (0 = dark, 1 = noon)
// Using a pre-smoothed GDScript value rather than sampling the main viewport avoids per-frame
// texture reads, which caused flickering on high-contrast edges (e.g. treetops against sky).
uniform float intensity = 1.0;		// overall effect scale, configured via MCM (0 = off, 1 = full)

const float PUPIL_MAX = 7.0;		// maximum useful exit pupil — fully dark-adapted human eye (mm)
const float base_brightness = 0.73;	// optical transmission baseline — not all light passes through glass
const float gamma = 0.78;		// subtle gamma lift applied to the sub-viewport render
const float dim_start = 0.15;		// \
const float dim_end = 0.55;		//  } outdoor brightness compensation curve (see 'dim' below)
const float dim_strength = 0.40;	// /

void fragment() {
	// 3x3 box-blur kernel — applied when Likho's WeaponRig sets blur_radius > 0 at higher zoom
	// levels. At zoom 1 (or without Likho) blur_radius stays 0.0 and we sample the centre only.
	vec3 c;
	if (blur_radius > 0.0) {
		vec2 texel = blur_radius / vec2(textureSize(viewport, 0));
		c = vec3(0.0);
		c += texture(viewport, UV + vec2(-texel.x, -texel.y)).rgb;
		c += texture(viewport, UV + vec2( 0.0,    -texel.y)).rgb;
		c += texture(viewport, UV + vec2( texel.x, -texel.y)).rgb;
		c += texture(viewport, UV + vec2(-texel.x,  0.0   )).rgb;
		c += texture(viewport, UV).rgb;
		c += texture(viewport, UV + vec2( texel.x,  0.0   )).rgb;
		c += texture(viewport, UV + vec2(-texel.x,  texel.y)).rgb;
		c += texture(viewport, UV + vec2( 0.0,     texel.y)).rgb;
		c += texture(viewport, UV + vec2( texel.x,  texel.y)).rgb;
		c /= 9.0;
	} else {
		c = texture(viewport, UV).rgb;
	}

	// Outdoor brightness compensation.
	// The scope sub-viewport renders at a fixed internal exposure regardless of scene brightness.
	// 'dim' pulls the image back as the scene gets brighter so the scope doesn't appear
	// blown out against the surroundings in daylight.
	float dim = 1.0 - (dim_strength * intensity) * smoothstep(dim_start, dim_end, ambient_lum);

	// Exit pupil efficiency: how much light the scope delivers relative to a fully open pupil.
	// Physics: exit_pupil = objective_diameter / magnification.
	// Efficiency = (exit_pupil / PUPIL_MAX)^2, clamped to 1.0 — quadratic because both
	// dimensions of the pupil area scale with diameter.
	// Only penalises in genuine darkness: bright light fills the pupil regardless of exit pupil
	// diameter, so scope_factor approaches 1.0 in daylight.
	float ep_ratio = exit_pupil / PUPIL_MAX;
	float scope_efficiency = min(1.0, ep_ratio * ep_ratio);
	float darkness = intensity * (1.0 - smoothstep(0.0, 0.4, ambient_lum));
	float scope_factor = mix(1.0, scope_efficiency, darkness);

	c *= base_brightness * dim * scope_factor;
	c = pow(max(c, vec3(0.0)), vec3(gamma));

	ALBEDO = active ? clamp(c, 0.0, 1.0) : vec3(0.0);
}
