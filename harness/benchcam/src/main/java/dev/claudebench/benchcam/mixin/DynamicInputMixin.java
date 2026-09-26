package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.DynamicRoutes;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Prevent attack/use/drop/game-mode input from editing the scene while route control is active. */
@Mixin(Minecraft.class)
public abstract class DynamicInputMixin {
    @Inject(method = "handleKeybinds()V", at = @At("HEAD"), cancellable = true)
    private void benchcam$routeInput(CallbackInfo ci) {
        if (DynamicRoutes.controlsActive()) ci.cancel();
    }
}
