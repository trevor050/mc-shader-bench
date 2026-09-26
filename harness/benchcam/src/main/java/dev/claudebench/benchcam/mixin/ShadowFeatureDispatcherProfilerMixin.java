package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.ShadowFeaturePhaseScope;
import net.minecraft.client.renderer.SubmitNodeStorage;
import net.minecraft.client.renderer.feature.FeatureRenderDispatcher;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Six sequential intervals within Iris's shadow feature-render call on Minecraft 26.2. */
@Mixin(FeatureRenderDispatcher.class)
public abstract class ShadowFeatureDispatcherProfilerMixin {
	@Inject(method = "renderAllFeatures", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/feature/FeatureRenderDispatcher$PreparedFrame;executeSolid()V"), require = 1)
	private void benchcam$solid(SubmitNodeStorage storage, CallbackInfo ci) {
		ShadowFeaturePhaseScope.next("feature_solid");
	}

	@Inject(method = "renderAllFeatures", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/feature/FeatureRenderDispatcher$PreparedFrame;executeTranslucent()V"), require = 1)
	private void benchcam$translucent(SubmitNodeStorage storage, CallbackInfo ci) {
		ShadowFeaturePhaseScope.next("feature_translucent");
	}

	@Inject(method = "renderAllFeatures", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/feature/FeatureRenderDispatcher$PreparedFrame;executeTranslucentAfterTerrain()V"), require = 1)
	private void benchcam$afterTerrain(SubmitNodeStorage storage, CallbackInfo ci) {
		ShadowFeaturePhaseScope.next("feature_after_terrain");
	}

	@Inject(method = "renderAllFeatures", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/feature/FeatureRenderDispatcher$PreparedFrame;executeAlwaysOnTop()V"), require = 1)
	private void benchcam$alwaysOnTop(SubmitNodeStorage storage, CallbackInfo ci) {
		ShadowFeaturePhaseScope.next("feature_always_on_top");
	}

	// renderAllFeatures also has a second close invocation in its exceptional cleanup path.
	@Inject(method = "renderAllFeatures", at = @At(value = "INVOKE", ordinal = 0,
		target = "Lnet/minecraft/client/renderer/feature/FeatureRenderDispatcher$PreparedFrame;close()V"), require = 1)
	private void benchcam$close(SubmitNodeStorage storage, CallbackInfo ci) {
		ShadowFeaturePhaseScope.next("feature_close");
	}
}
