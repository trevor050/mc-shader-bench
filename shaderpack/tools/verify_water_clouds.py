"""GPU diagnostics for the exact water cloud-reflection and cloud-depth GLSL helpers.

This uses the shaderpack's baked cloud noise in a standalone OpenGL context. It
checks high-layer-only fallback reflection and the translucent cloud front-depth
gate. It does not emulate Iris temporal history or replace an in-game capture.
"""
from pathlib import Path
import json
import re

import moderngl
import numpy as np

# Resolve from this tracked tools/ file so the command works from any working directory.
ROOT = Path(__file__).resolve().parents[2]
SHADERS = ROOT / "shaderpack" / "shaders"
OUT = ROOT / "work" / "water-clouds-results.json"
INC = re.compile(r'^\s*#include\s+"([^"]+)"', re.M)


def expand(path):
    return INC.sub(lambda m: expand(SHADERS / m.group(1).lstrip("/")), path.read_text())


def function_body(source, name):
    match = re.search(rf"\b{re.escape(name)}\s*\([^;]*?\)\s*\{{", source, re.S)
    if not match:
        raise ValueError(f"missing GLSL function {name}")
    start = match.end()
    depth = 1
    i = start
    while depth:
        depth += (source[i] == "{") - (source[i] == "}")
        i += 1
    return source[match.start():i]


VERTEX = """#version 430 core
out vec2 vUv;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""


def reflection_shader():
    settings = expand(SHADERS / "lib" / "settings.glsl")
    settings = re.sub(r"#define SKY_PRESET [^\n]*", "#define SKY_PRESET 0", settings)
    core = """#version 430 core
#define FRAGMENT
#define CLOUDS
#define patch patchValue
uniform float rainStrength;
uniform float frameTimeCounter;
uniform vec3 cameraPosition;
uniform float raySlope;
"""
    core += settings + expand(SHADERS / "lib" / "common.glsl")
    core += expand(SHADERS / "lib" / "atmosphere.glsl")
    core += expand(SHADERS / "lib" / "lighting.glsl")
    cloud_source = expand(SHADERS / "lib" / "clouds.glsl")
    water_source = (SHADERS / "lib" / "water.glsl").read_text()
    core += cloud_source
    core += "float " + function_body(water_source, "reflectedCloudDensityAt") + "\n"
    core += "vec3 " + function_body(water_source, "reflectedClouds") + "\n"
    return core + r"""
