package dev.claudebench.benchcam;

import net.fabricmc.loader.api.FabricLoader;
import net.irisshaders.iris.Iris;
import net.irisshaders.iris.api.v0.IrisApi;
import net.minecraft.client.Minecraft;
import net.minecraft.world.level.Level;
import net.minecraft.resources.ResourceKey;

/** In-memory Art-only radius overrides for the DH-equipped ShaderBench harness. */
public final class DhNetherRadiusTrial {
	private static final int DEFAULT_NETHER_RADIUS = 64;
	private static final int DEFAULT_END_RADIUS = 64;
	private static final int MIN_NETHER_RADIUS = 32;
	private static final int MIN_END_RADIUS = 64;
	private static final String REQUIRED_PACK_NAME = "ClaudeBenchV4Art";
	private static final boolean AUTO_ART_RADIUS = !Boolean.getBoolean("benchcam.disableArtDhRadiusAuto");
	private static final long MAX_CLEAR_RETRY_MS = 10_000;
	private static final boolean DH_PRESENT = FabricLoader.getInstance().isModLoaded("distanthorizons");
	// null follows the Art-only automatic default; explicit commands persist for this JVM session.
	private static Boolean netherSessionOverride = Boolean.getBoolean("benchcam.dhNetherRadiusTrial") ? Boolean.TRUE : null;
	private static Boolean endSessionOverride;
	private static boolean netherFailed;
	private static boolean endFailed;
	private static boolean owned;
	private static boolean suspended;
	private static boolean clearPending;
	private static int requestedNetherRadius = DEFAULT_NETHER_RADIUS;
	private static int requestedEndRadius = DEFAULT_END_RADIUS;
	private static Integer ownedRadius;
	private static ResourceKey<Level> ownedDimension;
	private static int clearFailures;
	private static long nextClearRetryNs;
	private static String netherError = "none";
	private static String endError = "none";
	private static String clearError = "none";

	private DhNetherRadiusTrial() {}

	/** Called at renderFrame HEAD and at tick end, always on the client thread. */
	public static void update(Minecraft mc) {
		if (!DH_PRESENT || (!netherControlEnabled() && !endControlEnabled() && !owned && !clearPending)) return;
		boolean artPackActive = isRequiredArtPackActive();
		ResourceKey<Level> dimension = mc.level == null ? null : mc.level.dimension();
		int desiredRadius = desiredRadius(dimension, artPackActive);
		if (suspended) desiredRadius = 0;

		if (owned && (!java.util.Objects.equals(dimension, ownedDimension) || desiredRadius != ownedRadius)) {
			if (!clearPending || System.nanoTime() - nextClearRetryNs >= 0) clear();
		}
		if (clearPending || owned || desiredRadius == 0) return;

		try {
			if (!DhAccess.ready()) return;
			int minRadius = Level.END.equals(dimension) ? MIN_END_RADIUS : MIN_NETHER_RADIUS;
			Integer savedRadius = DhAccess.set(desiredRadius, dimension.toString(), minRadius);
			owned = true;
			ownedRadius = desiredRadius;
			ownedDimension = dimension;
			DhAccess.verify(desiredRadius, savedRadius);
			BenchCam.LOG.info("BenchCam DH {} radius override active: {} chunks", dimension, desiredRadius);
		} catch (Throwable t) {
			fail(dimension, t);
		}
	}

	private static int desiredRadius(ResourceKey<Level> dimension, boolean artPackActive) {
		if (!artPackActive) return 0;
		if (Level.NETHER.equals(dimension) && netherControlEnabled() && !netherFailed) return requestedNetherRadius;
		if (Level.END.equals(dimension) && endControlEnabled() && !endFailed) return requestedEndRadius;
		return 0;
	}

	/** Iris 1.11.4 currentPackName is set after successful pack load; the API confirms a pipeline is active. */
	private static boolean isRequiredArtPackActive() {
		return REQUIRED_PACK_NAME.equals(Iris.getCurrentPackName())
				&& IrisApi.getInstance().isShaderPackInUse();
	}

	private static boolean netherControlEnabled() {
		return netherSessionOverride != null ? netherSessionOverride : AUTO_ART_RADIUS;
	}

	private static boolean endControlEnabled() {
		return endSessionOverride != null ? endSessionOverride : AUTO_ART_RADIUS;
	}

	private static String controlSource(Boolean override) {
		return override == null ? (AUTO_ART_RADIUS ? "auto" : "auto_disabled") : (override ? "session_on" : "session_off");
	}

	public static String command(String arg, Minecraft mc) {
		if (arg.startsWith("radius ")) return setRequestedNetherRadius(arg.substring(7).strip(), mc);
		return switch (arg) {
			case "status" -> status(mc);
			case "on" -> {
				if (!DH_PRESENT) yield "err DH absent";
				if (clearPending) {
					clear();
					if (clearPending) yield "err DH radius cleanup pending: " + clearError;
				}
				netherFailed = false;
				netherError = "none";
				netherSessionOverride = true;
				update(mc);
				yield netherFailed ? "err " + netherError : status(mc);
			}
			case "off" -> {
				netherSessionOverride = false;
				if (Level.NETHER.equals(ownedDimension)) clear();
				yield clearPending ? "err DH radius cleanup pending: " + clearError : status(mc);
			}
			default -> "err usage: dhtrial on|off|status|radius <chunks>";
		};
	}

