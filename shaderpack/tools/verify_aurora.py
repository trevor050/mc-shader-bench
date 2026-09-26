#!/usr/bin/env python3
"""Render and measure the shaderpack's aurora GLSL without launching Minecraft.

Requires Python packages moderngl, glcontext, numpy, and Pillow. Uses a standalone
OpenGL context (WGL on Windows), compiles the live aurora implementation and the
live helper functions from common.glsl, then writes linear PFM/NPY data, review
PNGs, and a JSON metrics report under work/aurora by default.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path

import moderngl
import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
NIGHT = ROOT / "shaderpack/shaders/lib/night.glsl"
COMMON = ROOT / "shaderpack/shaders/lib/common.glsl"
SETTINGS = ROOT / "shaderpack/shaders/lib/settings.glsl"
STARS = ROOT / "shaderpack/shaders/lib/stars.glsl"
MILKYWAY = ROOT / "shaderpack/shaders/textures/milkyway.dat"
DEFAULT_OUT = ROOT / "work/aurora"
FUNCTION_RE = re.compile(r"\b(?:float|int|bool|vec[234]|mat[234])\s+(\w+)\s*\([^;{}]*\)\s*\{")


def functions_named(source: str, names: set[str]) -> str:
    """Extract complete GLSL function definitions by name, preserving source text."""
    found: dict[str, str] = {}
    for match in FUNCTION_RE.finditer(source):
        name = match.group(1)
        if name not in names:
            continue
        open_brace = source.find("{", match.start())
        depth = 0
        for i in range(open_brace, len(source)):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    found[name] = source[match.start():i + 1]
                    break
    missing = names - found.keys()
    if missing:
        raise RuntimeError(f"could not find GLSL function(s): {', '.join(sorted(missing))}")
    return "\n\n".join(found.values())


def setting_float(name: str, default: float) -> float:
    match = re.search(rf"^\s*#define\s+{re.escape(name)}\s+([-+0-9.eE]+)", SETTINGS.read_text(), re.M)
    return float(match.group(1)) if match else default


def stars_setting_float(name: str, default: float) -> float:
    match = re.search(rf"^\s*#define\s+{re.escape(name)}\s+([-+0-9.eE]+)", STARS.read_text(encoding="utf-8"), re.M)
    return float(match.group(1)) if match else default


def source_fragments(aurora_mode: int | None = None) -> tuple[str, set[str]]:
    night = NIGHT.read_text(encoding="utf-8")
    common = COMMON.read_text(encoding="utf-8")
    # Keep the aurora section and its helpers while excluding unrelated firefly code.
    aurora_section = night.split("// Fireflies:", 1)[0]
    funcs = set(re.findall(r"\b(?:float|int|bool|vec[234]|mat[234])\s+(\w+)\s*\([^;{}]*\)\s*\{", aurora_section))
    funcs |= {"hash12", "valueNoise", "sqr", "luminance"}
    glsl = functions_named(common, {"hash12", "valueNoise", "sqr", "luminance"}) + "\n\n" + functions_named(aurora_section, funcs - {"hash12", "valueNoise", "sqr", "luminance"})
    # Copy only the live settings macros used by this isolated shader, avoiding local
    # constants from unrelated functions later in night.glsl.
    settings = SETTINGS.read_text(encoding="utf-8")
    declarations = ["#define PI 3.14159265", "#define TAU 6.28318531"]
    for name in ("AURORA", "AURORA_BRIGHTNESS", "AURORA_PREVIEW", "AURORA_MODE"):
        match = re.search(rf"^\s*#define\s+{name}\s+([^\r\n]+)", settings, re.M)
        if match:
            value = str(aurora_mode) if name == "AURORA_MODE" and aurora_mode is not None else match.group(1).strip()
            declarations.append(f"#define {name} {value}")
    if not any(line.startswith("#define AURORA_BRIGHTNESS") for line in declarations):
        declarations.append(f"#define AURORA_BRIGHTNESS {setting_float('AURORA_BRIGHTNESS', 0.09):.9g}")
    uniforms = []
    for name, decl in (("worldDay", "uniform int worldDay;"), ("worldTime", "uniform int worldTime;"),
                       ("cameraPosition", "uniform vec3 cameraPosition;"), ("rainStrength", "uniform float rainStrength;"),
                       ("inSnowy", "uniform float inSnowy;"), ("moonPhase", "uniform int moonPhase;")):
        if re.search(rf"\b{name}\b", glsl + "\n".join(declarations)):
            uniforms.append(decl)
    return "\n".join(declarations + uniforms) + "\n" + glsl, funcs


VERTEX = """#version 430 core
out vec2 vUv;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""


