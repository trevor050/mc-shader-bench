package dev.claudebench.benchcam;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;

/** Validated immutable definition. Its hash covers the exact decoded protocol bytes. */
public final class DynamicRoute {
    public final String id, hash, dimension;
    public final double duration;
    public final RouteMath path;
    private final double[][] environment;

    public DynamicRoute(byte[] bytes) throws Exception {
        if (bytes.length > 128 * 1024) throw new IllegalArgumentException("Route JSON too large");
        JsonObject json = JsonParser.parseString(new String(bytes, StandardCharsets.UTF_8)).getAsJsonObject();
        if (json.get("version").getAsInt() != 1) throw new IllegalArgumentException("Unknown route schema");
        id = json.get("id").getAsString();
        if (!id.matches("[a-z0-9_-]{1,64}")) throw new IllegalArgumentException("Invalid route id");
        dimension = json.get("dimension").getAsString();
        if (!dimension.equals("minecraft:overworld")) throw new IllegalArgumentException("This route runner supports Overworld only");
        duration = json.get("duration_s").getAsDouble();
        if (!Double.isFinite(duration) || duration < 5 || duration > 180) throw new IllegalArgumentException("Duration must be 5..180 seconds");
        JsonArray input = json.getAsJsonArray("points");
        double[][] points = new double[input.size()][5];
        String[] axes = {"x", "y", "z", "yaw", "pitch"};
        for (int i = 0; i < points.length; i++) for (int j = 0; j < 5; j++) points[i][j] = input.get(i).getAsJsonObject().get(axes[j]).getAsDouble();
        path = new RouteMath(points);
        if (path.length / duration > 32) throw new IllegalArgumentException("Travel speed exceeds 32 blocks/second");
        JsonArray states = json.getAsJsonArray("environment");
        if (states.size() < 2 || states.size() > 64) throw new IllegalArgumentException("Environment needs 2..64 keyframes");
        environment = new double[states.size()][4];
        String[] fields = {"t_s", "time_ticks", "rain", "thunder"};
        for (int i = 0; i < states.size(); i++) {
            for (int j = 0; j < 4; j++) {
                double v = states.get(i).getAsJsonObject().get(fields[j]).getAsDouble();
                if (!Double.isFinite(v)) throw new IllegalArgumentException("Nonfinite environment keyframe");
                environment[i][j] = v;
            }
            if (environment[i][0] < 0 || environment[i][0] > duration || (i > 0 && environment[i][0] <= environment[i - 1][0]))
                throw new IllegalArgumentException("Environment times must increase across the route");
            if (environment[i][1] < 0 || environment[i][1] > 2_000_000_000L) throw new IllegalArgumentException("World time outside supported range");
            for (int j = 2; j < 4; j++) if (environment[i][j] < 0 || environment[i][j] > 1) throw new IllegalArgumentException("Weather strength outside 0..1");
        }
        if (environment[0][0] != 0 || environment[environment.length - 1][0] != duration)
            throw new IllegalArgumentException("Environment must span 0..duration");
        hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    /** Cubic easing gives zero derivative at each environment keyframe. */
    public double environment(double elapsed, int axis) {
        elapsed = Math.max(0, Math.min(duration, elapsed));
        int i = 0;
        while (i + 2 < environment.length && elapsed > environment[i + 1][0]) i++;
        double u = (elapsed - environment[i][0]) / (environment[i + 1][0] - environment[i][0]);
        u = u * u * (3 - 2 * u);
        return environment[i][axis] + (environment[i + 1][axis] - environment[i][axis]) * u;
    }
}
