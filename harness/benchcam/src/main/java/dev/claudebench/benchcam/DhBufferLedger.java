package dev.claudebench.benchcam;

import java.util.HashMap;
import java.util.Map;

/** Tracks only DH GLBuffer storage changes, without GL calls or retained buffer objects. */
public final class DhBufferLedger {
	private static final boolean ENABLED = Boolean.getBoolean("benchcam.memowners.trackDh");
	private static final Map<Integer, Integer> BUFFER_BYTES = new HashMap<>();
	private static long totalBytes;

	private DhBufferLedger() {}

	public record Snapshot(boolean enabled, long bytes, int count) {}

	/** Called only after DH has successfully established storage for this GL buffer name. */
	public static void record(int id, int size) {
		if (!ENABLED || id <= 0 || size < 0) return;
		synchronized (BUFFER_BYTES) {
			Integer old = BUFFER_BYTES.put(id, size);
			totalBytes += (long) size - (old == null ? 0 : old);
		}
	}

	/** Called after the actual DH GL deletion, including its deferred cleanup path. */
	public static void forget(int id) {
		if (!ENABLED || id <= 0) return;
		synchronized (BUFFER_BYTES) {
			Integer old = BUFFER_BYTES.remove(id);
			if (old != null) totalBytes -= old;
		}
	}

	public static Snapshot snapshot() {
		if (!ENABLED) return new Snapshot(false, 0, 0);
		synchronized (BUFFER_BYTES) {
			return new Snapshot(true, totalBytes, BUFFER_BYTES.size());
		}
	}
}