def fragment_shader(core: str, selection: bool = False) -> str:
    body = """
    uniform int uMode;
    uniform int uDay;
    uniform float uTime;
    uniform float uFov;
    uniform float uAspect;
    uniform float uPitch;
    uniform float uSunHeight;
    uniform int uCombined;
    uniform int uBenchmarkBaseline;
    uniform sampler2D milkyway;
    in vec2 vUv;
    out vec4 fragColor;
    void main() {
      if (uMode == 9) {
        float visibility = auroraVisibility(uSunHeight);
        fragColor = vec4(visibility, auroraNightRoll(worldDay), auroraNightActive(worldDay), 1.0);
        return;
      }
      if (uMode == 1) {
        int day = uDay + int(gl_FragCoord.y);
        float roll = auroraNightRoll(day);
        float isActive = auroraNightActive(day);
        fragColor = vec4(roll, isActive, float(day % 2), 1.0);
        return;
      }
      vec2 p = vUv * 2.0 - 1.0;
      vec3 rd;
      if (uMode == 2) {
        float lon = p.x * 3.141592653589793;
        float lat = p.y * 1.570796326794897;
        rd = normalize(vec3(sin(lon) * cos(lat), sin(lat), -cos(lon) * cos(lat)));
      } else {
        float tanHalf = tan(uFov * 0.5);
        float cp = cos(uPitch), sp = sin(uPitch);
        rd = normalize(vec3(p.x * uAspect * tanHalf,
                            p.y * tanHalf * cp + sp,
                            -p.y * tanHalf * sp - cp));
      }
      vec3 c = vec3(0.0);
      if (uBenchmarkBaseline == 0) {
        float auroraAmt = auroraVisibility(uSunHeight);
        if (auroraAmt > 0.001) c = aurora(rd, uTime) * auroraAmt;
      }
      if (uCombined == 1) {
        const vec3 celestialNorth = vec3(0.0, 0.42262, -0.90631);
        vec3 sunDir = normalize(vec3(0.0, -0.9063078, -0.4226183));
        vec3 b1 = normalize(sunDir - dot(sunDir, celestialNorth) * celestialNorth);
        vec3 b2 = cross(celestialNorth, b1);
        float sinDec = clamp(dot(rd, celestialNorth), -1.0, 1.0);
        float dec = asin(sinDec);
        float raSun = fract(float(uDay) / 3650.0 + 0.61) * TAU;
        float ra = mod(raSun + atan(dot(rd, b2), dot(rd, b1)), TAU);
        vec2 uv = vec2(ra / TAU, dec / PI + 0.5);
        vec3 mw = textureLod(milkyway, uv, 0.0).rgb;
        mw = pow(max(mw, vec3(0.0)), vec3(1.15)) * 1.25;
        mw = max(mix(vec3(luminance(mw)), mw, SATURATION), 0.0);
        float darkSky = smoothstep(-0.12, -0.5, sunDir.y);
        darkSky *= darkSky;
        mw *= BRIGHTNESS * darkSky;
        mw *= exp(-0.2 / max(rd.y + 0.03, 0.02)) * smoothstep(-0.02, 0.05, rd.y);
        c += mw;
      }
      fragColor = vec4(c, 1.0);
    }
    """
    body = body.replace("SATURATION", f"{stars_setting_float('MILKYWAY_SATURATION', 1.1):.9g}")
    body = body.replace("BRIGHTNESS", f"{stars_setting_float('MILKYWAY_BRIGHTNESS', 0.5):.9g}")
    return "#version 430 core\n" + core + "\n" + body


def make_context(backend: str | None):
    candidates = [backend] if backend else ["wgl", None]
    errors = []
    for candidate in candidates:
        try:
            ctx = moderngl.create_standalone_context(require=430, **({"backend": candidate} if candidate else {}))
            return ctx
        except Exception as exc:  # continue to the next context backend
            errors.append(f"{candidate or 'default'}: {exc}")
    raise RuntimeError("Unable to create OpenGL 4.3 context. " + " | ".join(errors))


