// Repaired native sRGB fog shared by standalone composite and fused Potato final.
// Standard Iris common uniforms are supplied through CustomUniforms' fixed-input path.
#ifndef POTATO_FOG_GLSL
#define POTATO_FOG_GLSL
vec3 potatoSnowWhiteout(vec3 haze) {
    float l = luminance(haze);
    return mix(haze, vec3(l) * vec3(0.96, 1.0, 1.07) * 1.45, 0.75);
}
float potatoSnowHorizonShare() { return 0.55 + 0.45 * rainStrength; }
vec3 fogPotatoScene(vec3 col, vec2 uv, vec3 sunDir) {
    float depth = texture(depthtex0, uv).r;
    float dhDepth = depth >= 1.0 ? texture(dhDepthTex0, uv).r : 1.0;
    if (depth >= 0.56 && (depth < 1.0 || dhDepth < 1.0)) {
        vec3 viewPos = projectAndDivide(depth < 1.0 ? gbufferProjectionInverse : dhProjectionInverse,
                                       vec3(uv, depth < 1.0 ? depth : dhDepth) * 2.0 - 1.0);
        vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz;
        float dist = length(playerPos);
        // Iris 26.2 exposes environmental fog here; clear weather may use infinite bounds.
        // Do not pass infinities to smoothstep, and preserve valid immersion/environmental fog.
        float amount = 0.0;
        if (fogStart < 1e6 && fogEnd < 1e6 && fogEnd > fogStart)
            amount = smoothstep(fogStart, fogEnd, dist);
        vec3 haze = fogColor;
#if !defined DIM_NETHER && !defined DIM_END
        if (isEyeInWater == 0) {
            // DH supplies its configured radius in blocks; its projection plane is not coverage.
            float radius = dhFarPlane > 0.0 ? max(float(dhRenderDistance), far) : far;
            float edge = smoothstep(radius * 0.75, max(radius * 0.97, 1.0), length(playerPos.xz));
            float open = depth >= 1.0 ? 1.0 : smoothstep(24.0, 144.0, float(eyeBrightnessSmooth.y));
            float worldY = playerPos.y + cameraPosition.y;
            float heightFalloff = exp(-max(worldY - 62.0, 0.0) / 90.0);
            float density = (0.00018 + rainLocal * 0.004) * FOG_DENSITY * mix(0.6, 1.0, heightFalloff);
            // Restore cheap continuous snow air, whose omission exposed flat distant LOD faces.
            density += inSnowy * (0.0019 + 0.028 * rainStrength);
            amount = max(amount, max(edge, (1.0 - exp(-dist * density)) * open));
            vec3 skyHaze = max(hazeColor(normalize(playerPos), sunDir), vec3(0.0));
            skyHaze = mix(skyHaze, potatoSnowWhiteout(skyHaze), inSnowy * potatoSnowHorizonShare());
            haze = pow(skyHaze / (vec3(1.0) + skyHaze), vec3(1.0 / 2.2));
        }
#endif
        col = mix(col, haze, amount);
    }
    return col;
}
#endif