	public static String endCommand(String arg, Minecraft mc) {
		if (arg.startsWith("radius ")) return setRequestedEndRadius(arg.substring(7).strip(), mc);
		return switch (arg) {
			case "status" -> status(mc);
			case "on" -> {
				if (!DH_PRESENT) yield "err DH absent";
				if (clearPending) {
					clear();
					if (clearPending) yield "err DH radius cleanup pending: " + clearError;
				}
				endFailed = false;
				endError = "none";
				endSessionOverride = true;
				update(mc);
				yield endFailed ? "err " + endError : status(mc);
			}
			case "off" -> {
				endSessionOverride = false;
				if (Level.END.equals(ownedDimension)) clear();
				yield clearPending ? "err DH radius cleanup pending: " + clearError : status(mc);
			}
			default -> "err usage: dhend on|off|status";
		};
	}

	private static String setRequestedNetherRadius(String raw, Minecraft mc) {
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
		if (owned && Level.NETHER.equals(ownedDimension) && !clearPending
				&& java.util.Objects.equals(ownedRadius, chunks)) {
			try {
				if (DhAccess.isActive(chunks)) return status(mc);
			} catch (Throwable t) {
				return "err DH radius check: " + t;
			}
		}
		if (clearPending) return "err DH radius cleanup pending: " + clearError;
		if (owned && Level.NETHER.equals(ownedDimension)) {
			clear();
			if (owned || clearPending) return "err DH radius cleanup pending: " + clearError;
		}
		try {
			if (DhAccess.apiValue() != null && !owned) return "err DH radius overridden by another mod";
		} catch (Throwable t) {
			return "err DH radius check: " + t;
		}
		requestedNetherRadius = chunks;
		if (netherControlEnabled() && !netherFailed && !suspended && mc.level != null && Level.NETHER.equals(mc.level.dimension())) {
			update(mc);
			if (netherFailed) return "err " + netherError;
		}
		return status(mc);
	}

	public static String status(Minecraft mc) {
		String dimension = mc.level == null ? "none" : mc.level.dimension().toString();
		String ownerDimension = ownedDimension == null ? "none" : ownedDimension.toString();
		boolean artPackActive = isRequiredArtPackActive();
		String netherSuppressed = netherSuppression(artPackActive);
		String endSuppressed = endSuppression(artPackActive);
		String prefix = "ok enabled=" + netherControlEnabled() + " source=" + controlSource(netherSessionOverride)
				+ " requested=" + requestedNetherRadius + " dhPresent=" + DH_PRESENT
				+ " dimension=" + dimension + " endEnabled=" + endControlEnabled() + " endSource=" + controlSource(endSessionOverride)
				+ " endRequested=" + requestedEndRadius + " autoArt=" + AUTO_ART_RADIUS + " pack=" + REQUIRED_PACK_NAME
				+ " artPackActive=" + artPackActive + " netherSuppressed=" + netherSuppressed + " endSuppressed=" + endSuppressed
				+ " endPack=" + REQUIRED_PACK_NAME + " endPackActive=" + artPackActive
				+ " ownerDimension=" + ownerDimension + " owned=" + owned + " apiOwner=not_exposed" + " suspended=" + suspended
				+ " failed=" + (netherFailed || endFailed) + " netherFailed=" + netherFailed + " endFailed=" + endFailed
				+ " clearPending=" + clearPending + " clearFailures=" + clearFailures
				+ " error=" + netherError + " endError=" + endError + " clearError=" + clearError;
		if (!DH_PRESENT) return prefix + " active=unavailable true=unavailable api=unavailable";
		try {
			if (!DhAccess.ready()) return prefix + " active=initializing true=initializing api=initializing";
			return prefix + " " + DhAccess.status();
		} catch (Throwable t) {
			return "err DH status: " + t;
		}
	}

	private static String netherSuppression(boolean artPackActive) {
		if (suspended) return "suspended";
		if (Boolean.FALSE.equals(netherSessionOverride)) return "session_off";
		if (!AUTO_ART_RADIUS && netherSessionOverride == null) return "auto_disabled";
		if (!artPackActive) return "art_guard";
		return netherFailed ? "failed" : "none";
	}

	private static String endSuppression(boolean artPackActive) {
		if (suspended) return "suspended";
		if (Boolean.FALSE.equals(endSessionOverride)) return "session_off";
		if (!AUTO_ART_RADIUS && endSessionOverride == null) return "auto_disabled";
		if (!artPackActive) return "art_guard";
		return endFailed ? "failed" : "none";
	}

