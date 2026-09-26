package dev.claudebench.benchcam;

import com.google.gson.JsonParser;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Validate the real shipped catalog against the Java parser and production sampler. No Minecraft classes. */
public final class DynamicRouteTest {
    public static void main(String[] arguments) throws Exception {
        var routes = JsonParser.parseString(Files.readString(Path.of(arguments[0]))).getAsJsonObject().getAsJsonArray("routes");
        int count = 0;
        for (var entry : routes) {
            byte[] bytes = entry.toString().getBytes(StandardCharsets.UTF_8);
            DynamicRoute route = new DynamicRoute(bytes);
            RouteMath.Pose a = new RouteMath.Pose(), b = new RouteMath.Pose();
            route.path.sample(0, a); route.path.sample(1, b);
            check(distance(a, b) < 1e-7, "closed catalog path");
            double expected = route.path.length / 20000, max = 0;
            route.path.sample(0, a);
            for (int i = 1; i <= 20000; i++) {
                route.path.sample(i / 20000.0, b);
                max = Math.max(max, Math.abs(distance(a, b) / expected - 1));
                a.x = b.x; a.y = b.y; a.z = b.z;
                double t = route.duration * i / 20000;
                check(Double.isFinite(route.environment(t, 1)), "finite world clock");
                check(route.environment(t, 2) >= 0 && route.environment(t, 2) <= 1, "bounded rain");
                check(route.environment(t, 3) >= 0 && route.environment(t, 3) <= 1, "bounded thunder");
            }
            check(max < .003, "catalog speed error " + max);
            check(route.hash.equals(new DynamicRoute(bytes).hash), "stable exact-byte hash");
            System.out.println(route.id + " speed=" + route.path.length / route.duration + " max_speed_relative_error=" + max + " hash=" + route.hash);
            count++;
        }
        System.out.println("PASS " + count + " catalog definitions, sampled speed/environment/hash invariants");
    }
    private static double distance(RouteMath.Pose a, RouteMath.Pose b) {
        double x = a.x - b.x, y = a.y - b.y, z = a.z - b.z;
        return Math.sqrt(x * x + y * y + z * z);
    }
    private static void check(boolean result, String message) { if (!result) throw new AssertionError(message); }
}
