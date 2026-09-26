#!/usr/bin/env python3
"""Check cloud fog, march coverage, horizon/depth boundaries, and climate GLSL.

Run from any directory: py /path/to/repo/shaderpack/tools/verify_clouds.py
Requires numpy, moderngl and glcontext; uses a small standalone OpenGL 4.3 context.
Writes work/cloud-verification.json by default. No Minecraft controls or timing
claims. --cpu-only checks the parsed deck stride bound without an OpenGL context.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import sys

import numpy as np

import check_compile as compile_check

ROOT = Path(__file__).resolve().parents[2]
SHADERS = compile_check.SHADERS
VERTEX = """#version 430 core
out vec2 vUv;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""
NEUTRAL = {"skyClimate": (0., 0., 0., 0.), "skyAerosol": 1.,
           "skyConvection": .5, "skyVividEvent": 0.}
HUMID = {"skyClimate": (0., 0., .85, 0.), "skyAerosol": 1.34,
         "skyConvection": 1., "skyVividEvent": 1.}
PROGRAMS = {}


def function(source: str, name: str) -> str:
    """Preserve a complete production GLSL function, including its return type."""
    match = re.search(rf"\b(?:float|vec[234])\s+{re.escape(name)}\s*\([^;{{}}]*\)\s*\{{", source)
    if not match:
        raise ValueError(f"missing GLSL function {name}")
    depth = 1
    end = match.end()
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


def number(source: str, pattern: str) -> float:
    match = re.search(pattern, source)
    if not match:
        raise ValueError(f"deck control changed; review the coverage probe: {pattern}")
    return float(match[1])


def step_bound(clouds: str, profile: int | None = None) -> dict:
    """Replay production stride constants in float32, assuming no early opacity exit."""
    deck = function(clouds, "marchDeck")
    span = number(deck, r"t0\s*\+\s*([\d.]+)\s*,\s*rayLimit")
    nominal_count = number(deck, r"const int N\s*=\s*(\d+)")
    bound = int(number(deck, r"for \(int i = 0; i < (\d+); i\+\+\)"))
    match = re.search(r"min\(min\(nominalStep,\s*([\d.]+)\s*\+\s*segmentStart\s*\*\s*([\d.]+)\),\s*t1\s*-\s*segmentStart\)", deck)
    if not match:
        raise ValueError("deck stride expression changed; review the coverage probe")
    base, growth = map(float, match.groups())
    starts, spans = np.meshgrid(np.array([0., .1, 1., 60., 400., 1200., 6000.], dtype="f4"),
                               np.linspace(1., span, 1200, dtype="f4"))
    end = starts + spans
    position = starts.copy()
    scale = 1.0
    if profile is not None:
        quality = (SHADERS / "lib/performance_quality.glsl").read_text()
        control = "#if PERFORMANCE_PROFILE >= 4" if profile == 4 else f"#elif PERFORMANCE_PROFILE == {profile}" if profile else "#else"
        block = re.search(re.escape(control) + r"\s*\n(.*?)(?=\n#(?:elif|else|endif))", quality, re.S)[1]
        scale = float(re.search(r"#define CLOUD_MARCH_SCALE ([\d.]+)", block)[1])
    nominal = (end - starts) / np.float32(nominal_count) * np.float32(scale)
    counts = np.zeros(starts.shape, dtype="i4")
    for _ in range(bound):
        active = position < end
        counts += active
        stride = np.minimum(np.minimum(nominal, np.float32(base) + position * np.float32(growth)), end - position)
        position += np.where(active, stride, 0.)
    missing = end - position
    if np.any(missing > 0.):
        raise AssertionError(f"deck march truncates {float(missing.max()):.6f} blocks at loop bound {bound}")
    return {"intervals": int(starts.size), "loop_bound": bound, "max_steps": int(counts.max()),
            "max_span": span, "nominal_steps": nominal_count, "nominal_stride_scale": scale,
            "close_stride": base, "growth": growth, "active_in_selected_profile": profile != 0}


def core_shader(profile: int | None = None) -> str:
    settings = compile_check.expand(SHADERS / "lib/settings.glsl", [])
    # The designed presets have separate authored masks; probe the ordinary weather path.
    settings = re.sub(r"#define SKY_PRESET [^\n]*", "#define SKY_PRESET 0", settings)
    if profile is not None:
        settings = re.sub(r"#define PERFORMANCE_PROFILE [^\n]*", f"#define PERFORMANCE_PROFILE {profile}", settings)
    core = "#version 430 core\n#define FRAGMENT\n#define patch patchValue\n"
    core += "uniform float rainStrength;\nuniform float frameTimeCounter;\n" + settings
    for name in ["common", "atmosphere", "lighting", "clouds"]:
        core += compile_check.expand(SHADERS / f"lib/{name}.glsl", [])
    return core


