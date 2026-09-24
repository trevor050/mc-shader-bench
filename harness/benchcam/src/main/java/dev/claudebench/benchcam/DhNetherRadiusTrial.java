package dev.claudebench.benchcam;

import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.world.level.Level;

/** Opt-in, in-memory radius override for the DH-equipped ShaderBench harness. */
public final class DhNetherRadiusTrial {
	private static final int DEFAULT_NETHER_RADIUS = 64;
	private static final int MIN_NETHER_RADIUS = 32;
	private static final long MAX_CLEAR_RETRY_MS = 10_000;
	private static final boolean DH_PRESENT = FabricLoader.getInstance().isModLoaded("distanthorizons");
	private static boolean enabled = DH_PRESENT && Boolean.getBoolean("benchcam.dhNetherRadiusTrial");
	private static boolean failed;
	private static boolean owned;
	private static boolean suspended;
	private static boolean clearPending;
	private static int requestedRadius = DEFAULT_NETHER_RADIUS;
	private static Integer ownedRadius;
	private static int clearFailures;
	private static long nextClearRetryNs;
	private static String error = "none";
	private static String clearError = "none";

	private DhNetherRadiusTrial() {}

	/** Called at renderFrame HEAD and at tick end, always on the client thread. */
	public static void update(Minecraft mc) {
		if (!DH_PRESENT) return;
		boolean nether = mc.level != null && Level.NETHER.equals(mc.level.dimension());
		if (!enabled || failed || suspended || !nether) {
			if (owned && (!clearPending || System.nanoTime() - nextClearRetryNs >= 0)) clear();
			return;
		}
		if (owned) return;
		try {
			if (!DhAccess.ready()) return;
			Integer savedRadius = DhAccess.set(requestedRadius);
			owned = true;
			ownedRadius = requestedRadius;
			DhAccess.verify(requestedRadius, savedRadius);
			BenchCam.LOG.info("BenchCam DH Nether radius override active: {} chunks", requestedRadius);
		} catch (Throwable t) {
			fail(t);
		}
	}

	public static String command(String arg, Minecraft mc) {
		if (arg.startsWith("radius ")) return setRequestedRadius(arg.substring(7).strip(), mc);
		return switch (arg) {
			case "status" -> status(mc);
			case "on" -> {
				if (!DH_PRESENT) yield "err DH absent";
				if (clearPending) {
					clear();
					if (owned) yield "err DH radius cleanup pending: " + clearError;
				}
				failed = false;
				error = "none";
				enabled = true;
				update(mc);
				yield failed ? "err " + error : status(mc);
			}
			case "off" -> {
				enabled = false;
				clear();
				yield failed ? "err " + error : status(mc);
			}
			default -> "err usage: dhtrial on|off|status|radius <chunks>";
		};
	}

	private static String setRequestedRadius(String raw, Minecraft mc) {
		final int chunks;
		try {
			chunks = Integer.parseInt(raw);
		} catch (NumberFormatException e) {
			return "err usage: dhtrial radius <chunks>";
		}
		if (chunks < MIN_NETHER_RADIUS) return "err DH radius must be at least " + MIN_NETHER_RADIUS;
		if (!DH_PRESENT) return "err DH absent";
		try {
			if (!DhAccess.ready()) return "err DH configs initializing";
			Integer savedRadius = DhAccess.trueValue();
			if (savedRadius == null) return "err DH saved radius unavailable";
			if (chunks > savedRadius) return "err DH radius exceeds saved radius " + savedRadius;
		} catch (Throwable t) {
			return "err DH radius validation: " + t;
		}
		if (clearPending) return "err DH radius cleanup pending: " + clearError;
		if (owned) {
			clear();
			if (owned || clearPending) return "err DH radius cleanup pending: " + clearError;
		}
		try {
			if (DhAccess.apiValue() != null) return "err DH radius overridden by another mod";
		} catch (Throwable t) {
			return "err DH radius check: " + t;
		}
		requestedRadius = chunks;
		if (enabled && !failed && !suspended && mc.level != null && Level.NETHER.equals(mc.level.dimension())) {
			update(mc);
			if (failed) return "err " + error;
		}
		return status(mc);
	}

