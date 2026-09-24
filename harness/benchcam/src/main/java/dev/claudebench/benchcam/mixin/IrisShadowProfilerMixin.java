package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import dev.claudebench.benchcam.GpuPassProfiler;
import net.irisshaders.iris.mixin.LevelRendererAccessor;
import net.minecraft.client.Camera;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Non-overlapping timers around Iris 1.11.4's shadow drawing and shadowcomp. */
@Mixin(targets = "net.irisshaders.iris.shadows.ShadowRenderer", remap = false)
public abstract class IrisShadowProfilerMixin {
	@Unique private long benchcam$shadowDrawToken;
	@Unique private long benchcam$shadowCompositeToken;

	// The three injections run first; the wrapper catches exceptions and changed normal exits.
	@WrapMethod(method = "renderShadows", remap = false, order = 20000)
	private void benchcam$guardRenderShadows(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, Operation<Void> original) {
		boolean completed = false;
		try {
			original.call(levelRenderer, playerCamera, renderState);
			completed = true;
		} finally {
			if (!completed || benchcam$shadowDrawToken != 0 || benchcam$shadowCompositeToken != 0) {
				String reason = completed ? "unbalanced_shadow_group" : "shadow_render_exception";
				GpuPassProfiler.abort(benchcam$shadowDrawToken, reason);
				GpuPassProfiler.abort(benchcam$shadowCompositeToken, reason);
				benchcam$shadowDrawToken = 0;
				benchcam$shadowCompositeToken = 0;
			}
		}
	}

	/** After shadow frustum/terrain CPU setup, immediately before the opaque terrain draw path. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lcom/mojang/blaze3d/opengl/GlStateManager;_disableCull()V", remap = false), remap = false)
	private void benchcam$beginShadowDraw(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$shadowDrawToken = GpuPassProfiler.begin("shadow", "draw_mips");
	}

	/** Iris has one shadowcomp group after shadow map mipmap generation. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/gl/GLDebug;pushGroup(ILjava/lang/String;)V", remap = false), remap = false)
	private void benchcam$beginShadowComposite(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		GpuPassProfiler.end(benchcam$shadowDrawToken);
		benchcam$shadowDrawToken = 0;
		benchcam$shadowCompositeToken = GpuPassProfiler.begin("shadow", "shadowcomp");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/gl/GLDebug;popGroup()V", remap = false), remap = false)
	private void benchcam$endShadowComposite(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		GpuPassProfiler.end(benchcam$shadowCompositeToken);
		benchcam$shadowCompositeToken = 0;
	}
}