def uniforms(program, values: dict) -> None:
    for key, value in values.items():
        if key in program:
            program[key].value = value


def draw(ctx, source: str, size: tuple[int, int], outputs: int, values: dict, textures=()) -> list:
    import moderngl
    if source not in PROGRAMS:
        PROGRAMS[source] = ctx.program(vertex_shader=VERTEX, fragment_shader=source)
    program = PROGRAMS[source]
    vao = ctx.vertex_array(program, [])
    targets = [ctx.texture(size, 4, dtype="f4") for _ in range(outputs)]
    fbo = ctx.framebuffer(targets)
    try:
        fbo.use()
        ctx.viewport = (0, 0, *size)
        uniforms(program, values)
        for slot, texture in enumerate(textures):
            texture.use(slot)
        vao.render(moderngl.TRIANGLES, vertices=3)
        return [np.frombuffer(fbo.read(attachment=i, components=4, dtype="f4"), dtype="f4")
                .reshape(size[1], size[0], 4).copy() for i in range(outputs)]
    finally:
        for resource in [fbo, *targets, vao]:
            resource.release()


def fog_checks(ctx, composite: str) -> dict:
    """Run the actual GLSL formula against independently fogging the background."""
    rng = np.random.default_rng(26)
    bg, cloud, fog = [rng.random((100, 100, 3), dtype="f4") for _ in range(3)]
    amount = rng.random((100, 100, 1), dtype="f4")
    source = "#version 430 core\nuniform sampler2D backgroundTex, cloudTex, fogTex;\n"
    source += function(composite, "fogBehindClouds") + """
layout(location=0) out vec4 result;
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec3 bg = texelFetch(backgroundTex, pixel, 0).rgb;
    vec4 cloud = texelFetch(cloudTex, pixel, 0), fog = texelFetch(fogTex, pixel, 0);
    result = vec4(fogBehindClouds(bg * cloud.a + cloud.rgb, fog.rgb, fog.a, cloud), 1.0);
}
"""
    max_error = 0.
    for trans in [rng.random((100, 100, 1), dtype="f4"), np.zeros_like(amount), np.ones_like(amount)]:
        textures = [ctx.texture((100, 100), 3, bg.tobytes(), dtype="f4"),
                    ctx.texture((100, 100), 4, np.concatenate([cloud, trans], axis=2).tobytes(), dtype="f4"),
                    ctx.texture((100, 100), 4, np.concatenate([fog, amount], axis=2).tobytes(), dtype="f4")]
        try:
            actual = draw(ctx, source, (100, 100), 1, {"backgroundTex": 0, "cloudTex": 1, "fogTex": 2}, textures)[0][..., :3]
            expected = (bg * (1. - amount) + fog * amount) * trans + cloud
            np.testing.assert_allclose(actual, expected, atol=5e-7, rtol=5e-7)
            max_error = max(max_error, float(np.abs(actual - expected).max()))
        finally:
            for texture in textures:
                texture.release()
    return {"cases": 30000, "max_absolute_error": max_error, "includes_zero_and_unit_transmittance": True}


def foreground_checks(ctx, composite: str) -> dict:
    source = "#version 430 core\n#define CLOUDS\nuniform sampler2D colortex3, colortex9;\nuniform bool uEntity;\n"
    source += function(composite, "cloudForegroundAt") + """
layout(location=0) out vec4 result;
void main() { result = cloudForegroundAt(vec2(0.5), 10.0, uEntity); }
"""
    cloud = np.array([.4, .2, .1, .25], dtype="f4")
    identity = [0., 0., 0., 1.]
    cases = [("foreground", 5., False, cloud), ("behind_surface", 20., False, identity),
             ("surface_epsilon", 9.75, False, identity), ("entity", 5., True, identity)]
    for label, cloud_distance, entity, expected in cases:
        # Test the real RGBA16F distance representation that survives colortex8 reuse.
        depths = np.tile([cloud_distance / 65536., 10. / 65536., 0., 0.], (2, 2, 1)).astype("f2")
        textures = [ctx.texture((2, 2), 4, depths.tobytes(), dtype="f2"),
                    ctx.texture((2, 2), 4, np.tile(cloud, (2, 2, 1)).tobytes(), dtype="f4")]
        try:
            actual = draw(ctx, source, (1, 1), 1, {"colortex3": 0, "colortex9": 1, "uEntity": entity}, textures)[0][0, 0]
            np.testing.assert_allclose(actual, expected, atol=1e-6, err_msg=label)
        finally:
            for texture in textures:
                texture.release()
    return {"cases": [case[0] for case in cases], "distance_texture": "RGBA16F, distance/65536"}


