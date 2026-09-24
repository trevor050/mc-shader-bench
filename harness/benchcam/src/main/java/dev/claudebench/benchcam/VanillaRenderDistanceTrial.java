package dev.claudebench.benchcam;

import net.minecraft.client.Minecraft;
import net.minecraft.client.GraphicsPreset;
import dev.claudebench.benchcam.mixin.OptionsServerRenderDistanceAccessor;

/** Runtime-only 24/32 vanilla render-distance trial. */
public final class VanillaRenderDistanceTrial {
	private static boolean active;
	private static int originalRenderDistance = -1;
	private static int targetRenderDistance = -1;
	private static GraphicsPreset originalGraphicsPreset;

	private VanillaRenderDistanceTrial() {}

	public static String command(String arg, Minecraft mc) {
		return switch (arg) {
			case "status" -> status(mc);
			case "restore", "off" -> restore(mc, true, "command");
			case "24", "32" -> setTarget(Integer.parseInt(arg), mc);
			default -> "err usage: rdtrial 24|32|restore|status";
		};
	}

	private static String setTarget(int target, Minecraft mc) {
		if (mc.player == null || mc.level == null) return "err not in world";
		int current = mc.options.renderDistance().get();
		if (active && targetRenderDistance == target && current == target) return status(mc);
		if (!active && current == target) return status(mc);

		if (!active) {
			if (mc.options.graphicsPreset().get() != GraphicsPreset.CUSTOM)
				return "err rdtrial requires graphics preset CUSTOM to preserve other preset-managed options";
			originalRenderDistance = current;
			originalGraphicsPreset = mc.options.graphicsPreset().get();
		}
		active = true;
		targetRenderDistance = target;
		try {
			applyRenderDistance(mc, target);
			return status(mc);
		} catch (Throwable t) {
			String failure = t.toString().replace(' ', '_');
			BenchCam.LOG.error("BenchCam vanilla render-distance trial failed; restoring saved options", t);
			String cleanup = restore(mc, true, "failure:" + failure);
			return "err trial failed: " + failure + " " + cleanup;
		}
	}

	private static void applyRenderDistance(Minecraft mc, int value) {
		mc.options.renderDistance().set(value);
		// LevelExtractor checks for this value on the next frame too; call explicitly so runtime API users and
		// the options screen follow the same complete terrain rebuild path without waiting for that check.
		mc.levelExtractor.allChanged();
		// Options.save() would persist the temporary trial value. Broadcast the same client-information packet
		// path used by Options.save() without writing options.txt.
		mc.options.broadcastOptions();
		if (mc.options.renderDistance().get() != value)
			throw new IllegalStateException("render-distance option readback mismatch");
	}

	/** Restore on explicit request, disconnect, or normal client shutdown. */
	public static String restore(Minecraft mc, boolean persist, String reason) {
		if (!active) return status(mc);
		int restoreDistance = originalRenderDistance;
		GraphicsPreset restorePreset = originalGraphicsPreset;
		try {
			mc.options.renderDistance().set(restoreDistance);
			if (restorePreset != null) mc.options.graphicsPreset().set(restorePreset);
			if (mc.level != null) mc.levelExtractor.allChanged();
			if (persist) {
				// Persist the original value and preset, and use Options' normal client-info broadcast on restore.
				mc.options.save();
			} else {
				mc.options.broadcastOptions();
			}
			if (mc.options.renderDistance().get() != restoreDistance)
				throw new IllegalStateException("render-distance restore readback mismatch");
			BenchCam.LOG.info("BenchCam vanilla render-distance trial restored to {} chunks ({})", restoreDistance, reason);
			active = false;
			targetRenderDistance = -1;
			originalRenderDistance = -1;
			originalGraphicsPreset = null;
		} catch (Throwable t) {
			BenchCam.LOG.error("BenchCam vanilla render-distance restore failed ({})", reason, t);
			return "err restore failed: " + t.toString().replace(' ', '_') + " " + status(mc);
		}
		return status(mc);
	}

	public static void disconnect(Minecraft mc) {
		restore(mc, true, "disconnect");
	}

	public static void clientStopping(Minecraft mc) {
		restore(mc, true, "client-stopping");
	}

	public static String status(Minecraft mc) {
		String preset = mc.options.graphicsPreset().get().getSerializedName();
		String originalPreset = originalGraphicsPreset == null ? "none" : originalGraphicsPreset.getSerializedName();
		int current = mc.options.renderDistance().get();
		int effective = mc.options.getEffectiveRenderDistance();
		int serverCap = ((OptionsServerRenderDistanceAccessor) mc.options).benchcam$getServerRenderDistance();
		return "ok active=" + active
			+ " original=" + (active ? originalRenderDistance : "none")
			+ " target=" + (active ? targetRenderDistance : "none")
			+ " current=" + current
			+ " effective=" + effective
			+ " serverCap=" + (serverCap > 0 ? serverCap : "none")
			+ " serverClamp=" + (effective < current)
			+ " preset=" + preset
			+ " originalPreset=" + originalPreset;
	}
}
