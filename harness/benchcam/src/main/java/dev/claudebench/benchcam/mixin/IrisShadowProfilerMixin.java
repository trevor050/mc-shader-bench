package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import com.llamalad7.mixinextras.injector.wrapoperation.WrapOperation;
import dev.claudebench.benchcam.GpuPassProfiler;
import dev.claudebench.benchcam.ShadowFeaturePhaseScope;
import net.irisshaders.iris.mixin.LevelRendererAccessor;
import net.minecraft.client.Camera;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.SubmitNodeStorage;
import net.minecraft.client.renderer.feature.FeatureRenderDispatcher;
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
		target = "Lcom/mojang/blaze3d/opengl/GlStateManager;_disableCull()V", remap = false), remap = false, require = 1)
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
		benchcam$nextShadowPhase("entity_setup_extract");
	}

	/** Entity and block-entity submit methods populate render nodes; feature rendering draws them later. */
	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;renderEntities(Lnet/irisshaders/iris/mixin/LevelRendererAccessor;Lnet/minecraft/client/renderer/entity/EntityRenderDispatcher;Lcom/mojang/blaze3d/vertex/PoseStack;FLnet/minecraft/client/renderer/culling/Frustum;DDD)I", remap = false), remap = false, require = 1)
	private void benchcam$beginEntitySubmit(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("entity_submit");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE", shift = At.Shift.AFTER,
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;renderEntities(Lnet/irisshaders/iris/mixin/LevelRendererAccessor;Lnet/minecraft/client/renderer/entity/EntityRenderDispatcher;Lcom/mojang/blaze3d/vertex/PoseStack;FLnet/minecraft/client/renderer/culling/Frustum;DDD)I", remap = false), remap = false, require = 1)
	private void benchcam$beginBlockEntityExtract(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("block_entity_extract");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;renderBlockEntities(Lnet/irisshaders/iris/mixin/LevelRendererAccessor;Lcom/mojang/blaze3d/vertex/PoseStack;Lnet/minecraft/client/renderer/SubmitNodeStorage;Lnet/minecraft/client/renderer/state/level/LevelRenderState;Lnet/minecraft/client/Camera;)I", remap = false), remap = false, require = 1)
	private void benchcam$beginBlockEntitySubmit(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("block_entity_submit");
	}

	/** Scope the vanilla dispatcher hooks to Iris's shadow call only. The guard above handles exceptions. */
	@WrapOperation(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/feature/FeatureRenderDispatcher;renderAllFeatures(Lnet/minecraft/client/renderer/SubmitNodeStorage;)V", remap = false),
		remap = false, require = 1)
	private void benchcam$profileShadowFeatures(FeatureRenderDispatcher dispatcher, SubmitNodeStorage storage,
			Operation<Void> original) {
		benchcam$nextShadowPhase("feature_prepare_frame");
		ShadowFeaturePhaseScope.enter(this::benchcam$nextShadowPhase);
		try {
			original.call(dispatcher, storage);
		} finally {
			ShadowFeaturePhaseScope.exit();
		}
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/RenderBuffers;endFrame()V", remap = false), remap = false, require = 1)
	private void benchcam$beginBufferFlush(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("buffer_end_frame");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;copyPreTranslucentDepth(Lnet/irisshaders/iris/mixin/LevelRendererAccessor;)V", remap = false), remap = false, require = 1)
	private void benchcam$beginDepthCopy(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("depth_copy");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE", shift = At.Shift.AFTER,
		target = "Lnet/irisshaders/iris/shadows/ShadowRenderer;copyPreTranslucentDepth(Lnet/irisshaders/iris/mixin/LevelRendererAccessor;)V", remap = false), remap = false, require = 1)
	private void benchcam$endDepthCopy(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		benchcam$nextShadowPhase("translucent_setup");
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
		target = "Lnet/irisshaders/iris/gl/GLDebug;pushGroup(ILjava/lang/String;)V", remap = false), remap = false, require = 1)
	private void benchcam$beginShadowComposite(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		GpuPassProfiler.end(benchcam$shadowPhaseToken);
		benchcam$shadowPhaseToken = 0;
		benchcam$shadowCompositeToken = GpuPassProfiler.begin("shadow", "shadowcomp");
	}

	@Inject(method = "renderShadows", at = @At(value = "INVOKE",
		target = "Lnet/irisshaders/iris/gl/GLDebug;popGroup()V", remap = false), remap = false, require = 1)
	private void benchcam$endShadowComposite(LevelRendererAccessor levelRenderer, Camera playerCamera,
			CameraRenderState renderState, CallbackInfo ci) {
		GpuPassProfiler.end(benchcam$shadowCompositeToken);
		benchcam$shadowCompositeToken = 0;
	}
}
