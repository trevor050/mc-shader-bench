package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import dev.claudebench.benchcam.GpuPassProfiler;
import net.irisshaders.iris.gl.GLDebug;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

@Mixin(targets = "net.irisshaders.iris.pipeline.FinalPassRenderer", remap = false)
public abstract class IrisFinalProfilerMixin {
	@Unique private long benchcam$finalToken;

	// Redirects use order 10000; wrap the already-instrumented body afterward.
	@WrapMethod(method = "renderFinalPass", remap = false, order = 20000)
	private void benchcam$guardRenderFinalPass(Operation<Void> original) {
		boolean completed = false;
		try {
			original.call();
			completed = true;
		} finally {
			if (!completed || benchcam$finalToken != 0) {
				GpuPassProfiler.abort(benchcam$finalToken,
					completed ? "unbalanced_final_group" : "final_render_exception");
				benchcam$finalToken = 0;
			}
		}
	}

	@Redirect(method = "renderFinalPass", at = @At(value = "INVOKE", target = "Lnet/irisshaders/iris/gl/GLDebug;pushGroup(ILjava/lang/String;)V", remap = false), remap = false)
	private void benchcam$pushGroup(int id, String name) {
		benchcam$finalToken = GpuPassProfiler.begin("final", name);
		GLDebug.pushGroup(id, name);
	}

	@Redirect(method = "renderFinalPass", at = @At(value = "INVOKE", target = "Lnet/irisshaders/iris/gl/GLDebug;popGroup()V", remap = false), remap = false)
	private void benchcam$popGroup() {
		GpuPassProfiler.end(benchcam$finalToken);
		benchcam$finalToken = 0;
		GLDebug.popGroup();
	}
}