in vec2 vUv;
layout(location=0) out vec4 result;
layout(location=1) out vec4 layers;
layout(location=2) out vec4 sampleHeights;
layout(location=3) out vec4 cirrusData;
void main() {
    CloudWeather w = cloudWeather();
    vec3 ro = vec3((vUv.x - 0.5) * 30000.0, 80.0, (vUv.y - 0.5) * 30000.0);
    vec3 rd = normalize(vec3(0.0, raySlope, 1.0));
    vec3 sunDir = normalize(vec3(0.2, 0.5, 0.3));
    float cirrusDaylight = smoothstep(-0.1, 0.05, sunDir.y);
    float limit = cloudRayLimit(rd, 1e6);
    float l0 = 0.0;
    for (int i = 0; i < 5; ++i) {
        float y = i == 0 ? 163.0 : (i == 1 ? 240.0 : (i == 2 ? 390.0 : (i == 3 ? 700.0 : 1020.0)));
        float fade, distance;
        l0 = max(l0, reflectedCloudDensityAt(ro, rd, y, limit, w, 0, cirrusDaylight, fade, distance));
    }
    DeckStyle altoStyleValue = altoStyle(w);
    DeckStyle veilStyleValue = veilStyle(w);
    DeckStyle fractusStyleValue = fractusStyle(w);
    float alto = 0.0, veil = 0.0, altoY = 0.0, veilY = 0.0;
    for (int i = 0; i < 2; ++i) {
        float f = (float(i) + 1.0) / 3.0;
        float fade, distance;
        float y = altoStyleValue.alt + altoStyleValue.thick * f;
        float d = reflectedCloudDensityAt(ro, rd, y, limit, w, 1, cirrusDaylight, fade, distance);
        if (d > alto) { alto = d; altoY = y; }
        y = veilStyleValue.alt + veilStyleValue.thick * f;
        d = reflectedCloudDensityAt(ro, rd, y, limit, w, 4, cirrusDaylight, fade, distance);
        if (d > veil) { veil = d; veilY = y; }
    }
    float fractus = 0.0, virga = 0.0, cirrus = 0.0;
    float fractusY = 0.0, virgaY = 0.0, cirrusY = 0.0;
    for (int i = 0; i < 2; ++i) {
        float f = (float(i) + 1.0) / 3.0;
        float fade, distance;
        float y = fractusStyleValue.alt + fractusStyleValue.thick * f;
        float d = reflectedCloudDensityAt(ro, rd, y, limit, w, 2, cirrusDaylight, fade, distance);
        if (d > fractus) { fractus = d; fractusY = y; }
        y = L1_ALT - VIRGA_DEPTH + VIRGA_DEPTH * f;
        d = reflectedCloudDensityAt(ro, rd, y, limit, w, 3, cirrusDaylight, fade, distance);
        if (d > virga) { virga = d; virgaY = y; }
        y = L2_ALT - 0.5 * L2_THICK + L2_THICK * f;
        d = reflectedCloudDensityAt(ro, rd, y, limit, w, 5, cirrusDaylight, fade, distance);
        if (d > cirrus) { cirrus = d; cirrusY = y; }
    }
    vec3 sky = vec3(0.12, 0.21, 0.33);
    vec3 reflected = reflectedClouds(sky, rd, ro, sunDir, vec3(1.1,0.7,0.4),
                                      vec3(0.9,0.65,0.4), sunDir, vec3(0.15,0.18,0.22));
    result = vec4(reflected - sky, l0);
    layers = vec4(alto, veil, fractus, virga);
    sampleHeights = vec4(altoY, veilY, fractusY, virgaY);
    cirrusData = vec4(cirrus, cirrusY, 0.0, 0.0);
}
"""


def depth_shader():
    source = (SHADERS / "program" / "gbuffers_translucent.glsl").read_text()
    helper = "vec3 " + function_body(source, "applyCloudsInFront")
    return r"""#version 430 core
