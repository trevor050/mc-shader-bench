"""Render actual before/after bloom kernels in an isolated OpenGL context, without touching Minecraft."""
import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

import moderngl
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "work" / "torch-halo"
W, H = 1024, 512
VERTEX = """#version 430 core
out vec2 texcoord;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    texcoord = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""
PROFILES = {"POTATO": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "ULTRA": 4}


def function(source, name):
    m = re.search(r"\b(?:void|vec[234]|float)\s+" + name + r"\s*\([^)]*\)\s*\{", source)
    if m is None:
        raise ValueError(name)
    depth = 1
    end = m.end()
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[m.start():end]


def baseline(path, ref="3035b5e"):
    return subprocess.check_output(["git", "show", ref + ":" + path], cwd=ROOT, text=True)


def expand_includes(source, shaders):
    return re.sub(r'^\s*#include\s+"([^"]+)"',
                  lambda m: expand_includes((shaders / m.group(1).lstrip("/")).read_text(), shaders),
                  source, flags=re.M)


def cpu_compile(vertex, fragment, directory, name):
    """A syntax/link gate runs before context creation, including compile-only invocations."""
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for stage, source in (("vert", vertex), ("frag", fragment)):
        path = directory / f"{name}.{stage}"
        path.write_text(source)
        paths.append(str(path))
    compiler = os.environ.get("GLSLANG", str(Path.home() / "tools/glslang/bin/glslang.exe"))
    result = subprocess.run([compiler, "-l", *paths], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Fixture {name} failed CPU compilation/linking:\n{result.stdout}{result.stderr}")


def main():
    global W, H, OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", default="1024x512")
    parser.add_argument("--source-size", default="10x24")
    parser.add_argument("--timing-only", action="store_true", help="GPU-only native-size timing, no image readback")
    parser.add_argument("--controls-only", action="store_true", help="Check uniform/black controls at a small or unusual size")
    parser.add_argument("--output", type=Path, default=OUT)
    parser.add_argument("--profile", type=str.upper, choices=PROFILES, default="ULTRA")
    parser.add_argument("--shaderpack", type=Path, default=ROOT / "shaderpack")
    parser.add_argument("--baseline-ref", default="3035b5e")
    parser.add_argument("--baseline-mode", choices=("historical", "current-ultra"), default="historical",
                        help="Separate historical filter validation from current-tier versus current-Ultra comparisons")
    parser.add_argument("--compile-only", action="store_true", help="Compile/link fixtures without creating an OpenGL context")
    parser.add_argument("--no-timing", action="store_true", help="Numerical/image checks only, without issuing GPU timer queries")
    args = parser.parse_args()
    if args.no_timing and args.timing_only:
        parser.error("--no-timing and --timing-only are mutually exclusive")
    W, H = map(int, args.size.split("x"))
    source_w, source_h = map(int, args.source_size.split("x"))
    OUT = args.output
    OUT.mkdir(parents=True, exist_ok=True)
    shaders = args.shaderpack.resolve() / "shaders"
    settings_path = shaders / "lib/settings.glsl"
    quality_path = shaders / "lib/performance_quality.glsl"
    settings = settings_path.read_text()
    settings = re.sub(r"^#define PERFORMANCE_PROFILE\s+.*$", f"#define PERFORMANCE_PROFILE {PROFILES[args.profile]}", settings, flags=re.M)
    defines = expand_includes(settings, shaders)
    common = "float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }\n"
    final = (shaders / "program/final.glsl").read_text()
    tonemap = "vec3 saturate(vec3 c) { return clamp(c, 0.0, 1.0); }\n" + "\n".join(
        function(final, n) for n in ["hejl2015", "linearToSrgb", "filmic", "agxHuePreserving"])
    helper_path = shaders / "lib/bloom_filter.glsl"
    helper = helper_path.read_text()
    current_path = shaders / "program/sun_rays.glsl"
    current = current_path.read_text()
    old = baseline("shaderpack/shaders/program/sun_rays.glsl", args.baseline_ref)
    # Mirror the production hoist in the vertex stage instead of inventing per-fragment meter fixtures.
    bloom_vertex_main = function(current, "main").replace(
        "gl_Position = ftransform();", "vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);")
    bloom_vertex_main = bloom_vertex_main.replace("texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;", "texcoord = p;")
    bloom_vertex = ("#version 430 core\n" + defines + "\n" + common +
                    "out vec2 texcoord; flat out float frameLum; flat out int frameLastMip; uniform sampler2D colortex0;\n" + bloom_vertex_main)
    lod_loop = "    for (int lod = 1; lod <= 9; lod++) {"
    lod_filter = function(current, "bloomAndGlare").split(lod_loop, 1)[1].split("        float scale", 1)[0]
    metadata = {"profile": args.profile, "performance_profile": PROFILES[args.profile], "baseline_mode": args.baseline_mode,
                "shaderpack": str(args.shaderpack.resolve()), "baseline_ref": "CURRENT_ULTRA" if args.baseline_mode == "current-ultra" else args.baseline_ref,
                "historical_reference_ref": args.baseline_ref,
                "source_sha256": hashlib.sha256(current_path.read_bytes()).hexdigest(),
                "baseline_source_sha256": hashlib.sha256((current if args.baseline_mode == "current-ultra" else old).encode()).hexdigest(),
                "historical_reference_source_sha256": hashlib.sha256(old.encode()).hexdigest(),
                "quality_header_sha256": hashlib.sha256(quality_path.read_bytes()).hexdigest(),
                "settings_sha256": hashlib.sha256(settings_path.read_bytes()).hexdigest(),
                "effective_defines_sha256": hashlib.sha256(defines.encode()).hexdigest(),
                "bloom_helper_sha256": hashlib.sha256(helper_path.read_bytes()).hexdigest(),
                "baseline_mip_budget": "Current Ultra, including its actual cubic reconstruction." if args.baseline_mode == "current-ultra" else "Matched to selected current quality tier; historical sampling/filter kernel retained.",
                "meter_fixture": "Actual current vertex frameLum/frameLastMip hoist, sharing the rendered source texture."}
    metadata["gpu_timers_used"] = not args.no_timing and not args.compile_only and PROFILES[args.profile] > 0
    fixtures_sources = {}
    programs = {}
    exact_sampler = """
