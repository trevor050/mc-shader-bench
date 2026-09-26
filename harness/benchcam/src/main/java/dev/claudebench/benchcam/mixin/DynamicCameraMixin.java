package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.DynamicRoutes;
import dev.claudebench.benchcam.RouteMath;
import net.minecraft.client.Camera;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Override alignment before Camera.update builds its culling/projection state, not after extraction. */
@Mixin(Camera.class)
public abstract class DynamicCameraMixin {
    private final RouteMath.Pose benchcam$pose = new RouteMath.Pose();
    @Shadow private boolean detached;
    @Shadow protected abstract void setRotation(float yaw, float pitch);
    @Shadow protected abstract void setPosition(double x, double y, double z);

    @Inject(method = "alignWithEntity(F)V", at = @At("HEAD"), cancellable = true)
    private void benchcam$routeCamera(float partialTicks, CallbackInfo ci) {
        if (!DynamicRoutes.cameraPose(benchcam$pose)) return;
        setRotation((float)benchcam$pose.yaw, (float)benchcam$pose.pitch);
        setPosition(benchcam$pose.x, benchcam$pose.y, benchcam$pose.z);
        detached = false;
        ci.cancel();
    }
}
