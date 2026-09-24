package dev.claudebench.benchcam.mixin;

import dev.claudebench.benchcam.DhBufferLedger;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.nio.ByteBuffer;

/** Pinned DH 3.3.2 storage and final-delete hooks; no GL queries or per-frame work. */
@Mixin(targets = "com.seibel.distanthorizons.common.render.openGl.glObject.buffer.GLBuffer", remap = false)
public abstract class DhBufferMemoryMixin {
	@Shadow(remap = false) public abstract int getId();
	@Shadow(remap = false) public abstract int getSize();

	@Inject(method = "uploadBufferStorage(Ljava/nio/ByteBuffer;)V", at = @At("RETURN"), remap = false)
	private void benchcam$storage(ByteBuffer data, CallbackInfo ci) {
		DhBufferLedger.record(getId(), getSize());
	}

	@Inject(method = "uploadBufferData(Ljava/nio/ByteBuffer;I)V", at = @At("RETURN"), remap = false)
	private void benchcam$data(ByteBuffer data, int usage, CallbackInfo ci) {
		DhBufferLedger.record(getId(), getSize());
	}

	@Inject(method = "uploadSubData(Ljava/nio/ByteBuffer;II)V", at = @At("RETURN"), remap = false)
	private void benchcam$subData(ByteBuffer data, int offset, int usage, CallbackInfo ci) {
		DhBufferLedger.record(getId(), getSize());
	}

	@Inject(method = "destroyBufferIdNow(ILjava/lang/String;)V", at = @At("RETURN"), remap = false)
	private static void benchcam$deleted(int id, String reason, CallbackInfo ci) {
		DhBufferLedger.forget(id);
	}
}
