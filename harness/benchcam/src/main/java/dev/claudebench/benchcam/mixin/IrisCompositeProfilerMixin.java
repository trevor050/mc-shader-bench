package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import dev.claudebench.benchcam.GpuPassProfiler;
import net.irisshaders.iris.gl.GLDebug;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** Iris 1.11.4 has one nested debug group around each composite pass. */
@Mixin(targets = "net.irisshaders.iris.pipeline.CompositeRenderer", remap = false)
public abstract class IrisCompositeProfilerMixin {
	// Redirects use order 10000; wrap the already-instrumented body afterward.
	@WrapMethod(method = "renderAll", remap = false, order = 20000)
	private void benchcam$guardRenderAll(Operation<Void> original) {
		boolean completed = false;
		try {
			original.call();
			completed = true;
		} finally {
			GpuPassProfiler.finishCompositeMethod(completed);
		}
	}

	@Redirect(method = "renderAll", at = @At(value = "INVOKE", target = "Lnet/irisshaders/iris/gl/GLDebug;pushGroup(ILjava/lang/String;)V", remap = false), remap = false)
	private void benchcam$pushGroup(int id, String name) {
		GpuPassProfiler.pushCompositeGroup(name);
		GLDebug.pushGroup(id, name);
	}

	@Redirect(method = "renderAll", at = @At(value = "INVOKE", target = "Lnet/irisshaders/iris/gl/GLDebug;popGroup()V", remap = false), remap = false)
	private void benchcam$popGroup() {
		GpuPassProfiler.popCompositeGroup();
		GLDebug.popGroup();
	}
}
