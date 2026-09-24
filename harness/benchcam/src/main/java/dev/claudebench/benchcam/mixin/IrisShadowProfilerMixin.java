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
	@Unique private long benchcam$shadowPhaseToken;
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
			if (!completed || benchcam$shadowPhaseToken != 0 || benchcam$shadowCompositeToken != 0) {
				String reason = completed ? "unbalanced_shadow_group" : "shadow_render_exception";
				GpuPassProfiler.abort(benchcam$shadowPhaseToken, reason);
				GpuPassProfiler.abort(benchcam$shadowCompositeToken, reason);
				benchcam$shadowPhaseToken = 0;
				benchcam$shadowCompositeToken = 0;
			}
		}
	}

	/** After shadow frustum/terrain CPU setup, immediately before the opaque terrain draw path. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lcom/mojang/blaze3d/opengl/GlStateManager;_disableCull()V", remap = false), remap = false)
	private void benchcam$beginShadowDraw(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$shadowPhaseToken = GpuPassProfiler.begin("shadow", "terrain_opaque_callbacks");
	}

	@Unique private void benchcam$nextShadowPhase(String phase) {
		GpuPassProfiler.end(benchcam$shadowPhaseToken);
		benchcam$shadowPhaseToken = GpuPassProfiler.begin("shadow", phase);
	}

	/** The viewport reset is the unique boundary after opaque terrain and optional shadow callbacks. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE", ordinal = 0,
		target = "Lcom/mojang/blaze3d/opengl/GlStateManager;_viewport(IIII)V", remap = false), remap = false, require = 1)
	private void benchcam$beginEntities(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("entities_depth_copy");
	}

	/** The second renderGroup call is translucent terrain; the first is opaque terrain. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE", ordinal = 1,
		target = "Lnet/minecraft/client/renderer/chunk/ChunkSectionsToRender;renderGroup(Lnet/minecraft/client/renderer/chunk/ChunkSectionLayerGroup;Lcom/mojang/blaze3d/textures/GpuSampler;)V", remap = false), remap = false, require = 1)
	private void benchcam$beginTranslucent(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("terrain_translucent");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE", ordinal = 1, shift = At.Shift.AFTER,
		target = "Lnet/minecraft/client/renderer/chunk/ChunkSectionsToRender;renderGroup(Lnet/minecraft/client/renderer/chunk/ChunkSectionLayerGroup;Lcom/mojang/blaze3d/textures/GpuSampler;)V", remap = false), remap = false, require = 1)
	private void benchcam$endTranslucent(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("post_translucent");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;generateMipmaps()V", remap = false), remap = false, require = 1)
	private void benchcam$beginMipmaps(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("mipmaps");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE", shift = At.Shift.AFTER,
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;generateMipmaps()V", remap = false), remap = false, require = 1)
	private void benchcam$endMipmaps(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("restore_state");
	}

	/** Iris has one shadowcomp group after shadow map mipmap generation. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/gl/GLDebug;pushGroup(ILjava/lang/String;)V", remap = false), remap = false)
	private void benchcam$beginShadowComposite(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		GpuPassProfiler.end(benchcam$shadowPhaseToken);
		benchcam$shadowPhaseToken = 0;
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
