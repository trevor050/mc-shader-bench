package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.ShadowFeaturePhaseScope;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Counts submitted node references handed to each executed PreparedGroup. */
@Mixin(targets = "net.minecraft.client.renderer.feature.FeatureRenderDispatcher$PreparedGroup")
public abstract class ShadowFeatureGroupCountMixin {
	@Shadow @Final private int fromInclusive;
	@Shadow private int toInclusive;

	@Inject(method = "execute", at = @At("HEAD"), require = 1)
	private void benchcam$countNodes(CallbackInfo ci) {
		ShadowFeaturePhaseScope.addNodes(toInclusive - fromInclusive + 1);
	}
}