	public static String status(Minecraft mc) {
		String dimension = mc.level == null ? "none" : mc.level.dimension().toString();
		String prefix = "ok enabled=" + enabled + " requested=" + requestedRadius + " dhPresent=" + DH_PRESENT + " dimension=" + dimension
				+ " owned=" + owned + " suspended=" + suspended + " failed=" + failed
				+ " clearPending=" + clearPending + " clearFailures=" + clearFailures
				+ " error=" + error + " clearError=" + clearError;
		if (!DH_PRESENT) return prefix + " active=unavailable true=unavailable api=unavailable";
		try {
			if (!DhAccess.ready()) return prefix + " active=initializing true=initializing api=initializing";
			return prefix + " " + DhAccess.status();
		} catch (Throwable t) {
			return "err DH status: " + t;
		}
	}

	/** Called on disconnect and client stop in addition to ordinary dimension transitions. */
	public static void clear() {
		if (!owned) return;
		try {
			Integer apiValue = DhAccess.apiValue();
			if (apiValue == null) {
				releaseOwnership();
				return;
			}
			if (!java.util.Objects.equals(apiValue, ownedRadius)) {
				releaseOwnership();
				BenchCam.LOG.warn("BenchCam did not clear a DH radius override changed by another mod: {}", apiValue);
				return;
			}
			DhAccess.clear();
			if (DhAccess.apiValue() != null) throw new IllegalStateException("DH radius override remained after clear");
			releaseOwnership();
			BenchCam.LOG.info("BenchCam DH Nether radius override cleared");
		} catch (Throwable t) {
			recordClearFailure(t);
		}
	}

	private static void releaseOwnership() {
		owned = false;
		ownedRadius = null;
		clearPending = false;
		clearFailures = 0;
		nextClearRetryNs = 0;
		clearError = "none";
	}

	private static void recordClearFailure(Throwable t) {
		boolean firstFailure = !clearPending;
		failed = true;
		enabled = false;
		clearPending = true;
		clearFailures++;
		clearError = t.toString().replace(' ', '_');
		long delayMs = Math.min(MAX_CLEAR_RETRY_MS, 1000L << Math.min(clearFailures - 1, 4));
		nextClearRetryNs = System.nanoTime() + java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(delayMs);
		if (firstFailure) BenchCam.LOG.error("BenchCam DH radius clear failed; retrying with backoff", t);
	}

	public static void disconnect() {
		suspended = true;
		clear();
	}

	public static void join() {
		suspended = false;
	}

	private static void fail(Throwable t) {
		boolean firstFailure = !failed;
		failed = true;
		enabled = false;
		error = t.toString().replace(' ', '_');
		if (firstFailure) BenchCam.LOG.error("BenchCam DH radius trial failed; clearing override", t);
		clear();
	}

	/** Keep this API link out of the outer class so the new adapter does not resolve it before DH is present. */
	private static final class DhAccess {
		private static boolean ready() {
			return com.seibel.distanthorizons.api.DhApi.Delayed.configs != null;
		}

		private static com.seibel.distanthorizons.api.interfaces.config.IDhApiConfigValue<Integer> radius() {
			var configs = com.seibel.distanthorizons.api.DhApi.Delayed.configs;
			if (configs == null) throw new IllegalStateException("DH API configs not initialized");
			return configs.graphics().chunkRenderDistance();
		}

		private static Integer set(int chunks) {
			var value = radius();
			if (!value.getCanBeOverrodeByApi()) throw new IllegalStateException("DH radius cannot be overridden");
			if (value.getApiValue() != null) throw new IllegalStateException("DH radius already overridden by another mod");
			Integer savedRadius = value.getTrueValue();
			if (savedRadius == null || chunks < MIN_NETHER_RADIUS || chunks > savedRadius)
				throw new IllegalArgumentException("requested DH radius outside [" + MIN_NETHER_RADIUS + ", saved radius " + savedRadius + "]");
			if (!value.setValue(chunks, "BenchCam Nether radius trial")) throw new IllegalStateException("DH rejected radius override");
			return savedRadius;
		}

		private static Integer trueValue() {
			return radius().getTrueValue();
		}

		private static void verify(int chunks, Integer savedRadius) {
			var value = radius();
			if (!Integer.valueOf(chunks).equals(value.getValue()) || !Integer.valueOf(chunks).equals(value.getApiValue()))
				throw new IllegalStateException("DH did not activate requested radius");
			if (!java.util.Objects.equals(savedRadius, value.getTrueValue()))
				throw new IllegalStateException("DH changed saved radius during API override");
		}

		private static void clear() {
			if (!radius().clearValue()) throw new IllegalStateException("DH rejected radius clear");
		}

		private static Integer apiValue() {
			return radius().getApiValue();
		}

		private static String status() {
			var value = radius();
			return "active=" + value.getValue() + " true=" + value.getTrueValue() + " api=" + value.getApiValue();
		}
	}
}
