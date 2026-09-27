package dev.afterglow.clientfixes.mixin;

import dev.afterglow.clientfixes.GuiQueueGuard;
import dev.afterglow.clientfixes.QueuePolicy;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(targets = "com.mojang.blaze3d.opengl.GlCommandEncoder", remap = false)
public abstract class GlCommandEncoderMixin {
    @Shadow public abstract long currentSubmitIndex();
    @Shadow public abstract boolean awaitSubmit(long index, long timeoutNS);

    @Inject(method = "submit", at = @At("TAIL"), require = 1)
    private void afterglow$completeGuiFrame(CallbackInfo ci) {
        if (!GuiQueueGuard.shouldWait()) return;
        // submit() has incremented the index and waited for index-2. Index-1 is this frame's
        // existing fence. Awaiting it does not add a fence, alter transient-memory rotation,
        // or wait forever. A timeout leaves the fence intact for vanilla's next submit.
        long startNs = System.nanoTime();
        try {
            boolean completed = awaitSubmit(QueuePolicy.submittedFrameIndex(currentSubmitIndex()), GuiQueueGuard.timeoutNs());
            GuiQueueGuard.recordWait(System.nanoTime() - startNs, completed);
        } catch (RuntimeException ex) {
            GuiQueueGuard.fail(ex);
        }
    }
}