def render(ctx, core: str, width: int, height: int, mode: int, day: int, time_s: float,
           fov_deg: float = 70.0, pitch_deg: float = 0.0, uniforms: dict | None = None,
           combined: bool = False, milky_texture=None) -> np.ndarray:
    program = ctx.program(vertex_shader=VERTEX, fragment_shader=fragment_shader(core))
    vao = ctx.vertex_array(program, [])
    color_target = ctx.texture((width, height), 4, dtype="f4")
    fbo = ctx.framebuffer(color_attachments=[color_target])
    fbo.use()
    ctx.viewport = (0, 0, width, height)
    program["uMode"].value = mode
    program["uDay"].value = day
    program["uTime"].value = time_s
    program["uFov"].value = math.radians(fov_deg)
    program["uAspect"].value = width / height
    program["uPitch"].value = math.radians(pitch_deg)
    program["uSunHeight"].value = -0.9063078
    program["uCombined"].value = int(combined)
    program["uBenchmarkBaseline"].value = 0
    if milky_texture is not None and "milkyway" in program:
        milky_texture.use(location=0)
        program["milkyway"].value = 0
    for name, val in (uniforms or {}).items():
        if name in program:
            program[name].value = val
    vao.render(moderngl.TRIANGLES, vertices=3)
    raw = fbo.read(components=4, dtype="f4", alignment=1)
    out = np.frombuffer(raw, dtype=np.float32).reshape(height, width, 4)[..., :3]
    if mode != 1:
        out = np.flipud(out)
    out = out.copy()
    fbo.release(); color_target.release(); vao.release(); program.release()
    return out


def tone_map(rgb: np.ndarray) -> np.ndarray:
    rgb = np.maximum(np.nan_to_num(rgb), 0.0)
    display = np.power(rgb / (1.0 + rgb), 1.0 / 2.2)
    return np.clip(display * 255.0 + 0.5, 0, 255).astype(np.uint8)


def save_pfm(path: Path, image: np.ndarray) -> None:
    # PFM stores bottom row first and uses a negative scale for little-endian floats.
    with path.open("wb") as f:
        f.write(f"PF\n{image.shape[1]} {image.shape[0]}\n-1.0\n".encode("ascii"))
        f.write(np.flipud(image.astype("<f4")).tobytes())


def summarize(rgb: np.ndarray) -> dict:
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    finite = np.isfinite(rgb).all(axis=-1)
    return {
        "pixels": int(lum.size), "finite_fraction": float(finite.mean()),
        "negative_channel_fraction": float((rgb < -1e-7).any(axis=-1).mean()),
        "nonfinite_channel_count": int((~np.isfinite(rgb)).sum()),
        "channel_min": float(np.nanmin(rgb)), "channel_max": float(np.nanmax(rgb)),
        "luminance_mean": float(np.nanmean(lum)), "luminance_p50_p90_p99_p99_9_max":
            [float(x) for x in np.nanpercentile(lum, [50, 90, 99, 99.9, 100])],
        "fraction_luminance_gt_0_001": float((lum > 0.001).mean()),
        "fraction_luminance_gt_0_01": float((lum > 0.01).mean()),
    }


def milkyway_reference() -> dict:
    # shaders.properties declares RGBA16 ... RGBA UNSIGNED_SHORT (UNORM), 2048x1024.
    tex = np.fromfile(MILKYWAY, dtype="<u2")
    expected = 2048 * 1024 * 4
    if tex.size != expected:
        return {"error": f"expected {expected} uint16 values, found {tex.size}"}
    rgb = tex.reshape(1024, 2048, 4)[..., :3].astype(np.float32) / 65535.0
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    # stars.glsl texture shaping followed by the live saturation and brightness settings.
    processed = np.maximum(rgb, 0.0) ** 1.15 * 1.25
    sat = stars_setting_float("MILKYWAY_SATURATION", 1.1)
    processed = np.maximum((processed @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32))[..., None] * (1.0 - sat) + processed * sat, 0.0)
    brightness = stars_setting_float("MILKYWAY_BRIGHTNESS", 0.5)
    y = processed @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32) * brightness
    return {"encoding": "RGBA16 UNORM", "milkyway_brightness": brightness, "milkyway_saturation": sat,
            "raw_luminance_p50_p90_p99_p99_9_max": [float(x) for x in np.percentile(lum, [50, 90, 99, 99.9, 100])],
            "stars_glsl_processed_luminance_p50_p90_p99_p99_9_max": [float(x) for x in np.percentile(y, [50, 90, 99, 99.9, 100])]}


