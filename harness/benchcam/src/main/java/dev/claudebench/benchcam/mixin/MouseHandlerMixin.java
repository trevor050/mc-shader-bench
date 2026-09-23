package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.BenchCam;
import net.minecraft.client.MouseHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Keeps the game from capturing and clipping the OS cursor while it runs unattended. */
@Mixin(MouseHandler.class)
public abstract class MouseHandlerMixin {
	@Inject(method = "grabMouse", at = @At("HEAD"), cancellable = true)
	private void benchcam$blockGrab(CallbackInfo ci) {
		if (!BenchCam.allowMouseGrab) ci.cancel();
	}
}
