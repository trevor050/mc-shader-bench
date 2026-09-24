package dev.claudebench.ambience;

import java.util.ArrayList;
import java.util.List;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.resources.sounds.AbstractTickableSoundInstance;
import net.minecraft.client.resources.sounds.SimpleSoundInstance;
import net.minecraft.client.resources.sounds.SoundInstance;
import net.minecraft.resources.Identifier;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.boss.enderdragon.EnderDragon;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;

/**
 * The End's storm, as sound. Layered loops (wind drone, sweeping howls, sub rumble, an alien choir, and AmbientSounds'
 * recorded heavy wind and storm when that mod is installed) whose volume follows a storm intensity that rises during
 * the dragon fight, with altitude and with speed. Lightning is decided here and handed to the shaderpack through the
 * End's unused weather values (rain level = bolt direction code, thunder level = flash brightness; the shader reads
 * them as Iris's rainStrength/thunderStrength), so every flash the player sees has a thunderclap that arrives after
 * the delay its distance implies.
 */
public final class StormAmbience implements ClientModInitializer {
	private static final Vec3 VORTEX = new Vec3(0.0, 100.0, 0.0);
	private static final double EYE_RADIUS = 250.0;

	private final List<Loop> loops = new ArrayList<>();
	private final List<PendingThunder> pending = new ArrayList<>();
	private final RandomSource random = RandomSource.create();
	private boolean active;
	private float intensity;
	private int boltAge = -1;
	private float boltCode = 0.5F;
	private float boltSeed;
	private float howlAngle;
	private long ticks;
	// Gusts: discrete events with a sharp attack and a longer decay, over a turbulent base.
	private float gustLevel;
	private float gustPeak;
	private int gustAge = -1;
	private int gustAttack, gustDecay, nextGust = 40;
	// Camera sway (trauma model): the last offset applied, so only the change is added each tick.
	private float swayYaw, swayPitch;

	private record PendingThunder(long dueTick, Vec3 pos, double distance) {}

	@Override
	public void onInitializeClient() {
		ClientTickEvents.END_CLIENT_TICK.register(this::tick);
	}

	private static SoundEvent event(String namespace, String path) {
		return SoundEvent.createVariableRangeEvent(Identifier.fromNamespaceAndPath(namespace, path));
	}

	private void tick(Minecraft mc) {
		ClientLevel level = mc.level;
		Player player = mc.player;
		if (level == null || player == null || level.dimension() != Level.END || mc.isPaused()) {
			if (active && (level == null || level.dimension() != Level.END)) stopAll(level);
			return;
		}
		ticks++;
		if (!active) startAll(mc);
		active = true;

		// Storm intensity: calm-ish in the eye, raging while the dragon lives, harder high up and at speed.
		boolean dragon = false;
		for (Entity e : level.entitiesForRendering()) {
			if (e instanceof EnderDragon d && d.isAlive() && d.distanceTo(player) < 350.0F) { dragon = true; break; }
		}
		double altitude = Math.max(player.getY() - 60.0, 0.0);
		double speed = player.getDeltaMovement().length() * 20.0;
		float target = 0.5F + (dragon ? 0.5F : 0.0F) + (float) Math.min(altitude / 400.0, 0.1) + (float) Math.min(speed / 60.0, 0.15);
		target = Math.min(target, 1.0F);
		intensity += (target - intensity) * 0.02F;

		float gust = updateGust(dragon);
		howlAngle += 0.012F + 0.02F * intensity;
		for (Loop l : loops) {
			if (!mc.getSoundManager().isActive(l)) mc.getSoundManager().play(l);
			l.update(intensity, gust, howlAngle);
		}

		updateLightning(mc, level, player, dragon, gust);
		buffet(player, gust);
	}

	/**
	 * Gust envelope, 0..1. Events arrive every 2-7 s (more often in the fight): a 0.3-0.6 s attack to a random
	 * peak, then a 1.5-3.5 s decay, on top of a light turbulent flutter. The same value drives the sound, the
	 * shove and (via the thunder channel) the shader's camera effects, so what you hear and see hits together.
	 */
	private float updateGust(boolean dragon) {
		if (gustAge < 0 && --nextGust <= 0) {
			gustAge = 0;
			gustAttack = 6 + random.nextInt(7);
			gustDecay = 30 + random.nextInt(40);
			gustPeak = 0.55F + 0.45F * random.nextFloat();
			nextGust = (dragon ? 30 : 50) + random.nextInt(dragon ? 60 : 90);
		}
		float env = 0.0F;
		if (gustAge >= 0) {
			if (gustAge < gustAttack) env = (float) gustAge / gustAttack;
			else env = (float) Math.exp(-(gustAge - gustAttack) / (gustDecay * 0.45));
			env *= gustPeak;
			if (++gustAge > gustAttack + gustDecay * 2) gustAge = -1;
		}
		float flutter = (float) (0.12 * (Math.sin(ticks * 0.37) * Math.sin(ticks * 0.23 + 2.1) + 1.0));
		float target = Math.min(1.0F, env + flutter * 0.5F);
		gustLevel += (target - gustLevel) * 0.35F;
		return gustLevel;
	}

