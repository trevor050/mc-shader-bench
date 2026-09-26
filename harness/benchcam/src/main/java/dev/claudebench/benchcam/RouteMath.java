package dev.claudebench.benchcam;

/** Closed Catmull-Rom path with a precomputed arc-length parameterization. No sampling allocations. */
public final class RouteMath {
    private static final int SUBDIVISIONS = 1024;
    private final double[][] points;
    private final double[] cumulative;
    private final int segments;
    private final double yawCycle;
    public final double length;

    public static final class Pose {
        public double x, y, z, yaw, pitch;
    }

    public RouteMath(double[][] input) {
        if (input.length < 5 || input.length > 65) throw new IllegalArgumentException("Closed routes need 4..64 distinct points plus repeated endpoint");
        points = new double[input.length][];
        for (int i = 0; i < input.length; i++) {
            if (input[i].length != 5) throw new IllegalArgumentException("Point must contain x,y,z,yaw,pitch");
            points[i] = input[i].clone();
            for (double value : points[i]) if (!Double.isFinite(value)) throw new IllegalArgumentException("Nonfinite route point");
            if (Math.abs(points[i][4]) > 90) throw new IllegalArgumentException("Pitch outside -90..90");
        }
        segments = points.length - 1;
        for (int axis = 0; axis < 3; axis++) if (Math.abs(points[0][axis] - points[segments][axis]) > 1e-8)
            throw new IllegalArgumentException("Route must close at its initial position");
        if (Math.abs(points[0][4] - points[segments][4]) > 1e-8) throw new IllegalArgumentException("Pitch must close");
        yawCycle = points[segments][3] - points[0][3];
        if (Math.abs(yawCycle / 360 - Math.rint(yawCycle / 360)) > 1e-8) throw new IllegalArgumentException("Yaw endpoint must match modulo 360; use explicit unwrapped angles");
        for (int i = 1; i < points.length; i++) if (Math.abs(points[i][3] - points[i - 1][3]) > 180)
            throw new IllegalArgumentException("Adjacent yaw changes must not exceed 180 degrees");
        cumulative = new double[segments * SUBDIVISIONS + 1];
        Pose previous = new Pose(), next = new Pose();
        sampleParameter(0, previous);
        for (int i = 1; i < cumulative.length; i++) {
            sampleParameter((double)i / SUBDIVISIONS, next);
            double dx = next.x - previous.x, dy = next.y - previous.y, dz = next.z - previous.z;
            cumulative[i] = cumulative[i - 1] + Math.sqrt(dx * dx + dy * dy + dz * dz);
            previous.x = next.x; previous.y = next.y; previous.z = next.z;
        }
        length = cumulative[cumulative.length - 1];
        if (length < 1 || length > 8192) throw new IllegalArgumentException("Path length must be 1..8192 blocks");
    }

    /** fraction is elapsed / duration. Translation speed is constant to lookup-table accuracy. */
    public void sample(double fraction, Pose result) {
        fraction = Math.max(0, Math.min(1, fraction));
        double target = fraction * length;
        int lo = 0, hi = cumulative.length - 1;
        while (hi - lo > 1) {
            int mid = (lo + hi) >>> 1;
            if (cumulative[mid] < target) lo = mid; else hi = mid;
        }
        double delta = cumulative[hi] - cumulative[lo];
        double coordinate = lo + (delta > 1e-12 ? (target - cumulative[lo]) / delta : 0);
        sampleParameter(coordinate / SUBDIVISIONS, result);
    }

    private double value(int index, int axis) {
        int cycle = Math.floorDiv(index, segments);
        int wrapped = Math.floorMod(index, segments);
        return points[wrapped][axis] + (axis == 3 ? cycle * yawCycle : 0);
    }

    private void sampleParameter(double parameter, Pose pose) {
        int segment = Math.min(segments - 1, (int)parameter);
        double u = parameter - segment;
        pose.x = spline(segment, u, 0); pose.y = spline(segment, u, 1); pose.z = spline(segment, u, 2);
        pose.yaw = spline(segment, u, 3); pose.pitch = Math.max(-90, Math.min(90, spline(segment, u, 4)));
    }

    private double spline(int i, double u, int axis) {
        double a = value(i - 1, axis), b = value(i, axis), c = value(i + 1, axis), d = value(i + 2, axis);
        return 0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u + (-a + 3 * b - 3 * c + d) * u * u * u);
    }
}