	private static String setRequestedEndRadius(String raw, Minecraft mc) {
		final int chunks;
		try {
			chunks = Integer.parseInt(raw);
		} catch (NumberFormatException e) {
			return "err usage: dhend radius <chunks>";
		}
		if (chunks < MIN_END_RADIUS) return "err End DH radius must be at least " + MIN_END_RADIUS;
		if (!DH_PRESENT) return "err DH absent";
		try {
			if (!DhAccess.ready()) return "err DH configs initializing";
			Integer savedRadius = DhAccess.trueValue();
			if (savedRadius == null) return "err DH saved radius unavailable";
			if (chunks > savedRadius) return "err DH radius exceeds saved radius " + savedRadius;
		} catch (Throwable t) {
			return "err DH radius validation: " + t;
		}
		if (endControlEnabled() && !endFailed && !suspended && Level.END.equals(mc.level == null ? null : mc.level.dimension())
				&& owned && Level.END.equals(ownedDimension) && !clearPending && java.util.Objects.equals(ownedRadius, chunks)) {
			try {
				if (DhAccess.isActive(chunks)) return status(mc);
			} catch (Throwable t) {
				return "err DH radius check: " + t;
			}
		}
		if (clearPending) return "err DH radius cleanup pending: " + clearError;
		if (owned && Level.END.equals(ownedDimension)) {
			clear();
			if (owned || clearPending) return "err DH radius cleanup pending: " + clearError;
		}
		try {
			if (DhAccess.apiValue() != null && !owned) return "err DH radius overridden by another mod";
		} catch (Throwable t) {
			return "err DH radius check: " + t;
		}
		if (chunks == requestedEndRadius) return status(mc);
		requestedEndRadius = chunks;
		if (endControlEnabled() && !endFailed && !suspended && mc.level != null && Level.END.equals(mc.level.dimension())) {
			update(mc);
			if (endFailed) return "err " + endError;
		}
		return status(mc);
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
				String changedValue = String.valueOf(apiValue);
				releaseOwnership();
				BenchCam.LOG.warn("BenchCam did not clear a DH radius API value that differs from its recorded value: {}", changedValue);
				return;
			}
			DhAccess.clear();
			if (DhAccess.apiValue() != null) throw new IllegalStateException("DH radius override remained after clear");
			String oldDimension = ownedDimension.toString();
			releaseOwnership();
		BenchCam.LOG.info("BenchCam DH {} radius override cleared", oldDimension);
		} catch (Throwable t) {
			recordClearFailure(t);
		}
	}

	private static void releaseOwnership() {
		owned = false;
		ownedRadius = null;
		ownedDimension = null;
		clearPending = false;
		clearFailures = 0;
		nextClearRetryNs = 0;
		clearError = "none";
	}

	private static void recordClearFailure(Throwable t) {
		boolean firstFailure = !clearPending;
		if (Level.NETHER.equals(ownedDimension)) {
			netherFailed = true;
			netherError = t.toString().replace(' ', '_');
		} else if (Level.END.equals(ownedDimension)) {
			endFailed = true;
			endError = t.toString().replace(' ', '_');
		}
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

	private static void fail(ResourceKey<Level> dimension, Throwable t) {
		if (Level.NETHER.equals(dimension)) {
			netherFailed = true;
			netherError = t.toString().replace(' ', '_');
		} else {
			endFailed = true;
			endError = t.toString().replace(' ', '_');
		}
		BenchCam.LOG.error("BenchCam DH {} radius trial failed; clearing override", dimension, t);
		clear();
	}

	/** Keep this API link out of the outer class so the adapter does not resolve it before DH is present. */
	private static final class DhAccess {
		private static boolean ready() {
			return com.seibel.distanthorizons.api.DhApi.Delayed.configs != null;
		}

		private static com.seibel.distanthorizons.api.interfaces.config.IDhApiConfigValue<Integer> radius() {
			var configs = com.seibel.distanthorizons.api.DhApi.Delayed.configs;
			if (configs == null) throw new IllegalStateException("DH API configs not initialized");
			return configs.graphics().chunkRenderDistance();
		}

		private static Integer set(int chunks, String dimension, int minRadius) {
			var value = radius();
			if (!value.getCanBeOverrodeByApi()) throw new IllegalStateException("DH radius cannot be overridden");
			if (value.getApiValue() != null) throw new IllegalStateException("DH radius already overridden by another mod");
			Integer savedRadius = value.getTrueValue();
			if (savedRadius == null || chunks < minRadius || chunks > savedRadius)
				throw new IllegalArgumentException("requested DH radius outside [" + minRadius + ", saved radius " + savedRadius + "]");
			if (!value.setValue(chunks, "BenchCam " + dimension + " radius trial")) throw new IllegalStateException("DH rejected radius override");
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

		private static boolean isActive(int chunks) {
			var value = radius();
			return Integer.valueOf(chunks).equals(value.getValue())
					&& Integer.valueOf(chunks).equals(value.getApiValue());
		}

		private static String status() {
			var value = radius();
			return "active=" + value.getValue() + " true=" + value.getTrueValue() + " api=" + value.getApiValue();
		}
	}
}