	/** The gale shoves you: gusts push along the vortex's spin and jolt your view, harder while the dragon lives. */
	private void buffet(Player player, float gust) {
		Vec3 rel = player.position().subtract(VORTEX);
		Vec3 tangent = new Vec3(-rel.z, 0.0, rel.x);
		if (tangent.lengthSqr() < 1e-6) tangent = new Vec3(1.0, 0.0, 0.0);
		tangent = tangent.normalize();
		if (!player.isSpectator()) {
			double push = 0.014 * intensity * intensity * gust;
			player.setDeltaMovement(player.getDeltaMovement().add(tangent.x * push, 0.0, tangent.z * push));
		}
		// Trauma-model sway (Eiserloh, "Juicing Your Cameras With Math", GDC 2016): shake = trauma^2 times smooth
		// noise, rotational rather than positional. Only the change in offset is applied each tick, so the aim
		// sways and settles back instead of drifting.
		float trauma = Math.min(1.0F, intensity * (0.25F + 0.75F * gust));
		float shake = trauma * trauma;
		double tt = ticks / 20.0;
		float yaw = (float) (smooth(tt * 1.3, 1.7) * 2.2 * shake);
		float pitch = (float) (smooth(tt * 1.1, 5.3) * 1.3 * shake);
		player.setYRot(player.getYRot() + (yaw - swayYaw));
		player.setXRot(Math.max(-90.0F, Math.min(90.0F, player.getXRot() + (pitch - swayPitch))));
		swayYaw = yaw;
		swayPitch = pitch;
	}

	/** Smooth zero-mean noise in [-1, 1]: a few incommensurate sines. */
	private static double smooth(double t, double seed) {
		return (Math.sin(t * 1.0 + seed) * 0.5 + Math.sin(t * 2.31 + seed * 3.1) * 0.3 + Math.sin(t * 4.73 + seed * 7.7) * 0.2);
	}

	private void updateLightning(Minecraft mc, ClientLevel level, Player player, boolean dragon, float gust) {
		if (boltAge < 0 && random.nextFloat() < 0.004F + 0.009F * intensity * intensity * (dragon ? 1.3F : 1.0F)) {
			boltAge = 0;
			boltCode = random.nextInt(16) / 16.0F;
			boltSeed = random.nextFloat() * 10.0F;
			Vec3 pos = boltPosition(boltCode);
			double distance = pos.distanceTo(player.position());
			// Sound travels ~343 blocks per second.
			long delay = Math.round(distance / 343.0 * 20.0);
			pending.add(new PendingThunder(ticks + delay, pos, distance));
		}
		float flash = 0.0F;
		if (boltAge >= 0) {
			float t = boltAge;
			// One flash and a single soft after-glow; no strobing (Trevor: the rapid flicker read as epileptic).
			flash = (float) (Math.exp(-t / 2.5) + (t >= 4.0F ? 0.35 * Math.exp(-(t - 4.0) / 2.5) : 0.0));
			if (++boltAge > 16) boltAge = -1;
		}
		// Channels for the shader (decoded in the shaderpack's lib/end_atmosphere.glsl). Rain carries only the storm
		// intensity, which changes smoothly: packing the bolt direction in with it made the value jump at every
		// strike, and the in-between value the renderer blends to decoded as a random intensity for a frame (the
		// "random pink frame"). Thunder carries the gust (0..0.5), or during a strike the bolt direction and flash
		// (0.5..1.0: 16 directions, flash in the fraction). Minecraft reports thunder multiplied by rain.
		level.setRainLevel(0.2F + 0.8F * Math.min(intensity, 0.999F));
		float boltDir = Math.round(boltCode * 16.0F) % 16;
		level.setThunderLevel(flash > 0.02F ? 0.5F + 0.5F * (boltDir + Math.min(flash, 0.999F)) / 16.0F : 0.499F * gust);

		pending.removeIf(p -> {
			if (ticks < p.dueTick()) return false;
			Vec3 dir = p.pos().subtract(player.getEyePosition()).normalize();
			Vec3 at = player.getEyePosition().add(dir.scale(10.0));
			boolean near = p.distance < 220.0;
			float vol = (float) Math.max(0.5, Math.min(2.0, 420.0 / (p.distance + 60.0))) * (0.8F + 0.8F * intensity);
			mc.getSoundManager().play(new SimpleSoundInstance(event("claudebench_ambience", near ? "end.thunder_near" : "end.thunder_far"),
				SoundSource.WEATHER, vol, 0.85F + random.nextFloat() * 0.25F, random, at.x, at.y, at.z));
			return true;
		});
	}