#define CLOUDS
#define MAT_ENTITY 20
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform int isEyeInWater;
uniform int mat;
""" + helper + r"""
in vec2 vUv;
layout(location=0) out vec4 fragColor;
void main() {
    fragColor = vec4(applyCloudsInFront(vec3(0.4,0.5,0.6), vec2(0.5), 10.0), 1.0);
}
"""


def cloud_texture(ctx):
    noise = np.fromfile(SHADERS / "textures" / "cloudnoise.dat", dtype="<u2").astype(np.float32) / 65535.0
    tex = ctx.texture3d((65, 65, 65), 4, noise.tobytes(), dtype="f4")
    tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
    tex.repeat_x = tex.repeat_y = tex.repeat_z = False
    return tex


def run_scan(ctx, program, tex, rain, day=80, time=18000, size=(256, 256), ray_slope=250.0):
    vao = ctx.vertex_array(program, [])
    targets = [ctx.texture(size, 4, dtype="f4") for _ in range(4)]
    fbo = ctx.framebuffer(targets)
    fbo.use()
    ctx.viewport = (0, 0, *size)
    tex.use(0)
    for name, value in {"cloudNoise": 0, "rainStrength": rain, "frameTimeCounter": 60.0,
                        "raySlope": ray_slope,
                        "worldDay": day, "worldTime": time}.items():
        if name in program:
            program[name].value = value
    vao.render(moderngl.TRIANGLES, vertices=3)
    arrays = [np.frombuffer(fbo.read(attachment=i, components=4, dtype="f4"), dtype="f4")
              .reshape(size[1], size[0], 4).copy() for i in range(4)]
    for resource in [fbo, *targets, vao]:
        resource.release()
    return arrays


def reflection_checks(ctx, tex):
    program = ctx.program(vertex_shader=VERTEX, fragment_shader=reflection_shader())
    cases = {}
    configs = [
        ("alto", 0.0, 80, 18000, 0, 0, [1150.0, 1410.0], [1, 2, 3], 1),
        ("veil", 0.0, 80, 21000, 1, 1, [1850.0, 2230.0], [0, 2, 3], 1),
        ("fractus", 1.0, 80, 18000, 2, 2, [560.0, 760.0], [0, 1, 3], 1),
        ("virga", 0.0, 80, 21000, 3, 3, [690.0, 1150.0], [0, 1, 2], 1),
        ("cirrus", 0.0, 80, 18000, 0, 1, [2510.0, 2690.0], [0, 1, 2, 3], 3),
    ]
    for label, rain, day, time, layer_idx, height_idx, height_range, other_indices, data_idx in configs:
        arrays = run_scan(ctx, program, tex, rain, day, time)
        target_field = arrays[data_idx][..., 0] if label == "cirrus" else arrays[1][..., layer_idx]
        candidate = target_field > 0.01
        candidate &= arrays[0][..., 3] < 1e-6
        for other_idx in other_indices:
            candidate &= arrays[1][..., other_idx] < 1e-6
        if label != "cirrus":
            candidate &= arrays[3][..., 0] < 1e-6
        else:
            candidate &= arrays[1][..., 0] < 1e-6
        candidate &= np.linalg.norm(arrays[0][..., :3], axis=-1) > 1e-5
        if not candidate.any():
            cases[label] = {"passed": False, "reason": "no high-layer-only candidate found in scan",
                            "max_layer_density": float(target_field.max()),
                            "min_l0": float(arrays[0][..., 3].min())}
            continue
        y, x = np.argwhere(candidate)[0]
        sample_y = arrays[3][y, x, 1] if label == "cirrus" else arrays[2][y, x, height_idx]
        cases[label] = {
            "passed": True,
            "rain": rain,
            "world_day": day,
            "world_time": time,
            "pixel": [int(x), int(y)],
            "l0_density": float(arrays[0][y, x, 3]),
            "target_density": float(target_field[y, x]),
            "selected_sample_y": float(sample_y),
            "expected_layer_range": height_range,
            "reflection_delta_rgb": [float(v) for v in arrays[0][y, x, :3]],
            "reflection_delta_length": float(np.linalg.norm(arrays[0][y, x, :3])),
        }
        lo, hi = height_range
        cases[label]["sample_in_layer"] = lo <= cases[label]["selected_sample_y"] <= hi
        cases[label]["passed"] &= cases[label]["sample_in_layer"]
    horizon = run_scan(ctx, program, tex, 0.0, 80, 18000, ray_slope=0.12)
    clear = horizon[0][..., 3] < 1e-6
    clear &= np.max(horizon[1], axis=-1) < 1e-6
    clear &= horizon[3][..., 0] < 1e-6
    haze_delta = np.linalg.norm(horizon[0][..., :3], axis=-1)
    haze_candidate = clear & (haze_delta > 1e-5)
    cases["horizon_haze_without_resolved_cloud"] = {
        "passed": bool(haze_candidate.any()),
        "max_delta_length_when_resolved_layers_clear": float(haze_delta[clear].max()) if clear.any() else 0.0,
        "clear_pixel_count": int(clear.sum()),
        "ray_y": float(0.12 / np.sqrt(1.0 + 0.12 * 0.12)),
    }
    for resource in [program]:
        resource.release()
    return cases


def depth_checks(ctx):
    program = ctx.program(vertex_shader=VERTEX, fragment_shader=depth_shader())
    vao = ctx.vertex_array(program, [])
    size = (1, 1)
    target = ctx.texture(size, 4, dtype="f4")
    fbo = ctx.framebuffer([target])
    fbo.use()
    ctx.viewport = (0, 0, 1, 1)
    c8 = ctx.texture(size, 4, np.array([5.0, 10.0, 0.0, 0.0], dtype="f4").tobytes(), dtype="f4")
    c9 = ctx.texture(size, 4, np.array([0.1, 0.1, 0.1, 0.5], dtype="f4").tobytes(), dtype="f4")
    c8.filter = c9.filter = (moderngl.NEAREST, moderngl.NEAREST)
    c8.use(0); c9.use(1)
    program["colortex8"].value = 0
    program["colortex9"].value = 1
    program["isEyeInWater"].value = 0
    program["mat"].value = 0
    vao.render(moderngl.TRIANGLES, vertices=3)
    front = np.frombuffer(fbo.read(components=4, dtype="f4"), dtype="f4")[:3]
    c8.write(np.array([15.0, 10.0, 0.0, 0.0], dtype="f4").tobytes())
    vao.render(moderngl.TRIANGLES, vertices=3)
    behind = np.frombuffer(fbo.read(components=4, dtype="f4"), dtype="f4")[:3]
    c8.write(np.array([5.0, 10.0, 0.0, 0.0], dtype="f4").tobytes())
    program["mat"].value = 20
    vao.render(moderngl.TRIANGLES, vertices=3)
    entity = np.frombuffer(fbo.read(components=4, dtype="f4"), dtype="f4")[:3]
    for resource in [fbo, target, c8, c9, vao, program]:
        resource.release()
    return {
        "cloud_in_front": [float(v) for v in front],
        "cloud_behind": [float(v) for v in behind],
        "entity_cloud_bypass": [float(v) for v in entity],
        "expected_front": [0.3, 0.35, 0.4],
        "expected_behind": [0.4, 0.5, 0.6],
        "expected_entity": [0.4, 0.5, 0.6],
        "passed": bool(np.allclose(front, [0.3, 0.35, 0.4], atol=1e-5)
                       and np.allclose(behind, [0.4, 0.5, 0.6], atol=1e-5)
                       and np.allclose(entity, [0.4, 0.5, 0.6], atol=1e-5)),
    }


def timing_checks(ctx, tex, size=(256, 256), repeats=6):
    """Measure the full water fallback helper, including its optional horizon haze, on the GPU."""
    program = ctx.program(vertex_shader=VERTEX, fragment_shader=reflection_shader())
    vao = ctx.vertex_array(program, [])
    targets = [ctx.texture(size, 4, dtype="f4") for _ in range(4)]
    fbo = ctx.framebuffer(targets)
    fbo.use()
    ctx.viewport = (0, 0, *size)
    tex.use(0)
    for name, value in {"cloudNoise": 0, "rainStrength": 0.0, "frameTimeCounter": 60.0,
                        "worldDay": 80, "worldTime": 18000}.items():
        if name in program:
            program[name].value = value
    results = {}
    for label, slope in (("upward", 250.0), ("horizon", 0.12)):
        program["raySlope"].value = slope
        for _ in range(2):
            vao.render(moderngl.TRIANGLES, vertices=3)
        elapsed_ns = []
        for _ in range(repeats):
            with ctx.query(time=True) as query:
                vao.render(moderngl.TRIANGLES, vertices=3)
            elapsed_ns.append(query.elapsed)
        results[label] = {
            "ray_y": float(slope / np.sqrt(1.0 + slope * slope)),
            "resolution": list(size),
            "iterations": repeats,
            "gpu_ms_per_frame_median": float(np.median(elapsed_ns) / 1e6),
            "gpu_ms_per_megapixel_median": float(np.median(elapsed_ns) / 1e6 / (size[0] * size[1] / 1e6)),
        }
    for resource in [fbo, *targets, vao, program]:
        resource.release()
    return results


def main():
    ctx = moderngl.create_standalone_context(require=430)
    report = {"renderer": ctx.info.get("GL_RENDERER"), "GL_VERSION": ctx.info.get("GL_VERSION"),
              "limitations": "Standalone exact GLSL and baked texture, synthetic ray/camera. No Iris temporal history or game screenshot match."}
    try:
        tex = cloud_texture(ctx)
        report["high_layer_only"] = reflection_checks(ctx, tex)
        report["cloud_depth_gate"] = depth_checks(ctx)
        report["gpu_timing"] = timing_checks(ctx, tex)
        tex.release()
    finally:
        ctx.release()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not all(case.get("passed", False) for case in report["high_layer_only"].values()):
        raise SystemExit(1)
    if not report["cloud_depth_gate"]["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