def horizon_checks(ctx, core: str, noise) -> dict:
    source = core + """
uniform vec3 uCamera, uSun;
uniform float uRayY;
layout(location=0) out vec4 horizon;
layout(location=1) out vec4 detailFade;
void main() {
    gCloudCamera = uCamera;
    vec3 rd = normalize(vec3(0.0, uRayY, -1.0)), sun = normalize(uSun);
    CloudLightEnv e = makeCloudLightEnv(sun);
    float maxDist = float(int(gl_FragCoord.x)) * cloudRenderDistance() / 64.0;
    float dist;
    horizon = cloudHorizonHaze(uCamera, rd, maxDist, cloudWeather(), e.directLight, e.directLight1,
                 e.directLight2, e.skyLight, e.cirrusDaylight, smoothstep(-0.1,-0.3,sun.y), dist);
    detailFade = cloudResolvedFade(vec4(0.4,0.2,0.1,0.0), maxDist, rd);
}
"""
    summaries = []
    common = {"cloudNoise": 0, "worldDay": 0, "worldTime": 6000, "frameTimeCounter": 5.,
              "rainStrength": 0., "thunderStrength": 0.}
    for climate_name, climate in [("neutral", NEUTRAL), ("humid", HUMID)]:
        for phase, sun in [("day", (.6, .8, .1)), ("dusk", (.99, -.075, .05)), ("night", (.3, -.95, .1))]:
            for y in [240., 1280., 2040.]:
                for slope in [0., .00009, -.00011, -.4, .4]:
                    haze, fade = draw(ctx, source, (257, 1), 2,
                                      common | climate | {"uCamera": (982., y, -1434.), "uSun": sun, "uRayY": slope}, [noise])
                    check_medium(haze)
                    check_medium(fade)
                    # Horizontal distances are known independently of the shader's fade implementation.
                    horizontal = np.arange(257) / 64. / np.sqrt(1. + slope * slope)
                    for actual, expected in [(haze[0, horizontal <= .65], [0.,0.,0.,1.]),
                                             (fade[0, horizontal <= .65], [.4,.2,.1,0.]),
                                             (fade[0, horizontal >= 1.], [0.,0.,0.,1.])]:
                        np.testing.assert_allclose(actual, np.broadcast_to(expected, actual.shape), atol=1e-6)
                    if np.any(np.diff(fade[0, :, 3]) < -1e-6):
                        raise AssertionError("resolved opacity fade is not monotonic")
                    summaries.append({"climate": climate_name, "phase": phase, "camera_y": y, "ray_y": slope,
                                      "transmittance_min": float(haze[..., 3].min()),
                                      "rgb_max": [float(v) for v in haze[..., :3].max(axis=(0, 1))]})
    return {"rays": len(summaries), "distances_per_ray": 257, "samples": summaries}


def check_medium(values) -> None:
    if not np.isfinite(values).all() or values[..., :3].min() < -1e-7:
        raise AssertionError("nonfinite or negative cloud radiance")
    if values[..., 3].min() < -1e-7 or values[..., 3].max() > 1.0000001:
        raise AssertionError("cloud transmittance outside [0,1]")