	/** Same mapping as endLightning() in the shaderpack's lib/end_atmosphere.glsl. */
	static Vec3 boltPosition(float code) {
		double a = code * Math.PI * 2.0;
		double y = 90.0 + 170.0 * fract(code * 7.31);
		return new Vec3(VORTEX.x + Math.cos(a) * EYE_RADIUS, y, VORTEX.z + Math.sin(a) * EYE_RADIUS);
	}

	private static double fract(double x) { return x - Math.floor(x); }

	private void startAll(Minecraft mc) {
		loops.clear();
		loops.add(new Loop(event("claudebench_ambience", "end.wind_drone"), 0.2F, 1.1F, 0.3F, false, 1.0F));
		loops.add(new Loop(event("claudebench_ambience", "end.wind_howl"), 0.1F, 1.3F, 1.0F, true, 1.0F));
		// The same howl an octave down: a groaning wind that sounds wrong.
		loops.add(new Loop(event("claudebench_ambience", "end.wind_howl"), 0.0F, 0.9F, 1.0F, true, 0.5F));
		loops.add(new Loop(event("claudebench_ambience", "end.rumble"), 0.2F, 0.9F, 0.0F, false, 1.0F));
		loops.add(new Loop(event("claudebench_ambience", "end.alien_choir"), 0.12F, 0.4F, 0.0F, false, 1.0F));
		if (FabricLoader.getInstance().isModLoaded("ambientsounds")) {
			loops.add(new Loop(event("ambientsounds", "wind.heavy-wind"), 0.1F, 1.2F, 0.6F, true, 1.0F));
			loops.add(new Loop(event("ambientsounds", "weather.storm-close"), 0.0F, 1.0F, 0.2F, false, 0.85F));
			loops.add(new Loop(event("ambientsounds", "wind.howling-wind"), 0.05F, 0.9F, 1.0F, true, 0.8F));
		}
		for (Loop l : loops) mc.getSoundManager().play(l);
		intensity = 0.3F;
	}

	private void stopAll(ClientLevel level) {
		for (Loop l : loops) l.finish();
		loops.clear();
		pending.clear();
		boltAge = -1;
		active = false;
	}

	/** A looping layer: volume = base + span * intensity (optionally swelling with gusts), optionally circling. */
	private static final class Loop extends AbstractTickableSoundInstance {
		private final float base, span, gustAmount;
		private final boolean circles;
		private final float phase;
		private final float pitchBase;

		Loop(SoundEvent event, float base, float span, float gustAmount, boolean circles, float pitchBase) {
			super(event, SoundSource.AMBIENT, RandomSource.create());
			this.base = base;
			this.span = span;
			this.gustAmount = gustAmount;
			this.circles = circles;
			this.pitchBase = pitchBase;
			this.phase = (float) (Math.random() * Math.PI * 2.0);
			this.looping = true;
			this.delay = 0;
			this.relative = true;
			this.attenuation = SoundInstance.Attenuation.NONE;
			this.volume = 0.01F;
		}

		void update(float intensity, float gust, float angle) {
			float g = 1.0F - gustAmount + gustAmount * gust * 1.6F;
			this.volume = Math.max(0.0F, (base + span * intensity) * g);
			this.pitch = pitchBase * (0.9F + 0.15F * intensity + 0.05F * gust);
			if (circles) {
				// Gusts sweep around the player with the vortex.
				double a = angle + phase;
				this.x = Math.cos(a) * 4.0;
				this.y = 1.0;
				this.z = Math.sin(a) * 4.0;
			}
		}

		void finish() { this.stop(); }

		@Override
		public void tick() {}
	}
}
