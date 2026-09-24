package dev.claudebench.benchcam.mixin;

import net.caffeinemc.mods.sodium.client.render.SodiumWorldRenderer;
import net.caffeinemc.mods.sodium.client.render.chunk.RenderSectionManager;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Pinned Sodium 0.9.2 path to its existing arena accounting getters. */
@Mixin(value = SodiumWorldRenderer.class, remap = false)
public interface SodiumWorldRendererAccessor {
	@Accessor(value = "renderSectionManager", remap = false)
	RenderSectionManager benchcam$getRenderSectionManager();
}
