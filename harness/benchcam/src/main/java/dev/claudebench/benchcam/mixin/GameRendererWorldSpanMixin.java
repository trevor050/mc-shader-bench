package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import dev.claudebench.benchcam.GpuPassProfiler;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Mixin;

/** Brackets the world render with timestamp markers; elapsed pass queries remain independent. */
@Mixin(GameRenderer.class)
public abstract class GameRendererWorldSpanMixin {
	@WrapMethod(method = "renderLevel(Lnet/minecraft/client/DeltaTracker;)V", order = 20000)
	private void benchcam$measureWorldRender(DeltaTracker deltaTracker, Operation<Void> original) {
		GpuPassProfiler.beginRenderLevel();
		boolean completed = false;
		try {
			original.call(deltaTracker);
			completed = true;
		} finally {
			if (completed) GpuPassProfiler.endRenderLevel();
			else GpuPassProfiler.abortRenderLevel();
		}
	}
}
