// Quiet window into the End: a deep violet dust field, a few distant stars, and just enough depth motion
// to keep it from reading as a flat texture. Coordinates stay anchored in the portal's world-space plane.
vec3 endPortalRadiance(vec3 worldPos, vec3 normal, vec3 viewRay) {
    vec3 axis = abs(normal);
    vec2 plane = axis.y >= max(axis.x, axis.z) ? worldPos.xz : (axis.x >= axis.z ? worldPos.zy : worldPos.xy);
    vec2 rayPlane = axis.y >= max(axis.x, axis.z) ? viewRay.xz : (axis.x >= axis.z ? viewRay.zy : viewRay.xy);

    // Project the eye ray a short way into the portal. Clamping incidence avoids huge coordinate jumps at
    // grazing angles while preserving visible parallax when the player moves around the frame.
    float incidence = max(abs(dot(viewRay, normal)), 0.22);
    float time = frameTimeCounter;
    vec2 nearLayer = plane + rayPlane * (2.0 / incidence) + time * vec2(0.012, -0.008);
    vec2 farLayer = plane + rayPlane * (7.0 / incidence) + time * vec2(-0.006, 0.004);

    // One low-frequency dust field supplies the large forms. A single value-noise sample softens its edges,
    // avoiding the four full fractal layers in the previous portal shader.
    float dust = endFbm(farLayer * 0.045 + vec2(time * 0.002, -time * 0.0013));
    float grain = valueNoise(nearLayer * 0.19 + vec2(-time * 0.008, time * 0.005));
    float nebula = smoothstep(0.40, 0.78, dust + (grain - 0.5) * 0.18);
    float filament = smoothstep(0.67, 0.86, grain) * nebula;

    vec3 color = vec3(0.005, 0.002, 0.015);
    color += vec3(0.22, 0.055, 0.39) * nebula * 0.22;
    color += vec3(0.16, 0.10, 0.34) * filament * 0.09;

    // Sparse pinprick stars sit on the farther layer. They are faint, small, and drift with the same parallax.
    vec2 starPos = farLayer * 2.0;
    vec2 starCell = floor(starPos);
    vec2 starOffset = fract(starPos) - 0.5;
    float starSeed = hash12(starCell);
    float star = exp(-dot(starOffset, starOffset) * 72.0) * smoothstep(0.965, 0.992, starSeed);
    float twinkle = 0.84 + 0.16 * sin(time * 0.65 + starSeed * TAU);
    color += vec3(0.20, 0.17, 0.34) * star * twinkle * 0.45;

    return color * 3.0;
}
