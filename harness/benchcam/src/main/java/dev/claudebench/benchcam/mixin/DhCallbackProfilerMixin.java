package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import dev.claudebench.benchcam.GpuPassProfiler;
import dev.claudebench.benchcam.MainTerrainDhScope;
import org.spongepowered.asm.mixin.Mixin;

/** Pinned DH 3.3.2 callbacks reached from its renderGroup HEAD injection. */
@Mixin(targets = "com.seibel.distanthorizons.core.api.internal.ClientApi", remap = false)
public abstract class DhCallbackProfilerMixin {
	@WrapMethod(method = "renderLods", remap = false, order = 20000)
	private void benchcam$opaqueLods(Operation<Void> original) {
		if (!GpuPassProfiler.isRecording() || !MainTerrainDhScope.active()) {
			original.call();
			return;
		}
		GpuPassProfiler.beginDh("dh_opaque_callback");
		boolean completed = false;
		try {
			original.call();
			completed = true;
		} finally {
			if (completed) GpuPassProfiler.endDh();
			else GpuPassProfiler.abortDh();
		}
	}

	@WrapMethod(method = "renderDeferredLodsForShaders", remap = false, order = 20000)
	private void benchcam$translucentLods(Operation<Void> original) {
		if (!GpuPassProfiler.isRecording() || !MainTerrainDhScope.active()) {
			original.call();
			return;
		}
		GpuPassProfiler.beginDh("dh_translucent_callback");
		boolean completed = false;
		try {
			original.call();
			completed = true;
		} finally {
			if (completed) GpuPassProfiler.endDh();
			else GpuPassProfiler.abortDh();
		}
	}
}
