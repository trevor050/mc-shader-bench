package dev.claudebench.benchcam.mixin;

import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import com.llamalad7.mixinextras.injector.wrapoperation.WrapOperation;
import com.mojang.blaze3d.textures.GpuSampler;
import dev.claudebench.benchcam.GpuPassProfiler;
import dev.claudebench.benchcam.MainTerrainDhScope;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.chunk.ChunkSectionLayerGroup;
import net.minecraft.client.renderer.chunk.ChunkSectionsToRender;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;

/** Both pinned main-pass renderGroup calls; Iris shadow calls use a different caller. */
@Mixin(LevelRenderer.class)
public abstract class MainTerrainDhScopeMixin {
	@WrapOperation(method = "lambda$addMainPass$0", at = @At(value = "INVOKE",
		target = "Lnet/minecraft/client/renderer/chunk/ChunkSectionsToRender;renderGroup(Lnet/minecraft/client/renderer/chunk/ChunkSectionLayerGroup;Lcom/mojang/blaze3d/textures/GpuSampler;)V"), require = 2)
	private void benchcam$mainTerrainGroup(ChunkSectionsToRender sections, ChunkSectionLayerGroup group,
			GpuSampler sampler, Operation<Void> original) {
		if (!GpuPassProfiler.isRecording()) {
			original.call(sections, group, sampler);
			return;
		}
		String pass = group == ChunkSectionLayerGroup.OPAQUE ? "main_opaque_group"
			: group == ChunkSectionLayerGroup.TRANSLUCENT ? "main_translucent_group" : null;
		if (pass == null) {
			original.call(sections, group, sampler);
			return;
		}
		GpuPassProfiler.beginMainGroup(pass);
		MainTerrainDhScope.enter();
		boolean completed = false;
		try {
			original.call(sections, group, sampler);
			completed = true;
		} finally {
			MainTerrainDhScope.exit();
			if (completed) GpuPassProfiler.endMainGroup();
			else GpuPassProfiler.abortMainGroup();
		}
	}
}
