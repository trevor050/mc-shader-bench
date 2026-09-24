package dev.claudebench.benchcam;

import java.util.Arrays;
import java.util.Locale;

/** Low-allocation rolling samples of Minecraft's per-frame CPU render duration. */
public final class FrameTimeStats {
	private static final int CAPACITY = 4096;
	private static final int DEFAULT_SAMPLE_COUNT = 120;
	private static final long[] FRAME_TIMES_NS = new long[CAPACITY];
	private static int nextIndex;
	private static int count;

	private FrameTimeStats() {}

	/** Called once per Minecraft renderFrame invocation; keeps the hot path allocation-free. */
	public static synchronized void record(long frameTimeNs) {
		if (frameTimeNs <= 0) return;
		FRAME_TIMES_NS[nextIndex] = frameTimeNs;
		nextIndex = (nextIndex + 1) % CAPACITY;
		if (count < CAPACITY) count++;
	}

	/** Summarizes the latest n samples, or the latest 120 when n is omitted. */
	public static String summarizeRecent(String argument) {
		final int requested;
		if (argument == null || argument.isBlank()) {
			requested = DEFAULT_SAMPLE_COUNT;
		} else {
			try {
				requested = Integer.parseInt(argument.strip());
			} catch (NumberFormatException e) {
				return "err framestats expects an integer sample count from 1 to " + CAPACITY;
			}
		}
		if (requested < 1 || requested > CAPACITY) {
			return "err framestats sample count must be from 1 to " + CAPACITY;
		}

		long[] samples = snapshotRecent(requested);
		if (samples.length == 0) return "err no frame samples recorded yet";
		Arrays.sort(samples);

		long medianNs;
		int middle = samples.length / 2;
		if ((samples.length & 1) == 0) {
			long lower = samples[middle - 1];
			medianNs = lower + (samples[middle] - lower) / 2;
		} else {
			medianNs = samples[middle];
		}
		long p95Ns = samples[nearestRankIndex(samples.length, 0.95)];
		long p99Ns = samples[nearestRankIndex(samples.length, 0.99)];

		return String.format(Locale.ROOT,
			"ok n=%d median_ms=%.3f p95_ms=%.3f p99_ms=%.3f median_fps=%.2f",
			samples.length,
			medianNs / 1_000_000.0,
			p95Ns / 1_000_000.0,
			p99Ns / 1_000_000.0,
			1_000_000_000.0 / medianNs);
	}

	private static int nearestRankIndex(int sampleCount, double percentile) {
		return Math.max(0, (int) Math.ceil(percentile * sampleCount) - 1);
	}

	private static synchronized long[] snapshotRecent(int requested) {
		int sampleCount = Math.min(requested, count);
		long[] result = new long[sampleCount];
		int firstIndex = (nextIndex - sampleCount + CAPACITY) % CAPACITY;
		for (int i = 0; i < sampleCount; i++) {
			result[i] = FRAME_TIMES_NS[(firstIndex + i) % CAPACITY];
		}
		return result;
	}
}