vec4 exactTextureLod(sampler2D source, vec2 uv, float lod) {
    ivec2 baseSize = textureSize(source,0);
    int level = min(int(lod), int(floor(log2(float(max(baseSize.x,baseSize.y))))));
    ivec2 size = textureSize(source,level);
    vec2 p=uv*vec2(size)-0.5, f=fract(p);
    ivec2 b=ivec2(floor(p));
    return mix(mix(texelFetch(source,clamp(b,ivec2(0),size-1),level),
                   texelFetch(source,clamp(b+ivec2(1,0),ivec2(0),size-1),level),f.x),
               mix(texelFetch(source,clamp(b+ivec2(0,1),ivec2(0),size-1),level),
                   texelFetch(source,clamp(b+ivec2(1,1),ivec2(0),size-1),level),f.x),f.y);
}
#define textureLod exactTextureLod
"""
    for candidate in (False, True, "reference", "exact_candidate", "exact_reference"):
        compare_ultra = candidate is False and args.baseline_mode == "current-ultra"
        src = current if candidate is True or candidate == "exact_candidate" or compare_ultra else old
        variant_defines = re.sub(r"^#define PERFORMANCE_PROFILE\s+.*$", "#define PERFORMANCE_PROFILE 4", defines, flags=re.M) if compare_ultra else defines
        variant_vertex = bloom_vertex.replace(defines, variant_defines, 1)
        use_cubic = bool(candidate) or compare_ultra
        bloom_function = function(src, "bloomAndGlare")
        if src is old:
            bloom_function = bloom_function.replace(lod_loop, lod_loop + lod_filter)
        if candidate in ("reference", "exact_reference"):
            bloom_function = bloom_function.replace(
                "textureLod(colortex0, uv + vec2(x, y) * px * scale * 0.75, float(lod)).rgb",
                "sampleBloomCubic(colortex0, uv + vec2(x, y) * px * scale * 0.75, lod)")
        bloom_fragment = ("#version 430 core\n" + variant_defines + "\n" + common +
            (exact_sampler if str(candidate).startswith("exact_") else "") + (helper if candidate else "") +
            "uniform sampler2D colortex0; uniform float viewWidth, viewHeight; in vec2 texcoord;\n"
            "flat in float frameLum; flat in int frameLastMip;\n"
            "layout(location=0) out vec4 halo; layout(location=1) out vec4 bloom;\n" +
            bloom_function + "\nvoid main() { vec3 b,g,e; bloomAndGlare(texcoord,b,g,e);"
            "halo=vec4(g*GLARE_STRENGTH+e*EMITTER_BLOOM,1.0); bloom=vec4(b,1.0); }")
        # Current Ultra and current selected-tier paths use the same real cubic reconstruction.
        if compare_ultra:
            bloom_fragment = bloom_fragment.replace(common, common + helper, 1)
        reconstruction_fragment = (
            "#version 430 core\n" + variant_defines + "\n" + common + tonemap + (helper if use_cubic else "") +
            "uniform sampler2D scene, halo, bloom; in vec2 texcoord; layout(location=0) out vec4 hdr;"
            "layout(location=1) out vec4 preview; layout(location=2) out vec4 haloOnly;\n"
            "void main(){vec3 s=texture(scene,texcoord).rgb; vec3 h=" +
            ("sampleBloomCubic(halo,texcoord,0)" if use_cubic else "texture(halo,texcoord).rgb") +
            ";vec3 b=" + ("sampleBloomCubic(bloom,texcoord,0)" if use_cubic else "texture(bloom,texcoord).rgb") +
            ";vec3 c=mix(s+h,b,BLOOM_STRENGTH); hdr=vec4(c,1); preview=vec4(agxHuePreserving(c*8.0),1);"
            "haloOnly=vec4(h*(1-BLOOM_STRENGTH)+b*BLOOM_STRENGTH,1);}")
        label = str(candidate).lower()
        cpu_compile(variant_vertex, bloom_fragment, OUT / "fixture-glsl", label + "_bloom")
        cpu_compile(VERTEX, reconstruction_fragment, OUT / "fixture-glsl", label + "_reconstruction")
        fixtures_sources[candidate] = (variant_vertex, bloom_fragment, reconstruction_fragment)
    metadata["cpu_compile_link_checks"] = len(fixtures_sources) * 2
    metadata["postfx_pass_enabled"] = PROFILES[args.profile] > 0
    (OUT / "fixture-receipt.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if args.compile_only or not metadata["postfx_pass_enabled"]:
        print(json.dumps(metadata, indent=2))
        print("PASS: CPU fixture compilation/linking; no OpenGL context created")
        return
    ctx = moderngl.create_standalone_context(require=430)
    for candidate, (variant_vertex, bloom_fragment, reconstruction_fragment) in fixtures_sources.items():
        p = ctx.program(vertex_shader=variant_vertex, fragment_shader=bloom_fragment)
        p["colortex0"].value = 0
        p["viewWidth"].value = W
        p["viewHeight"].value = H
        p2 = ctx.program(vertex_shader=VERTEX, fragment_shader=reconstruction_fragment)
        for slot, n in enumerate(["scene", "halo", "bloom"]):
            p2[n].value = slot
        programs[candidate] = (p, ctx.vertex_array(p, []), p2, ctx.vertex_array(p2, []))

    def draw(vao):
        if args.no_timing:
            vao.render(moderngl.TRIANGLES, vertices=3)
            ctx.finish()
            return None
        with ctx.query(time=True) as query:
            vao.render(moderngl.TRIANGLES, vertices=3)
        ctx.finish()
        return query.elapsed / 1e6

    def render(data, candidate):
        source = ctx.texture((W, H), 3, data=data.astype("f4").tobytes(), dtype="f4")
        source.repeat_x = source.repeat_y = False
        source.build_mipmaps()
        source.filter = (moderngl.LINEAR_MIPMAP_LINEAR, moderngl.LINEAR)
        source.use(location=0)
        half = [ctx.texture((W // 2, H // 2), 4, dtype="f4") for _ in range(2)]
        for t in half:
            t.repeat_x = t.repeat_y = False
            t.filter = (moderngl.LINEAR, moderngl.LINEAR)
        hfbo = ctx.framebuffer(half)
        hfbo.use()
        ctx.viewport = (0, 0, W // 2, H // 2)
        p, vao, p2, vao2 = programs[candidate]
        gpu_ms = draw(vao)
        results = [ctx.texture((W, H), 4, dtype="f4") for _ in range(3)]
        fbo = ctx.framebuffer(results)
        fbo.use()
        ctx.viewport = (0, 0, W, H)
        half[0].use(location=1)
        half[1].use(location=2)
        final_ms = draw(vao2)
        arrays = [np.frombuffer(t.read(), "f4").reshape(H, W, 4)[..., :3].copy() for t in results]
        mip_bloom = np.frombuffer(half[1].read(), "f4").reshape(H // 2, W // 2, 4)[..., :3].copy()
        for obj in [fbo, hfbo, source] + results + half:
            obj.release()
        return arrays, {"bloom": gpu_ms, "final": final_ms}, mip_bloom

    if args.timing_only:
        source = ctx.texture((W,H),4,dtype="f2")
        source.repeat_x=source.repeat_y=False
        source_fbo=ctx.framebuffer([source])
        source_fbo.use()
        ctx.viewport=(0,0,W,H)
        source_program=ctx.program(vertex_shader=VERTEX,fragment_shader="""#version 430 core