def gpu_timing(ctx, core: str, width: int, height: int, active_day: int,
               inactive_day: int, frames: int = 8, warmup_frames: int = 3) -> dict:
    """Bounded GPU-only timing, reusing one program, VAO, and target throughout."""
    program = ctx.program(vertex_shader=VERTEX, fragment_shader=fragment_shader(core))
    vao = ctx.vertex_array(program, [])
    color_target = ctx.texture((width, height), 1, dtype="f4")
    framebuffer = ctx.framebuffer(color_attachments=[color_target])
    framebuffer.use()
    ctx.viewport = (0, 0, width, height)
    program["uMode"].value = 3  # perspective camera pitched up 30 degrees
    program["uTime"].value = 20.0
    program["uFov"].value = math.radians(70.0)
    program["uAspect"].value = width / height
    program["uPitch"].value = math.radians(30.0)
    program["uCombined"].value = 0
    program["uBenchmarkBaseline"].value = 0
    for name, value in (("cameraPosition", (0.0, 64.0, 0.0)), ("rainStrength", 0.0),
                        ("inSnowy", 1.0), ("moonPhase", 0)):
        if name in program:
            program[name].value = value
    mode = int(setting_float("AURORA_MODE", 3.0))
    scenarios = {
        "eligible_night": {"worldDay": active_day, "uDay": active_day, "uSunHeight": -0.9063078, "uBenchmarkBaseline": 0},
        "daytime_gate": {"worldDay": active_day, "uDay": active_day, "uSunHeight": 0.5, "uBenchmarkBaseline": 0},
        "event_gate_negative_inputs": {"worldDay": inactive_day, "uDay": inactive_day, "uSunHeight": -0.9063078,
                                       "uBenchmarkBaseline": 0, "inSnowy": 0.0, "moonPhase": 1},
        "no_aurora_baseline": {"worldDay": active_day, "uDay": active_day, "uSunHeight": -0.9063078, "uBenchmarkBaseline": 1},
    }
    result = {"resolution": [width, height], "pixels_per_frame": width * height, "aurora_mode_setting": mode,
              "camera": "north-facing perspective, 30 degree pitch, 70 degree vertical FOV",
              "warmup_frames": warmup_frames, "measured_frames": frames, "gpu_time_unit": "milliseconds",
              "method": "OpenGL timer queries around reused draw calls; no shader compilation, allocation, or framebuffer readback in timed intervals",
              "scenarios": {}}
    try:
        for label, values in scenarios.items():
            for name, value in values.items():
                if name in program:
                    program[name].value = value
            ctx.finish()
            samples_ms = []
            for index in range(warmup_frames + frames):
                query = ctx.query(time=True)
                with query:
                    vao.render(moderngl.TRIANGLES, vertices=3)
                ctx.finish()
                elapsed_ms = float(query.elapsed) / 1.0e6
                if index >= warmup_frames:
                    samples_ms.append(elapsed_ms)
            result["scenarios"][label] = {
                "samples_ms": samples_ms, "median_ms": float(np.median(samples_ms)),
                "p10_ms": float(np.percentile(samples_ms, 10)), "p90_ms": float(np.percentile(samples_ms, 90)),
                "max_ms": float(max(samples_ms)),
            }
    finally:
        framebuffer.release(); color_target.release(); vao.release(); program.release()
    return result


