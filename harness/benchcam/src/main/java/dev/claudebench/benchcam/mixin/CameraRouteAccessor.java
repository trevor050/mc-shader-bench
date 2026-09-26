package dev.claudebench.benchcam.mixin;

import net.minecraft.client.Camera;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** A pending debug frustum capture also freezes the next route's culling workload. */
@Mixin(Camera.class)
public interface CameraRouteAccessor {
    @Accessor("captureFrustum") boolean benchcam$isFrustumCapturePending();
}