def boundary_checks(ctx, core: str, noise) -> dict:
    source = core + """
uniform vec3 uCamera;
uniform float uRayY;
layout(location=0) out vec4 nearFog;
layout(location=1) out vec4 interval;
void main() {
    vec3 rd = normalize(vec3(0.0,uRayY,-1.0));
    float distances[6] = float[6](0.0,0.25,2.0,10.0,60.0,120.0);
    float distance = distances[int(gl_FragCoord.x)];
    CloudLightEnv e = makeCloudLightEnv(normalize(vec3(0.3,-0.95,0.1)));
    nearFog = cloudNearFog(uCamera,rd,distance,e,cloudNearLightTransmittance(uCamera,e),0.5);
    interval = vec4(cloudNearInterval(uCamera,rd,distance),cloudNearRange(uCamera),CLOUD_NEAR_DIST);
}
"""
    count = 0
    # Exact edges, deck interiors, and clear gaps, including high cirrus.
    heights = [80., 132., 650., 1080., 1115., 1150., 1280., 1410., 1600., 1850., 2040., 2230., 2400., 2510., 2600., 2690.]
    for height in heights:
        for slope in [0., 1e-6, -1e-6, .0001, -.0001, .8, -.8]:
            fog, intervals = draw(ctx, source, (6, 1), 2, NEUTRAL | {
                "cloudNoise": 0, "worldDay": 0, "worldTime": 18000, "frameTimeCounter": 5.,
                "rainStrength": 0., "thunderStrength": 0., "uCamera": (3246.375, height, 3239.625),
                "uRayY": slope}, [noise])
            check_medium(fog)
            if not np.isfinite(intervals).all():
                raise AssertionError("nonfinite near slab interval")
            np.testing.assert_allclose(fog[0, 0], [0., 0., 0., 1.], atol=1e-7)
            distances = np.array([0., .25, 2., 10., 60., 120.])
            valid = intervals[0, :, 1] > intervals[0, :, 0]
            if np.any(intervals[0, valid, 0] < 0.) or np.any(intervals[0, valid, 1] > distances[valid] + 1e-5):
                raise AssertionError("near fog interval extends beyond the scene surface")
            np.testing.assert_allclose(fog[0, ~valid], np.tile([0., 0., 0., 1.], ((~valid).sum(), 1)), atol=1e-7)
            # A surface past the shared near range must not add further near extinction.
            np.testing.assert_allclose(fog[0, 4], fog[0, 5], atol=1e-6)
            count += 6
    return {"samples": count, "heights": heights, "slopes": [0., 1e-6, -1e-6, .0001, -.0001, .8, -.8]}


def weather_checks(ctx, core: str) -> dict:
    source = core + """
layout(location=0) out vec4 low;
layout(location=1) out vec4 high;
layout(location=2) out vec4 decks;
void main() {
    CloudWeather w=cloudWeather();
    low=vec4(w.cov0,w.tower,w.cov1,w.cirrus);
    high=vec4(w.low,w.lowCov,w.cb,1.0);
    decks=vec4(veilAmount(w),fractusAmount(w),0.0,1.0);
}
"""
    cases = {}
    deck_balance = {}
    profiles = {"temperate": (0.,0.,0.,0.), "cold": (1.,0.,0.,0.), "arid": (0.,1.,0.,0.),
                "humid": (0.,0.,1.,0.), "maritime": (0.,0.,0.,1.)}
    for name, climate in profiles.items():
        low, high, decks = draw(ctx, source, (1, 1), 3, NEUTRAL | {
            "skyClimate": climate, "worldDay": 0, "worldTime": 6000,
            "rainStrength": 0., "thunderStrength": 0.})
        cases[name] = np.r_[low[0,0], high[0,0,:3]]
        deck_balance[name] = [float(v) for v in decks[0,0,:2]]
    for name, convection, rain, thunder in [("humid_morning",0.,0.,0.), ("humid_afternoon",1.,0.,0.), ("thunder",1.,1.,1.)]:
        low, high, decks = draw(ctx, source, (1, 1), 3, NEUTRAL | {
            "skyClimate": profiles["humid"], "skyConvection": convection,
            "worldDay": 0, "worldTime": 6000, "rainStrength": rain, "thunderStrength": thunder})
        cases[name] = np.r_[low[0,0], high[0,0,:3]]
        deck_balance[name] = [float(v) for v in decks[0,0,:2]]
    for name, values in cases.items():
        if not np.isfinite(values).all() or values.min() < 0. or values.max() > 1.:
            raise AssertionError(f"unbounded CloudWeather: {name}: {values}")
    if "skyClimate" in core:
        if not np.all(cases["arid"][[0,4]] < cases["temperate"][[0,4]]) or cases["arid"][6] > cases["temperate"][6]:
            raise AssertionError(f"arid coverage/low deck/storm strength did not decrease: {cases['arid']} vs {cases['temperate']}")
        if cases["humid_afternoon"][1] <= cases["humid_morning"][1]:
            raise AssertionError("humid convection did not increase tower height")
        if not np.all(cases["maritime"][[2,4]] > cases["temperate"][[2,4]]):
            raise AssertionError("maritime alto/low deck did not increase")
    if cases["thunder"][6] < 1.:
        raise AssertionError("full thunder failed to retain its storm strength")
    disabled = re.sub(r"#define SKY_CLIMATE [^\n]*", "#define SKY_CLIMATE 0.0", source)
    neutral_controls = 0
    for day, time in [(0,6000), (80,18000), (365,12000)]:
        for convection in [0.,1.]:
            values = NEUTRAL | {"worldDay": day, "worldTime": time, "skyConvection": convection,
                                "rainStrength": 0., "thunderStrength": 0.}
            enabled = draw(ctx, source, (1,1), 3, values)
            control = draw(ctx, disabled, (1,1), 3, values)
            for actual, expected in zip(enabled, control):
                np.testing.assert_allclose(actual, expected, atol=1e-7, rtol=1e-7)
            neutral_controls += 1
    return {"fields": ["cov0","tower","cov1","cirrus","low","lowCov","cb"],
            "cases": {name: [float(v) for v in values] for name, values in cases.items()},
            "deck_balance_veil_fractus": deck_balance,
            "neutral_equals_climate_disabled_cases": neutral_controls,
            "convection_note": "Morning/afternoon hold weather time fixed and vary the supplied convection uniform."}


