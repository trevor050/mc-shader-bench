package dev.claudebench.benchcam.mixin;

import net.minecraft.client.Options;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Reads the server-provided view-distance cap for BenchCam's runtime status. */
@Mixin(Options.class)
public interface OptionsServerRenderDistanceAccessor {
	@Accessor("serverRenderDistance")
	int benchcam$getServerRenderDistance();
}
