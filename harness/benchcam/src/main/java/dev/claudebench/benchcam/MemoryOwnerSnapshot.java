package dev.claudebench.benchcam;

import com.seibel.distanthorizons.common.render.openGl.glObject.buffer.GLBuffer;
import dev.claudebench.benchcam.mixin.SodiumWorldRendererAccessor;
import java.lang.management.BufferPoolMXBean;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.MemoryUsage;
import java.util.List;
import net.caffeinemc.mods.sodium.client.gpu.arena.ArenaAggregator;
import net.caffeinemc.mods.sodium.client.render.SodiumWorldRenderer;
import net.caffeinemc.mods.sodium.client.render.chunk.RenderSectionManager;
import net.minecraft.client.Minecraft;

/** On-demand storage accounting. These are Java/GL object sizes, never resident VRAM bytes. */
public final class MemoryOwnerSnapshot {
	private static final MemoryMXBean MEMORY = ManagementFactory.getMemoryMXBean();
	private static final List<GarbageCollectorMXBean> GCS = ManagementFactory.getGarbageCollectorMXBeans();
	private static final List<BufferPoolMXBean> BUFFER_POOLS = ManagementFactory.getPlatformMXBeans(BufferPoolMXBean.class);
	private static long previousGcCount = -1;
	private static long previousGcMs = -1;

	private MemoryOwnerSnapshot() {}

	/** Invoked by the explicit BenchCam command on the render thread, never per frame. */
	public static String command(String arg, Minecraft mc) {
		if (!arg.isEmpty()) return "err usage: memowners";
		long nowMs = System.currentTimeMillis();
		MemoryUsage heap = MEMORY.getHeapMemoryUsage();
		long gcCount = 0;
		long gcMs = 0;
		for (GarbageCollectorMXBean bean : GCS) {
			long count = bean.getCollectionCount();
			long time = bean.getCollectionTime();
			if (count >= 0) gcCount += count;
			if (time >= 0) gcMs += time;
		}
		long gcDeltaCount = previousGcCount < 0 ? -1 : gcCount - previousGcCount;
		long gcDeltaMs = previousGcMs < 0 ? -1 : gcMs - previousGcMs;
		previousGcCount = gcCount;
		previousGcMs = gcMs;
		long directBytes = -1;
		for (BufferPoolMXBean pool : BUFFER_POOLS) {
			if (pool.getName().equals("direct")) {
				directBytes = pool.getMemoryUsed();
				break;
			}
		}

		DhBufferLedger.Snapshot dh = DhBufferLedger.snapshot();

		StringBuilder out = new StringBuilder(360);
		out.append("ok ts_ms=").append(nowMs);
		out.append(" dh_tracking=").append(dh.enabled() ? "on" : "off");
		out.append(" dh_buffer_storage_bytes=").append(dh.enabled() ? Long.toString(dh.bytes()) : "na");
		out.append(" dh_buffer_count=").append(dh.enabled() ? Integer.toString(dh.count()) : "na");
		// Avoid initializing DH's GLBuffer cleanup thread from a menu-only diagnostic.
		out.append(" dh_glbuffer_count=").append(mc.level == null ? "na" : Integer.toString(GLBuffer.bufferCount.get()));

		SodiumWorldRenderer renderer = mc.level == null ? null : SodiumWorldRenderer.instanceNullable();
		RenderSectionManager sections = renderer == null ? null : ((SodiumWorldRendererAccessor) renderer).benchcam$getRenderSectionManager();
		ArenaAggregator arena = sections == null || sections.regions == null ? null : sections.regions.getArenaAggregator();
		if (arena == null) {
			out.append(" sodium_state=unavailable");
		} else {
			long geometryAllocated = arena.getGeometryDeviceAllocatedMemory();
			long indexAllocated = arena.getIndexDeviceAllocatedMemory();
			long cachedAllocated = arena.getMiscAllocatedMemory();
			out.append(" sodium_state=ready");
			out.append(" sodium_arena_alloc_bytes=").append(geometryAllocated + indexAllocated + cachedAllocated);
			out.append(" sodium_arena_used_bytes=").append(arena.getGeometryDeviceUsedMemory() + arena.getIndexDeviceUsedMemory());
			out.append(" sodium_cached_bytes=").append(cachedAllocated);
			out.append(" sodium_buffer_count=").append(arena.getBufferCount());
		}
		out.append(" heap_used_bytes=").append(heap.getUsed());
		out.append(" heap_committed_bytes=").append(heap.getCommitted());
		out.append(" jvm_direct_bytes=").append(directBytes);
		out.append(" gc_count=").append(gcCount);
		out.append(" gc_time_ms=").append(gcMs);
		out.append(" gc_delta_count=").append(gcDeltaCount);
		out.append(" gc_delta_ms=").append(gcDeltaMs);
		return out.toString();
	}
}
