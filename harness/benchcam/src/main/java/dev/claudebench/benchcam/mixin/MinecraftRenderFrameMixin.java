package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.FrameTimeStats;
import dev.claudebench.benchcam.GpuPassProfiler;
import dev.claudebench.benchcam.DhNetherRadiusTrial;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Samples Minecraft's recorded frame duration after its renderFrame pass completes. */
@Mixin(Minecraft.class)
public abstract class MinecraftRenderFrameMixin {
	@Inject(method = "renderFrame(Z)V", at = @At("HEAD"))
	private void benchcam$updateDhNetherRadius(boolean advanceGameTime, CallbackInfo ci) {
		DhNetherRadiusTrial.update((Minecraft) (Object) this);
	}

	@Inject(method = "renderFrame(Z)V", at = @At("TAIL"))
	private void benchcam$recordFrameTime(boolean advanceGameTime, CallbackInfo ci) {
		FrameTimeStats.record(((Minecraft) (Object) this).getFrameTimeNs());
		GpuPassProfiler.poll();
	}
}
