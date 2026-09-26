package dev.claudebench.benchcam;

import java.util.ArrayList;
import java.util.List;

/** Fault injection exercises the same accumulator used by client and server restoration. */
public final class BestEffortRestoreTest {
    public static void main(String[] ignored) {
        List<String> restored = new ArrayList<>(), failures = new ArrayList<>();
        BestEffortRestore restore = new BestEffortRestore((group, failure) -> failures.add(group));
        restore.attempt("mode", () -> restored.add("mode"));
        restore.attempt("clock", () -> { throw new IllegalStateException("injected clock failure"); });
        restore.attempt("weather", () -> restored.add("weather"));
        restore.attempt("weather_rule", () -> restored.add("weather_rule"));
        restore.attempt("client_clock", () -> { throw new AssertionError("injected client failure"); });
        restore.attempt("client_pose", () -> restored.add("client_pose"));
        restore.attempt("slot", () -> restored.add("slot"));
        if (restore.succeeded() || !failures.equals(List.of("clock", "client_clock"))
            || !restored.equals(List.of("mode", "weather", "weather_rule", "client_pose", "slot")))
            throw new AssertionError("Failed group skipped later restoration: " + restored + " / " + failures);
        BestEffortRestore clean = new BestEffortRestore((group, failure) -> { throw new AssertionError(failure); });
        clean.attempt("clean", () -> {});
        if (!clean.succeeded()) throw new AssertionError("clean restore rejected");
        System.out.println("BestEffortRestoreTest passed: independent groups continue after Exception and Error");
    }
}