in vec2 texcoord; out vec4 fragColor;
void main(){vec2 p=texcoord*vec2(%f,%f)-vec2(%f,%f);
vec2 q=mat2(0.9396926,-0.3420201,0.3420201,0.9396926)*p;
vec3 c=vec3(.001,.0025,.006)+mod(floor(gl_FragCoord.x/8)+floor(gl_FragCoord.y/8),2)*vec3(.0003,.0006,.001);
if(abs(q.x)<%f&&abs(q.y)<%f)c=vec3(1.5,14,11);fragColor=vec4(c,1);}
""" % (W,H,W/2+9,H/2-7,source_w/2,source_h/2))
        source_vao=ctx.vertex_array(source_program,[])
        source_vao.render(moderngl.TRIANGLES,vertices=3)
        source.build_mipmaps()
        source.filter=(moderngl.LINEAR_MIPMAP_LINEAR,moderngl.LINEAR)
        half=[ctx.texture((W//2,H//2),4,dtype="f2") for _ in range(2)]
        for t in half:
            t.repeat_x=t.repeat_y=False
            t.filter=(moderngl.LINEAR,moderngl.LINEAR)
        half_fbo=ctx.framebuffer(half)
        result=ctx.texture((W,H),4,dtype="f1")
        result_fbo=ctx.framebuffer([result])
        final_programs={}
        for candidate in [False,True]:
            use_cubic = bool(candidate) or args.baseline_mode == "current-ultra"
            src=("#version 430 core\n"+defines+"\n"+common+tonemap+(helper if use_cubic else "")+
                 "uniform sampler2D scene,halo,bloom; in vec2 texcoord; out vec4 fragColor;\n"
                 "void main(){vec3 s=texture(scene,texcoord).rgb;vec3 h="+
                 ("sampleBloomCubic(halo,texcoord,0)" if use_cubic else "texture(halo,texcoord).rgb")+
                 ";vec3 b="+("sampleBloomCubic(bloom,texcoord,0)" if use_cubic else "texture(bloom,texcoord).rgb")+
                 ";fragColor=vec4(agxHuePreserving(mix(s+h,b,BLOOM_STRENGTH)*8.0),1);}")
            p=ctx.program(vertex_shader=VERTEX,fragment_shader=src)
            for slot,n in enumerate(["scene","halo","bloom"]):p[n].value=slot
            final_programs[candidate]=(p,ctx.vertex_array(p,[]))
        def timed(candidate):
            source.use(location=0)
            half_fbo.use();ctx.viewport=(0,0,W//2,H//2)
            with ctx.query(time=True) as q:programs[candidate][1].render(moderngl.TRIANGLES,vertices=3)
            ctx.finish();bloom_ms=q.elapsed/1e6
            result_fbo.use();ctx.viewport=(0,0,W,H)
            half[0].use(location=1);half[1].use(location=2)
            with ctx.query(time=True) as q:final_programs[candidate][1].render(moderngl.TRIANGLES,vertices=3)
            ctx.finish()
            return {"bloom":bloom_ms,"final":q.elapsed/1e6}
        for _ in range(3):
            for candidate in [False,True]:timed(candidate)
        samples={"before":[],"after":[]}
        for _ in range(8):
            for candidate in [False,True]:samples["after" if candidate else "before"].append(timed(candidate))
        metrics={**metadata,"renderer":ctx.info["GL_RENDERER"],"resolution":[W,H],"source_size":[source_w,source_h],
                 "timing_scope":"GPU-only synthetic bloom and halo/tonemap reconstruction, RGBA16F HDR targets; no gameplay FPS claim",
                 "gpu_ms_samples":samples,
                 "median_gpu_ms":{k:{stage:float(np.median([x[stage] for x in vals])) for stage in ["bloom","final"]} for k,vals in samples.items()}}
        (OUT/"metrics.json").write_text(json.dumps(metrics,indent=2)+"\n")
        print(json.dumps(metrics,indent=2))
        return

    yy, xx = np.mgrid[:H, :W]
    center = (W // 2 + 9, H // 2 - 7)
    dx, dy = xx - center[0], yy - center[1]
    angle = np.deg2rad(-20)
    tx, ty = dx * np.cos(angle) - dy * np.sin(angle), dx * np.sin(angle) + dy * np.cos(angle)
    core = (abs(tx) < source_w/2) & (abs(ty) < source_h/2)
    checker = ((xx // 8 + yy // 8) & 1)[..., None] * np.array([0.0003, 0.0006, 0.001])
    scene = np.broadcast_to(np.array([0.001, 0.0025, 0.006]), (H, W, 3)).copy() + checker
    background = scene.copy()
    scene[core] = [1.5, 14.0, 11.0]
    distance_from_core = np.hypot(np.maximum(abs(tx)-source_w/2,0),np.maximum(abs(ty)-source_h/2,0))
    halo_mask = (distance_from_core > 24) & (distance_from_core < 180)
    metrics = {**metadata,"renderer": ctx.info["GL_RENDERER"], "gl_version": ctx.info["GL_VERSION"], "resolution": [W,H], "source_size": [source_w,source_h], "timing_scope": "numerical correctness only; no GPU timer queries" if args.no_timing else "synthetic isolated bloom + halo-reconstruction/tonemap passes, includes GPU scheduling contention; not gameplay FPS", "fixtures": {}}
    bg_outputs = {candidate: render(background, candidate)[0] for candidate in (False, True)}
    fixtures=[("uniform",np.full((H,W,3),0.02)),("black",np.zeros((H,W,3)))]
    if not args.controls_only:fixtures.insert(0,("torch",scene))
    for name, data in fixtures:
        outputs = {}
        for candidate in (False,True):
            arrays, ms, mip_bloom = render(data,candidate)
            outputs[candidate] = arrays
            if name == "torch":
                np.save(OUT / ("after.npy" if candidate else "before.npy"), arrays[2])
                img = Image.fromarray(np.uint8(np.clip(np.flipud(arrays[1]),0,1)*255))
                img.save(OUT / ("after.png" if candidate else "before.png"))
        a,b = outputs[False],outputs[True]
        values = {"finite": bool(np.isfinite(b[0]).all()), "min_after_hdr": float(b[0].min()),
                  "max_abs_hdr_change": float(abs(b[0]-a[0]).max())}
        if name == "torch":
            weights=np.array([.2126,.7152,.0722])
            lums=[(outputs[c][2] - bg_outputs[c][2]) @ weights for c in [False,True]]
            curvature=[]
            for lum in lums:
                dxx=np.diff(lum,2,axis=1)[1:-1,:]
                dyy=np.diff(lum,2,axis=0)[:,1:-1]
                curvature.append(float(np.quantile((abs(dxx)+abs(dyy))[halo_mask[1:-1,1:-1]],.99)))
            scene_coefficient = 1 - float(re.search(r"^#define BLOOM_STRENGTH\s+([^\s/]+)",settings,re.M).group(1))
            values.update(halo_energy_ratio=float(lums[1].sum()/lums[0].sum()),
                          halo_annulus_curvature_p99_before_after=curvature,
                          curvature_ratio=curvature[1]/curvature[0],
                          scene_core_max_error=float(abs(b[0]-b[2]-scene*scene_coefficient).max()))
        metrics["fixtures"][name]=values
    if args.controls_only:
        (OUT/"metrics.json").write_text(json.dumps(metrics,indent=2)+"\n")
        print(json.dumps(metrics,indent=2))
        assert metrics["fixtures"]["black"]["max_abs_hdr_change"] == 0
        assert metrics["fixtures"]["uniform"]["max_abs_hdr_change"] < 1e-6
        assert all(x["finite"] and x["min_after_hdr"] >= 0 for x in metrics["fixtures"].values())
        print("PASS: uniform/black controls at requested dimensions")
        return
    ImagePair = Image.new("RGB", (W, H//2+28))
    for n,name in enumerate(["before","after"]):
        im=Image.open(OUT/(name+".png"))
        crop=im.crop((center[0]-W//4,H-center[1]-H//4,center[0]+W//4,H-center[1]+H//4))
        ImagePair.paste(crop,(n*W//2,28))
    ImageDraw.Draw(ImagePair).text((8,8),"CURRENT ULTRA: cubic halo" if args.baseline_mode == "current-ultra" else "HISTORICAL: bilinear mip halo",fill="white")
    ImageDraw.Draw(ImagePair).text((W//2+8,8),args.profile + ": current cubic halo, same input",fill="white")
    ImagePair.save(OUT/"comparison.png")
    candidate_bloom = render(scene,True)[2]
    reference_bloom = render(scene,"reference")[2]
    metrics["hardware_folded_vs_36_fetch_reference_max_error"]=float(abs(candidate_bloom-reference_bloom).max())
    exact_candidate_bloom = render(scene,"exact_candidate")[2]
    exact_reference_bloom = render(scene,"exact_reference")[2]
    metrics["full_precision_folded_vs_36_fetch_reference_max_error"]=float(abs(exact_candidate_bloom-exact_reference_bloom).max())
    metrics["full_precision_folded_reference_relative_error"] = metrics["full_precision_folded_vs_36_fetch_reference_max_error"] / float(abs(exact_reference_bloom).max())
    def basis(x):
        a=abs(x)
        return (4+a*a*(3*a-6))/6 if a<1 else max(2-a,0)**3/6
    max_math_error = 0.0
    values = [0.5, 3.1, 0.02, 7.4, 0.8, 1.2]
    for radius in [0.25,0.5,0.75]:
        for f in np.linspace(0,1,101,endpoint=False):
            weights = [.25*basis(j-f-radius)+.5*basis(j-f)+.25*basis(j-f+radius) for j in range(-2,4)]
            direct = sum(v*w for v,w in zip(values,weights))
            pairs = 0.0
            for i in range(0,6,2):
                g = weights[i]+weights[i+1]
                ratio = weights[i+1]/g if g else 0
                pairs += ((1-ratio)*values[i]+ratio*values[i+1])*g
            max_math_error=max(max_math_error,abs(direct-pairs),abs(sum(weights)-1))
    metrics["float64_pairing_and_normalization_max_error"]=max_math_error
    # Warm up both shader programs before a small timing sample, without inferring whole-game speed.
    if not args.no_timing:
        timings={}
        for candidate in [False,True]:
            render(scene,candidate)
            timings["after" if candidate else "before"]=[render(scene,candidate)[1] for _ in range(3)]
        metrics["gpu_ms_samples"]=timings
    (OUT/"metrics.json").write_text(json.dumps(metrics,indent=2)+"\n")
    print(json.dumps(metrics,indent=2))
    assert metrics["fixtures"]["black"]["max_abs_hdr_change"] == 0
    assert metrics["fixtures"]["uniform"]["max_abs_hdr_change"] < 1e-6
    assert all(x["finite"] and x["min_after_hdr"] >= 0 for x in metrics["fixtures"].values())
    assert .9 < metrics["fixtures"]["torch"]["halo_energy_ratio"] < 1.1
    if args.baseline_mode == "historical":
        assert metrics["fixtures"]["torch"]["curvature_ratio"] < 1
    assert metrics["fixtures"]["torch"]["scene_core_max_error"] < 1e-5
    assert metrics["full_precision_folded_reference_relative_error"] < 1e-4
    assert metrics["float64_pairing_and_normalization_max_error"] < 1e-12
    print("PASS: normalized constant/black fields, nonnegative finite output, retained halo energy; current-tier curvature reported separately"
          if args.baseline_mode == "current-ultra" else
          "PASS: normalized constant/black fields, nonnegative finite output, retained halo energy, smoother halo curvature")


if __name__ == "__main__":
    main()
