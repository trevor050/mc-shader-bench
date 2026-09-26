package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.DynamicRoutes;
import net.minecraft.client.player.LocalPlayer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Integrated server owns the route player; suppress stale normal movement packets during that interval. */
@Mixin(LocalPlayer.class)
public abstract class DynamicLocalPlayerMixin {
    @Inject(method = "sendPosition()V", at = @At("HEAD"), cancellable = true)
    private void benchcam$routeOwnsPosition(CallbackInfo ci) {
        if (DynamicRoutes.controlsActive()) ci.cancel();
    }
}