def sky_seam_checks(ctx, core: str, deferred: str) -> dict:
    """Compare the actual shared haze and visible sky at their eye-level boundary."""
    assignment = re.search(r"\bcol\s*=\s*rd\.y\s*<\s*0\.0\s*\?.*?;", deferred, re.S)
    if not assignment:
        raise ValueError("deferred sky branch changed; review the continuity probe")
    source = core + """
uniform vec3 uSun;
layout(location=0) out vec4 sky;
layout(location=1) out vec4 haze;
void main() {
    float azimuth = float(int(gl_FragCoord.x)) / 256.0 * TAU;
    vec3 rd = normalize(vec3(cos(azimuth),0.0,sin(azimuth))), sunDir = normalize(uSun);
    vec3 col;
""" + assignment[0] + """
    sky = vec4(col,1.0);
    haze = vec4(hazeColor(rd,sunDir)+sunDisc(rd,sunDir),1.0);
}
"""
    result = []
    for profile, climate in [("neutral",NEUTRAL),("humid",HUMID)]:
        for phase, sun in [("day",(.6,.8,.1)),("dusk",(.99,-.075,.05)),("night",(.3,-.95,.1))]:
            for rain in [0.,1.]:
                sky, haze = draw(ctx, source, (257,1), 2, climate | {
                    "uSun": sun, "rainStrength": rain, "thunderStrength": rain})
                check_medium(sky)
                check_medium(haze)
                relative = np.abs(sky[...,:3] - haze[...,:3]) / np.maximum(sky[...,:3],1e-7)
                if relative.max() > 5e-5:
                    raise AssertionError(f"eye-level sky/haze radiance discontinuity: {profile}/{phase}/rain{rain}, {relative.max():.6%}")
                result.append({"climate": profile, "phase": phase, "rain": rain,
                               "max_relative_rgb_jump": float(relative.max())})
    return {"azimuths_per_case": 257, "cases": result}


