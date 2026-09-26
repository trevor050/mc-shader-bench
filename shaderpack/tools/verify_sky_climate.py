"""Check sky custom uniforms with the installed Iris expression engine.

The real parser catches properties errors that glslang cannot see. This check
does not launch, reload or control Minecraft. Requires a JDK and Prism's Iris,
JOML and fastutil jars; paths can be supplied for another installation.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

JAVA = r'''
import java.nio.file.*;
import java.util.*;
import kroppeb.stareval.parser.Parser;
import kroppeb.stareval.resolver.ExpressionResolver;
import kroppeb.stareval.expression.Expression;
import kroppeb.stareval.expression.VariableExpression;
import kroppeb.stareval.function.*;
import net.irisshaders.iris.parsing.*;
import net.irisshaders.iris.uniforms.SystemTimeUniforms;
import org.joml.Vector4f;

class SkyClimateCheck {
    record Spec(String name, Type type, String source) {}
    record Profile(String name, float temperature, float rainfall, int category, int precipitation) {}
    static final List<Spec> specs = new ArrayList<>();
    static final Map<String, Type> types = new HashMap<>();
    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    static class Engine {
        final BasicFunctionContext context = new BasicFunctionContext();
        final List<Expression> expressions = new ArrayList<>();
        Engine(Profile p) {
            context.setFloatVariable("temperature", p.temperature);
            context.setFloatVariable("rainfall", p.rainfall);
            context.setIntVariable("biome_category", p.category);
            context.setIntVariable("biome_precipitation", p.precipitation);
            for (BiomeCategories c : BiomeCategories.values())
                context.setIntVariable("CAT_" + c.name(), c.ordinal());
            context.setIntVariable("PPT_NONE", 0);
            context.setIntVariable("PPT_RAIN", 1);
            context.setIntVariable("PPT_SNOW", 2);
            ExpressionResolver resolver = new ExpressionResolver(IrisFunctions.functions, types::get);
            for (Spec s : specs) {
                try { expressions.add(resolver.resolveExpression(s.type, Parser.parse(s.source, IrisOptions.options))); }
                catch (Exception e) { throw new RuntimeException(s.name + " = " + s.source, e); }
            }
        }
        void evaluate(int day, int time, float rain, float thunder) {
            context.setIntVariable("worldDay", day);
            context.setIntVariable("worldTime", time);
            context.setFloatVariable("rainStrength", rain);
            context.setFloatVariable("thunderStrength", thunder);
            FunctionReturn result = new FunctionReturn();
            for (int i = 0; i < specs.size(); ++i) {
                Spec s = specs.get(i);
                expressions.get(i).evaluateTo(context, result);
                if (s.type == Type.Float) {
                    require(Float.isFinite(result.floatReturn), "nonfinite " + s.name);
                    context.setFloatVariable(s.name, result.floatReturn);
                } else if (s.type == VectorType.VEC4) {
                    Vector4f value = new Vector4f((Vector4f) result.objectReturn);
                    require(value.isFinite(), "nonfinite " + s.name);
                    context.setVariable(s.name, (VariableExpression) (c, r) -> r.objectReturn = value);
                }
            }
        }
        float scalar(String name) {
            FunctionReturn r = new FunctionReturn();
            context.getVariable(name).evaluateTo(context, r);
            return r.floatReturn;
        }
        Vector4f climate() {
            FunctionReturn r = new FunctionReturn();
            context.getVariable("skyClimate").evaluateTo(context, r);
            return new Vector4f((Vector4f) r.objectReturn);
        }
    }
    public static void main(String[] args) throws Exception {
        for (String name : List.of("temperature", "rainfall", "rainStrength", "thunderStrength"))
            types.put(name, Type.Float);
        for (String name : List.of("worldDay", "worldTime", "biome_category", "biome_precipitation", "PPT_NONE", "PPT_RAIN", "PPT_SNOW"))
            types.put(name, Type.Int);
        for (BiomeCategories c : BiomeCategories.values()) types.put("CAT_" + c.name(), Type.Int);
        for (String line : Files.readAllLines(Path.of(args[0]))) {
            String[] halves = line.strip().split("=", 2);
            if (halves.length != 2) continue;
            String[] key = halves[0].strip().split("\\.");
            if (key.length != 3 || !key[2].startsWith("sky")) continue;
            if (!key[0].equals("uniform") && !key[0].equals("variable")) continue;
            Type type = switch(key[1]) {
                case "float" -> Type.Float;
                case "vec4" -> VectorType.VEC4;
                default -> throw new AssertionError("unexpected type " + key[1]);
            };
            specs.add(new Spec(key[2], type, halves[1].strip()));
            types.put(key[2], type);
        }
        require(specs.size() >= 12, "sky properties not present");
        List<Profile> profiles = List.of(
            new Profile("temperate", 0.8f, 0.4f, BiomeCategories.PLAINS.ordinal(), 1),
            new Profile("cold", -0.5f, 0.5f, BiomeCategories.ICY.ordinal(), 2),
            new Profile("arid", 2.0f, 0.0f, BiomeCategories.DESERT.ordinal(), 0),
            new Profile("humid", 0.95f, 0.9f, BiomeCategories.JUNGLE.ordinal(), 1),
            new Profile("maritime", 0.5f, 0.5f, BiomeCategories.OCEAN.ordinal(), 1),
            new Profile("frozen_coast", -0.5f, 0.5f, BiomeCategories.OCEAN.ordinal(), 2));
        int samples = 0;
        for (Profile p : profiles) {
            Engine engine = new Engine(p);
            for (int day = 0; day < 120; ++day)
                for (int time = 0; time < 24000; time += 1000)
                    for (float rain : new float[]{0.0f, 0.5f, 1.0f}) {
                        engine.evaluate(day, time, rain, rain);
                        Vector4f c = engine.climate();
                        for (int i = 0; i < 4; ++i)
                            require(c.get(i) >= 0.0f && c.get(i) <= 1.0f, "climate axis out of bounds");
                        require(engine.scalar("skyAerosol") >= 0.7f && engine.scalar("skyAerosol") <= 1.65f, "aerosol bounds");
                        require(engine.scalar("skyConvection") >= 0.0f && engine.scalar("skyConvection") <= 1.0f, "convection bounds");
                        require(engine.scalar("skyVividEvent") >= 0.0f && engine.scalar("skyVividEvent") <= 1.0f, "event bounds");
                        if (rain == 1.0f) require(engine.scalar("skyVividEvent") == 0.0f, "vivid event survives overcast");
                        ++samples;
                    }
            engine.evaluate(8, 7000, 0.0f, 0.0f);
            System.out.printf(Locale.ROOT, "%s axes=%s aerosol=%.3f convection=%.3f%n", p.name, engine.climate(), engine.scalar("skyAerosol"), engine.scalar("skyConvection"));
        }
        Engine engine = new Engine(profiles.getFirst());
        int vivid = 0, strong = 0;
        int vividTestDay = -1, quietTestDay = -1;
        float maxBoundaryStep = 0;
        for (int day = 0; day < 2000; ++day) {
            engine.evaluate(day, 12500, 0, 0);
            if (engine.scalar("skyVividEvent") > 0.2f) ++vivid;
            if (engine.scalar("skyVividEvent") > 0.75f) ++strong;
            if (vividTestDay < 0 && engine.scalar("skyVividEvent") > 0.9f) vividTestDay = day;
            if (quietTestDay < 0 && engine.scalar("skyVividEvent") == 0.0f) quietTestDay = day;
            engine.evaluate(day, 23999, 0, 0);
            float before = engine.scalar("skyVividEvent");
            engine.evaluate(day + 1, 0, 0, 0);
            maxBoundaryStep = Math.max(maxBoundaryStep, Math.abs(engine.scalar("skyVividEvent") - before));
        }
        require(vivid > 20 && vivid < 500, "sunset enhancement rarity outside useful range: " + vivid);
        require(strong < 200, "strong sunset events are too common");
        require(maxBoundaryStep < 0.001f, "day boundary event discontinuity");
        for (int day : new int[]{quietTestDay, vividTestDay}) {
            engine.evaluate(day, 12500, 0, 0);
            System.out.printf(Locale.ROOT, "visual sunset probe day=%d time=12500 (/time set %d) event=%.3f%n", day, day * 24000 + 12500, engine.scalar("skyVividEvent"));
        }
        SmoothFloat smooth = new SmoothFloat();
        SystemTimeUniforms.TIMER.reset();
        smooth.updateAndGet(0.0f, 300.0f, 300.0f);
        SystemTimeUniforms.TIMER.beginFrame(0);
        float crossing = 0;
        for (int i = 1; i <= 300; ++i) {
            SystemTimeUniforms.TIMER.beginFrame(i * 100_000_000L);
            crossing = smooth.updateAndGet(1.0f, 300.0f, 300.0f);
        }
        require(Math.abs(crossing - 0.5f) < 0.002f, "installed smoothing half-life changed: " + crossing);
        System.out.printf(Locale.ROOT, "checked %d climate/time/weather samples; vivid dusk %.2f%%, strong %.2f%%; maximum day boundary step %.6f; 30s crossing %.4f%n", samples, vivid / 20.0f, strong / 20.0f, maxBoundaryStep, crossing);
    }
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prism", type=Path, default=Path(os.environ.get("APPDATA", "")) / "PrismLauncher")
    parser.add_argument("--iris", type=Path)
    parser.add_argument("--properties", type=Path, default=Path(__file__).resolve().parents[1] / "shaders" / "shaders.properties")
    args = parser.parse_args()
    iris = args.iris
    if iris is None:
        jars = list((args.prism / "instances" / "ShaderBench" / "minecraft" / "mods").glob("iris*.jar"))
        if len(jars) != 1:
            raise SystemExit("pass --iris with the installed Iris jar")
        iris = jars[0]
    libraries = args.prism / "libraries"
    dependencies = []
    for package in ("joml", "fastutil"):
        jars = sorted(libraries.rglob(f"{package}-*.jar"))
        if not jars:
            raise SystemExit(f"missing {package} jar under {libraries}")
        dependencies.append(jars[-1])
    classpath = os.pathsep.join(str(p) for p in [iris, *dependencies])
    with tempfile.TemporaryDirectory(prefix="sky-climate-check-") as temp:
        source = Path(temp) / "SkyClimateCheck.java"
        source.write_text(JAVA, encoding="utf-8")
        subprocess.run(["java", "--class-path", classpath, str(source), str(args.properties)], check=True)


if __name__ == "__main__":
    main()
