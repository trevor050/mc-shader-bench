package dev.claudebench.benchcam;

/** Render-thread scope for DH calls made by the main terrain framegraph callback. */
public final class MainTerrainDhScope {
	private static final ThreadLocal<Boolean> ACTIVE = new ThreadLocal<>();

	private MainTerrainDhScope() {}

	public static void enter() { ACTIVE.set(Boolean.TRUE); }
	public static void exit() { ACTIVE.remove(); }
	public static boolean active() { return Boolean.TRUE.equals(ACTIVE.get()); }
}
