package dev.claudebench.benchcam.mixin;

import net.minecraft.world.level.Level;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Save and restore both weather interpolation endpoints, including raw thunder when rain is zero. */
@Mixin(Level.class)
public interface LevelWeatherAccessor {
    @Accessor("rainLevel") float benchcam$getRain();
    @Accessor("oRainLevel") float benchcam$getOldRain();
    @Accessor("thunderLevel") float benchcam$getThunder();
    @Accessor("oThunderLevel") float benchcam$getOldThunder();
    @Accessor("rainLevel") void benchcam$setRain(float value);
    @Accessor("oRainLevel") void benchcam$setOldRain(float value);
    @Accessor("thunderLevel") void benchcam$setThunder(float value);
    @Accessor("oThunderLevel") void benchcam$setOldThunder(float value);
}