def gate_matrix(ctx, active_day: int, inactive_day: int,
                modes: tuple[int, ...] = (1, 2, 3, 4)) -> dict:
    """Exercise the live visibility GLSL over mode/snow/moon/rain/sun/day inputs."""
    results = {}
    for mode in modes:
        core, _ = source_fragments(aurora_mode=mode)
        program = ctx.program(vertex_shader=VERTEX, fragment_shader=fragment_shader(core))
        vao = ctx.vertex_array(program, [])
        target = ctx.texture((1, 1), 4, dtype="f4")
        framebuffer = ctx.framebuffer(color_attachments=[target])
        framebuffer.use()
        ctx.viewport = (0, 0, 1, 1)
        program["uMode"].value = 9
        program["uDay"].value = active_day
        program["uTime"].value = 0.0
        program["uFov"].value = math.radians(70.0)
        program["uAspect"].value = 1.0
        program["uPitch"].value = 0.0
        program["uCombined"].value = 0
        program["uBenchmarkBaseline"].value = 0
        if "cameraPosition" in program:
            program["cameraPosition"].value = (0.0, 64.0, 0.0)
        cases = []
        passed = True
        for day in (active_day, inactive_day):
            for snowy in (0.0, 1.0):
                for phase in (0, 4):
                    for rain in (0.0, 0.5, 1.0):
                        for sun_height in (-0.9063078, 0.5):
                            values = {"worldDay": day, "inSnowy": snowy, "moonPhase": phase,
                                      "rainStrength": rain, "uSunHeight": sun_height}
                            for name, value in values.items():
                                if name in program:
                                    program[name].value = value
                            vao.render(moderngl.TRIANGLES, vertices=3)
                            actual = np.frombuffer(framebuffer.read(components=4, dtype="f4", alignment=1), dtype=np.float32)
                            if mode == 1:
                                event = snowy
                            elif mode == 2:
                                event = snowy * (1.0 if phase == 0 else 0.0)
                            elif mode == 3:
                                event = 1.0 if day == active_day else 0.0
                            else:
                                event = 1.0
                            dark = 1.0 if sun_height < -0.32 else 0.0
                            expected = event * dark * dark * (1.0 - rain)
                            error = abs(float(actual[0]) - expected)
                            ok = bool(np.isfinite(actual).all() and error < 2.0e-6)
                            passed &= ok
                            cases.append({"day": day, "snowy": snowy, "moon_phase": phase,
                                          "rain_strength": rain, "sun_height": sun_height,
                                          "expected_visibility": expected,
                                          "actual_visibility": float(actual[0]), "pass": ok})
        # Explicitly repeat both GLSL selection functions at one event day to attest stability.
        for name, value in (("worldDay", active_day), ("inSnowy", 1.0), ("moonPhase", 0),
                            ("rainStrength", 0.0), ("uSunHeight", -0.9063078)):
            if name in program:
                program[name].value = value
        repeated = []
        for _ in range(3):
            vao.render(moderngl.TRIANGLES, vertices=3)
            repeated.append(np.frombuffer(framebuffer.read(components=4, dtype="f4", alignment=1), dtype=np.float32)[:3].tolist())
        stable = all(np.array_equal(np.asarray(repeated[0]), np.asarray(sample)) for sample in repeated[1:])
        results[str(mode)] = {"cases": cases, "case_count": len(cases), "all_cases_pass": passed,
                              "repeated_active_day_outputs": repeated, "selection_repeat_stable": stable}
        framebuffer.release(); target.release(); vao.release(); program.release()
    results["all_modes_pass"] = all(v["all_cases_pass"] and v["selection_repeat_stable"]
                                    for key, v in results.items() if key in {"1", "2", "3", "4"})
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--backend", help="ModernGL backend, e.g. wgl (default: try wgl then default)")
    parser.add_argument("--time", type=float, nargs="+", default=[0.0, 2.0, 20.0, 180.0, 3600.0], help="sample times in seconds")
    parser.add_argument("--day", type=int, help="worldDay used for sky renders (default: first active day found)")
    parser.add_argument("--view", choices=("all", "north_horizon", "north_up30", "zenith", "panorama"), default="all",
                        help="limit image capture to one projection; useful for short animation samples")
    parser.add_argument("--timing", action="store_true", help="Run bounded 3440x1369 GPU timing only (skips image capture)")
    parser.add_argument("--timing-width", type=int, default=3440)
    parser.add_argument("--timing-height", type=int, default=1369)
    parser.add_argument("--timing-frames", type=int, default=8, help="measured GPU frames per timing scenario; default 8 plus 3 warmups")
    parser.add_argument("--gate-matrix", action="store_true", help="test all four visibility modes across snow, moon, rain, sun, and day inputs")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    core, funcs = source_fragments()
    ctx = make_context(args.backend)
    selection = None
    if "auroraNightRoll" in funcs and "auroraNightActive" in funcs:
        selection = render(ctx, core, 1, 4096, 1, 0, 0.0)
        prev = render(ctx, core, 1, 1, 1, -1, 0.0)[0, 0, 1] > 0.5
        active = selection[:, 0, 1] > 0.5
        requested_day = args.day
        if args.day is None:
            active_indices = np.flatnonzero(active)
            if not len(active_indices):
                raise RuntimeError("night selector produced no active days in the first 4096-day sample")
            args.day = int(active_indices[0])
        elif not bool(active[args.day % len(active)]):
            print(f"requested day {args.day} is inactive in the 0..4095 sample; rendering its core with visibility gating", file=sys.stderr)
        args._requested_day = requested_day
    elif args.day is None:
        args.day = 0
    # NightSky's Milky Way uses its celestial mapping at a fixed midnight sun.
    mw_tex = None
    if not args.timing and not args.gate_matrix:
        mw_pixels = np.fromfile(MILKYWAY, dtype="<u2").reshape(1024, 2048, 4).astype(np.float32) / 65535.0
        mw_tex = ctx.texture((2048, 1024), 4, mw_pixels.tobytes(), dtype="f4", alignment=1)
        mw_tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
        mw_tex.repeat_x = True
        mw_tex.repeat_y = False
    report = {
        "source": str(NIGHT), "gl_version": ctx.info.get("GL_VERSION"), "renderer": ctx.info.get("GL_RENDERER"),
        "source_sha256": hashlib.sha256(NIGHT.read_bytes()).hexdigest(),
        "aurora_brightness_setting": setting_float("AURORA_BRIGHTNESS", 0.09),
        "milkyway_brightness_setting": stars_setting_float("MILKYWAY_BRIGHTNESS", 0.5),
        "aurora_mode_setting": int(setting_float("AURORA_MODE", 3.0)),
        "included_glsl_functions": sorted(funcs), "milkyway_reference": milkyway_reference(), "renders": {},
        "requested_world_day": getattr(args, "_requested_day", None), "render_world_day": args.day,
        "midnight_sun_direction": [0.0, -0.9063078, -0.4226183],
        "milky_way_preview_approximation": "stars.glsl coordinate mapping, texture shaping, saturation, brightness, dark-sky gate, and extinction; omits noise grain, star catalogue, and the rest of nightSky",
    }
    try:
        if args.timing:
            active_days = np.flatnonzero(active) if selection is not None else np.array([], dtype=np.int32)
            if not len(active_days):
                raise RuntimeError("GPU timing requires auroraNightActive and at least one active day in its sample")
            inactive_days = np.flatnonzero(~active)
            active_day = int(active_days[0])
            inactive_day = int(inactive_days[0])
            report["gpu_timing"] = gpu_timing(ctx, core, args.timing_width, args.timing_height,
                active_day, inactive_day, frames=max(1, args.timing_frames))
            report["gpu_timing"].update({"active_world_day": active_day, "inactive_world_day": inactive_day,
                "synthetic_scene_caveat": "Standalone full-screen shader timing on the RTX GPU; not a live Minecraft frame or FPS measurement. Concurrent game and desktop GPU work can affect these samples."})
        elif args.gate_matrix:
            active_days = np.flatnonzero(selection[:, 0, 1] > 0.5) if selection is not None else np.array([], dtype=np.int32)
            inactive_days = np.flatnonzero(selection[:, 0, 1] <= 0.5) if selection is not None else np.array([], dtype=np.int32)
            if not len(active_days) or not len(inactive_days):
                raise RuntimeError("mode gate matrix requires both active and inactive days in the selector sample")
            report["mode_gate_matrix"] = gate_matrix(ctx, int(active_days[0]), int(inactive_days[0]))
        else:
            views = ((0, "north_horizon", 0.0), (3, "north_up30", 30.0),
                     (4, "zenith", 90.0), (2, "panorama", 0.0))
            if args.view != "all":
                views = tuple(item for item in views if item[1] == args.view)
            for mode, label, pitch in views:
                samples = []
                for t in args.time:
                    uniforms = {"worldDay": args.day, "worldTime": int(t) % 24000,
                                "cameraPosition": (0.0, 64.0, 0.0), "rainStrength": 0.0,
                                "inSnowy": 1.0, "moonPhase": 0}
                    image = render(ctx, core, args.width, args.height, mode, args.day, t, pitch_deg=pitch, uniforms=uniforms)
                    key = f"{label}_aurora_t{t:g}s"
                    Image.fromarray(tone_map(image), "RGB").save(args.output / f"{key}.png")
                    save_pfm(args.output / f"{key}.pfm", image)
                    np.save(args.output / f"{key}.npy", image)
                    summary = summarize(image)
                    report["renders"][key] = summary
                    samples.append((t, image, summary))
                    combined = render(ctx, core, args.width, args.height, mode, args.day, t, pitch_deg=pitch, uniforms=uniforms, combined=True, milky_texture=mw_tex)
                    combined_key = f"{label}_milkyway_plus_aurora_t{t:g}s"
                    Image.fromarray(tone_map(combined), "RGB").save(args.output / f"{combined_key}.png")
                    save_pfm(args.output / f"{combined_key}.pfm", combined)
                    np.save(args.output / f"{combined_key}.npy", combined)
                    report["renders"][combined_key] = summarize(combined)
                    mw_delta = (combined - image) @ np.array([.2126, .7152, .0722])
                    report["renders"][combined_key]["milkyway_contribution_mean"] = float(mw_delta.mean())
                    report["renders"][combined_key]["milkyway_contribution_max"] = float(mw_delta.max())
                for (ta, a, _), (tb, b, _) in zip(samples, samples[1:]):
                    delta = np.abs(a - b)
                    lum_delta = np.abs(a @ np.array([.2126, .7152, .0722]) - b @ np.array([.2126, .7152, .0722]))
                    report["renders"][f"{label}_motion_{ta:g}_to_{tb:g}s"] = {
                        "mean_abs_rgb_delta": float(delta.mean()), "p99_abs_rgb_delta": float(np.percentile(delta, 99)),
                        "max_abs_rgb_delta": float(delta.max()),
                        "mean_abs_luminance_delta": float(lum_delta.mean()), "changed_pixels_gt_1e-4_fraction": float((lum_delta > 1e-4).mean()),
                    }
                if 0.0 in args.time and 3600.0 in args.time:
                    img0 = samples[args.time.index(0.0)][1]
                    imgw = samples[args.time.index(3600.0)][1]
                    report["renders"][f"{label}_wrap_t0_vs_t3600"] = {
                        "mean_abs_rgb_delta": float(np.abs(img0 - imgw).mean()),
                        "max_abs_rgb_delta": float(np.abs(img0 - imgw).max()),
                    }

        if selection is not None:
            # A tall, one-pixel render evaluates the real GLSL selection over consecutive days.
            rolls, active = selection[:, 0, 0], selection[:, 0, 1] > 0.5
            active_with_prev = np.concatenate(([prev], active))
            report["night_selection"] = {
                "days": len(active), "active_nights": int(active.sum()), "frequency": float(active.mean()),
                "consecutive_active_pairs": int(np.logical_and(active_with_prev[:-1], active_with_prev[1:]).sum()),
                "roll_range": [float(rolls.min()), float(rolls.max())], "finite_fraction": float(np.isfinite(selection).all(axis=-1).mean()),
                "negative_roll_count": int((rolls < 0).sum()), "roll_ge_1_count": int((rolls >= 1).sum()),
            }
        else:
            report["night_selection"] = {"status": "not rendered; current source does not define both selection functions"}
        # A coarse direction/time grid catches NaN and negative radiance in the real GLSL call.
        report["validation"] = {
            "all_render_pixels_finite": all(v.get("finite_fraction") == 1.0 for v in report["renders"].values() if "finite_fraction" in v),
            "all_render_channels_nonnegative": all(v.get("negative_channel_fraction") == 0.0 for v in report["renders"].values() if "negative_channel_fraction" in v),
            "selection_functions_present": "auroraNightRoll" in funcs and "auroraNightActive" in funcs,
            "milkyway_contribution_positive": all(v.get("milkyway_contribution_max", 1) > 0.0 for v in report["renders"].values() if "milkyway_contribution_max" in v),
            "mode_gate_matrix_pass": report.get("mode_gate_matrix", {}).get("all_modes_pass", True),
        }
    finally:
        if mw_tex is not None:
            mw_tex.release()
        ctx.release()
    report_name = "timing.json" if args.timing else "metrics.json"
    (args.output / report_name).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"renderer": report["renderer"], "output": str(args.output), "validation": report["validation"],
                      "night_selection": report["night_selection"], "milkyway_reference": report["milkyway_reference"],
                      "gpu_timing": report.get("gpu_timing")}, indent=2))
    return 0 if all(report["validation"][k] for k in ("all_render_pixels_finite", "all_render_channels_nonnegative", "milkyway_contribution_positive", "mode_gate_matrix_pass")) else 2


if __name__ == "__main__":
    sys.exit(main())
