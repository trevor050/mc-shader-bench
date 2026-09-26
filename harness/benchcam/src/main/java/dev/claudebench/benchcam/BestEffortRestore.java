package dev.claudebench.benchcam;

import java.util.function.BiConsumer;

/** A failed restore group must never prevent attempting the remaining saved state. */
final class BestEffortRestore {
    @FunctionalInterface interface Action { void run() throws Throwable; }
    private final BiConsumer<String, Throwable> report;
    private boolean succeeded = true;
    BestEffortRestore(BiConsumer<String, Throwable> report) { this.report = report; }
    void attempt(String group, Action action) {
        try { action.run(); }
        catch (Throwable failure) { succeeded = false; report.accept(group, failure); }
    }
    boolean succeeded() { return succeeded; }
}
