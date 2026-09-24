package dev.claudebench.benchcam;

import java.util.function.Consumer;

/** Render-thread scope for the vanilla dispatcher, which also runs outside Iris shadows. */
public final class ShadowFeaturePhaseScope {
	private static final ThreadLocal<Scope> ACTIVE = new ThreadLocal<>();

	private static final class Scope {
		final Consumer<String> phaseChange;
		int nodeCount;

		Scope(Consumer<String> phaseChange) { this.phaseChange = phaseChange; }
	}

	private ShadowFeaturePhaseScope() {}

	public static void enter(Consumer<String> callback) {
		ACTIVE.set(new Scope(callback));
	}

	public static void next(String phase) {
		Scope scope = ACTIVE.get();
		if (scope != null) {
			GpuPassProfiler.setFeatureNodeCount(scope.nodeCount);
			scope.phaseChange.accept(phase);
			scope.nodeCount = 0;
		}
	}

	public static void addNodes(int count) {
		Scope scope = ACTIVE.get();
		if (scope != null) scope.nodeCount += count;
	}

	public static void exit() {
		try {
			Scope scope = ACTIVE.get();
			if (scope != null) GpuPassProfiler.setFeatureNodeCount(scope.nodeCount);
		} finally {
			ACTIVE.remove();
		}
	}
}
