package dev.claudebench.benchcam;

/** Dependency-free executable invariants for the exact production route sampler. */
public final class RouteMathTest {
    public static void main(String[] ignored) {
        double[][] points = {{0,0,0,0,0}, {20,2,-20,90,5}, {0,0,-40,180,0}, {-20,-2,-20,270,-5}, {0,0,0,360,0}};
        RouteMath math = new RouteMath(points);
        RouteMath.Pose a = new RouteMath.Pose(), b = new RouteMath.Pose();
        math.sample(0, a); math.sample(1, b);
        check(distance(a, b) < 1e-9 && Math.abs(b.yaw - a.yaw - 360) < 1e-9, "closed pose/yaw");
        // Equal elapsed intervals cover equal distances despite unequal spline parameter speed.
        double expected = math.length / 10000, maxRelative = 0;
        math.sample(0, a);
        for (int i = 1; i <= 10000; i++) {
            math.sample(i / 10000.0, b);
            maxRelative = Math.max(maxRelative, Math.abs(distance(a, b) / expected - 1));
            check(Double.isFinite(b.x) && Double.isFinite(b.yaw), "finite sample");
            a.x = b.x; a.y = b.y; a.z = b.z;
        }
        check(maxRelative < .002, "constant speed error: " + maxRelative);
        math.sample(.137, a);
        math.sample(.137, b);
        check(distance(a, b) == 0 && a.yaw == b.yaw, "sampling independent of prior frames");
        // A stall advances to the same elapsed pose, rather than replaying missed frame increments.
        math.sample(.01, b); math.sample(.9, b); math.sample(.137, b);
        check(distance(a, b) == 0, "clock-based sampling after skipped frames");
        RouteMath.Pose before = new RouteMath.Pose(), after = new RouteMath.Pose(), start = new RouteMath.Pose();
        math.sample(1 - 1e-5, before); math.sample(1e-5, after); math.sample(0, start);
        check(Math.abs((start.x - before.x) - (after.x - start.x)) < 1e-5, "periodic tangent");
        boolean rejected = false;
        try { new RouteMath(new double[][]{{0,0,0,0,0},{1,0,0,0,0},{1,0,1,0,0},{0,0,1,0,0},{2,0,0,0,0}}); }
        catch (IllegalArgumentException expectedFailure) { rejected = true; }
        check(rejected, "unclosed route rejected");
        System.out.println("PASS constant-speed max relative error=" + maxRelative + ", deterministic sampling, closed pose/tangent, malformed route rejection");
    }
    private static double distance(RouteMath.Pose a, RouteMath.Pose b) {
        double x = a.x - b.x, y = a.y - b.y, z = a.z - b.z;
        return Math.sqrt(x * x + y * y + z * z);
    }
    private static void check(boolean result, String message) { if (!result) throw new AssertionError(message); }
}
