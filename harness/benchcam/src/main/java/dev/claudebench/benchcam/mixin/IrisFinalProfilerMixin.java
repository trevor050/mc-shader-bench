package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.GpuPassProfiler;
import net.irisshaders.iris.gl.GLDebug;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

@Mixin(targets = "net.irisshaders.iris.pipeline.FinalPassRenderer", remap = false)
public abstract class IrisFinalProfilerMixin {
	@Redirect(method = "renderFinalPass", at = @At(value = "INVOKE", target = "Lnet/irisshaders/iris/gl/GLDebug;pushGroup(ILjava/lang/String;)V", remap = false), remap = false)
	private void benchcam$pushGroup(int id, String name) {
		GpuPassProfiler.begin("final", name);
		GLDebug.pushGroup(id, name);
	}

	@Redirect(method = "renderFinalPass", at = @At(value = "INVOKE", target = "Lnet/irisshaders/iris/gl/GLDebug;popGroup()V", remap = false), remap = false)
	private void benchcam$popGroup() {
		GpuPassProfiler.end();
		GLDebug.popGroup();
	}
}