def link_checks(profile: int | None = None) -> dict:
    """Use the existing Iris include/prelude expansion on the actual pass pairs."""
    result = {}
    with tempfile.TemporaryDirectory(prefix="cloud-link-") as folder:
        for name in ["deferred", "composite2"]:
            paths = []
            for suffix, stage in [("vsh", "vert"), ("fsh", "frag")]:
                expanded = compile_check.expand(SHADERS / f"{name}.{suffix}", [])
                if profile is not None:
                    expanded = re.sub(r"#define PERFORMANCE_PROFILE [^\n]*", f"#define PERFORMANCE_PROFILE {profile}", expanded)
                first, rest = expanded.split("\n", 1)
                path = Path(folder) / f"{name}.{stage}"
                path.write_text(first + "\n" + compile_check.PRELUDE + rest, encoding="utf-8")
                paths.append(str(path))
            linked = subprocess.run([compile_check.GLSLANG, "-l", *paths], capture_output=True, text=True)
            if linked.returncode:
                raise AssertionError(f"{name} link failed:\n{linked.stdout}\n{linked.stderr}")
            result[name] = "passed"
    return result


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpu-only", action="store_true", help="skip all actual-GLSL checks; only verify the parsed march bound")
    parser.add_argument("--report", type=Path, default=Path("work/cloud-verification.json"))
    default_profile = re.search(r"#define PERFORMANCE_PROFILE (\d+)", (SHADERS / "lib/settings.glsl").read_text())[1]
    parser.add_argument("--profile", choices=("0", "1", "2", "3", "4", "all"), default=default_profile,
                        help="Potato 0 through Ultra 4, or all sequentially")
    args = parser.parse_args(argv)
    if args.profile == "all":
        original_args = sys.argv[1:] if argv is None else argv
        for profile in range(5):
            report_path = args.report.with_name(f"{args.report.stem}-profile-{profile}{args.report.suffix}")
            main(original_args + ["--profile", str(profile), "--report", str(report_path)])
        return
    args.profile = int(args.profile)
    output = args.report if args.report.is_absolute() else ROOT / args.report
    output.parent.mkdir(parents=True, exist_ok=True)
    # A failed/interrupted run must not leave an older successful receipt at this path.
    output.write_text(json.dumps({"status": "running", "mode": "cpu-only" if args.cpu_only else "cpu-and-glsl"}) + "\n", encoding="utf-8")
    clouds = (SHADERS / "lib/clouds.glsl").read_text()
    composite = (SHADERS / "program/composite.glsl").read_text()
    deferred = (SHADERS / "program/deferred.glsl").read_text()
    core = core_shader(profile=args.profile)
    report = {"mode": "cpu-only" if args.cpu_only else "cpu-and-glsl",
              "performance_profile": args.profile,
              "performance_profile_name": ("Potato", "Low", "Medium", "High", "Ultra")[args.profile],
              "quality_header_sha256": hashlib.sha256((SHADERS / "lib/performance_quality.glsl").read_bytes()).hexdigest(),
              "extracted_helper_scope": {
                  "fog_algebra_and_foreground_depth": "Profile-independent full helper algebra; active callers are profiles 1-4. Potato caller bypasses these, so this does not validate Potato composition.",
                  "selected_profile_core": "Weather, sky/haze, cloud boundaries and link checks compile the explicit selected profile."},
              "source_sha256": hashlib.sha256((core + composite + deferred).encode()).hexdigest(),
              "noise_sha256": hashlib.sha256((SHADERS / "textures/cloudnoise.dat").read_bytes()).hexdigest(),
              "climate_uniforms": {"neutral": NEUTRAL, "humid": HUMID},
              "limitations": "Small exact-GLSL numerical probes. No Iris temporal/deferred frame, game controls, visual certification, or performance measurement.",
              "deck_coverage": step_bound(clouds, profile=args.profile)}
    if not args.cpu_only:
        report["pass_links"] = link_checks(profile=args.profile)
        import moderngl
        ctx = moderngl.create_standalone_context(require=430)
        noise = None
        try:
            report["renderer"] = ctx.info["GL_RENDERER"]
            data = np.fromfile(SHADERS / "textures/cloudnoise.dat", dtype="<u2").astype("f4") / 65535.
            noise = ctx.texture3d((65,65,65), 4, data.tobytes(), dtype="f4")
            noise.filter = (moderngl.LINEAR, moderngl.LINEAR)
            noise.repeat_x = noise.repeat_y = noise.repeat_z = False
            report["fog_algebra"] = fog_checks(ctx, composite)
            report["foreground_depth"] = foreground_checks(ctx, composite)
            report["horizon"] = horizon_checks(ctx, core, noise)
            report["near_boundaries"] = boundary_checks(ctx, core, noise)
            report["weather"] = weather_checks(ctx, core)
            report["sky_haze_continuity"] = sky_seam_checks(ctx, core, deferred)
        finally:
            for program in PROGRAMS.values():
                program.release()
            PROGRAMS.clear()
            if noise is not None:
                noise.release()
            ctx.release()
    report["status"] = "passed"
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"cloud checks passed ({report['mode']}): {output}")
    print(f"deck intervals {report['deck_coverage']['intervals']}, max steps {report['deck_coverage']['max_steps']}")
    if not args.cpu_only:
        print(f"actual GLSL: fog 30000, foreground 4, horizon {report['horizon']['rays'] * 257}, near boundaries {report['near_boundaries']['samples']}, weather 8 + 6 neutral controls, sky continuity 3084")


if __name__ == "__main__":
    main()
