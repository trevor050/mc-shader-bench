package dev.claudebench.benchcam;

import com.google.gson.Gson;
import dev.claudebench.benchcam.mixin.CameraRouteAccessor;
import dev.claudebench.benchcam.mixin.LevelWeatherAccessor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentSkipListSet;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.minecraft.client.CameraType;
import net.minecraft.client.Minecraft;
import net.minecraft.core.Holder;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.clock.ClockState;
import net.minecraft.world.clock.WorldClock;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.saveddata.WeatherData;
import net.minecraft.world.phys.Vec3;

/** Native deterministic route runner. Wall-clock stalls skip forward; no frame/tick controls travel speed. */
public final class DynamicRoutes {
    private static final Gson JSON = new Gson();
    private static DynamicRoute loaded;
    private static volatile Run current;
    private static final RouteMath.Pose CLIENT_POSE = new RouteMath.Pose();
    private static final RouteMath.Pose SERVER_POSE = new RouteMath.Pose();
    private static Object irisTimer;
    private static Method irisTimerRead;
    private static boolean irisTimerResolved;

    private DynamicRoutes() {}

    public static void initialize() {
        ClientTickEvents.END_CLIENT_TICK.register(DynamicRoutes::clientTick);
        ServerTickEvents.END_SERVER_TICK.register(DynamicRoutes::serverTick);
        ServerLifecycleEvents.SERVER_STOPPING.register(server -> {
            Run run = current;
            if (run != null && run.running && run.server == server) restoreServer(run, "SERVER_STOPPING");
        });
        ClientLifecycleEvents.CLIENT_STOPPING.register(mc -> requestStop("CLIENT_STOPPING"));
    }

    public static boolean controlsActive() {
        Run run = current;
        return run != null && run.running;
    }

    /** Read-only clock calibration bypasses the render queue, so slow rendering cannot delay every probe. */
    public static String clockReply() {
        return "ok " + JSON.toJson(Map.of("monotonic_ns", System.nanoTime(), "epoch_ms", System.currentTimeMillis()));
    }

    public static String command(String argument, Minecraft mc) {
        try {
            int space = argument.indexOf(' ');
            String verb = space < 0 ? argument : argument.substring(0, space);
            String rest = space < 0 ? "" : argument.substring(space + 1).strip();
            return switch (verb) {
                case "clock" -> clockReply();
                case "status" -> "ok " + JSON.toJson(status(current));
                case "load" -> {
                    if (controlsActive()) yield "err a route is already active";
                    loaded = new DynamicRoute(Base64.getUrlDecoder().decode(rest));
                    yield "ok " + JSON.toJson(Map.of("id", loaded.id, "route_id", loaded.id, "route_sha256", loaded.hash,
                        "duration_s", loaded.duration, "length_blocks", loaded.path.length, "speed_blocks_s", loaded.path.length / loaded.duration));
                }
                case "start" -> start(mc, rest);
                case "cancel" -> {
                    if (!rest.isEmpty()) {
                        Run run = current;
                        if (!rest.startsWith("request_id=") || run == null || !run.requestId.equals(rest.substring(11)))
                            yield "err route cancellation request_id does not match current run";
                    }
                    requestStop("CANCELLED");
                    yield "ok " + JSON.toJson(status(current));
                }
                default -> "err usage: route load <base64url>|start warmup=N measure=N arm_ms=N [request_id=UUID]|status|clock|cancel [request_id=UUID]";
            };
        } catch (Throwable failure) {
            return "err " + failure.toString().replace('\n', ' ');
        }
    }

    private static String start(Minecraft mc, String arguments) throws Exception {
        if (controlsActive()) return "err a route is already active";
        if (loaded == null) return "err load a route first";
        String profilerState = GpuPassProfiler.status();
        if (!(profilerState.contains("state=idle ") || profilerState.contains("state=closed ")) || !profilerState.contains("pending=0 ") || !profilerState.contains("restart_required=false ")
            || !profilerState.contains("failed_reason=none ") || !profilerState.contains("writer_error=none ") || !profilerState.contains("unreleased_queries=0 "))
            return "err route acceptance requires GPU profiler idle/closed with no pending queries";
        if (mc.player == null || mc.level == null || mc.getSingleplayerServer() == null) return "err integrated singleplayer world required";
        if (mc.gui.screen() != null || mc.isPaused()) return "err close the game screen and unpause before starting";
        if (mc.player.isPassenger() || mc.player.isSleeping()) return "err dismount and wake before starting";
        if (!mc.player.isAlive() || mc.player.isUsingItem()) return "err living idle player required";
        if (mc.getCameraEntity() != mc.player) return "err self camera required before route ownership";
        if (mc.gameRenderer.mainCamera().getCapturedFrustum() != null
            || ((CameraRouteAccessor)mc.gameRenderer.mainCamera()).benchcam$isFrustumCapturePending())
            return "err release captured or pending debug frustum before route ownership";
        if (!mc.level.dimension().identifier().toString().equals(loaded.dimension)) return "err route requires the existing Overworld dimension";
        Map<String, Integer> options = new HashMap<>();
        String requestId = null;
        for (String token : arguments.split("\\s+")) {
            if (token.isBlank()) continue;
            String[] pair = token.split("=", 2);
            if (pair.length == 2 && pair[0].equals("request_id")) {
                if (requestId != null || !UUID.fromString(pair[1]).toString().equals(pair[1])) return "err canonical unique request_id UUID required";
                requestId = pair[1]; continue;
            }
            if (pair.length != 2 || !java.util.Set.of("warmup", "measure", "arm_ms").contains(pair[0])) return "err invalid start option " + token;
            if (options.put(pair[0], Integer.parseInt(pair[1])) != null) return "err duplicate start option";
        }
        int warm = options.getOrDefault("warmup", 2), measure = options.getOrDefault("measure", 1), arm = options.getOrDefault("arm_ms", 5000);
        if (warm < 1 || warm > 10 || measure < 1 || measure > 10 || arm < 2000 || arm > 60000) return "err warmup/measure 1..10, arm_ms 2000..60000 required";
        Run run = new Run(loaded, mc, warm, measure, arm, requestId);
        run.irisTimerAtRequest = irisTime();
        current = run;
        BenchCam.allowMouseGrab = false;
        mc.mouseHandler.releaseMouse();
        mc.options.setCameraType(CameraType.FIRST_PERSON);
        mc.options.smoothCamera = false;
        if (!mc.gui.hud.isHidden()) mc.gui.hud.toggle();
        run.server.execute(() -> prepare(run));
        return "ok " + JSON.toJson(status(run));
    }

    private static void prepare(Run run) {
        try {
            ServerPlayer player = run.server.getPlayerList().getPlayer(run.playerId);
            if (player == null || player.level() != run.server.overworld()) throw new IllegalStateException("Server player/dimension mismatch");
            // Spectator mode removes shoulder entities in 26.2. Reject instead of mutating the world.
            if (player.getShoulderParrotLeft().isPresent() || player.getShoulderParrotRight().isPresent())
                throw new IllegalStateException("Occupied shoulder prevents safe spectator preparation");
            if (player.getCamera() != player || player.isPassenger() || player.isSleeping()
                || !player.isAlive() || player.isUsingItem())
                throw new IllegalStateException("Server player must be living, idle, dismounted, awake and using self camera");
            run.saved = new SavedServer(run.server, player);
            // Resolve the exact fractional-clock restore path before any server state mutation.
            run.saved.resolveClockRestore(run.server);
            run.serverMutated = true;
            run.saved.player.setGameMode(GameType.SPECTATOR);
            run.server.getGlobalGameRules().set(GameRules.ADVANCE_WEATHER, false, run.server);
            run.server.setWeatherParameters(Integer.MAX_VALUE, 0, false, false);
            run.saved.level.setRainLevel(0); run.saved.level.setThunderLevel(0);
            run.server.clockManager().setPaused(run.saved.clock, true);
            run.route.path.sample(0, SERVER_POSE);
            player.connection.teleport(SERVER_POSE.x, SERVER_POSE.y, SERVER_POSE.z, (float)SERVER_POSE.yaw, (float)SERVER_POSE.pitch);
            player.getInventory().setSelectedSlot(run.saved.selectedSlot);
            run.server.clockManager().setTotalTicks(run.saved.clock, Math.round(run.route.environment(0, 1)));
            run.startNs = System.nanoTime() + run.armMs * 1_000_000L;
            run.measuredStartNs = run.startNs + Math.round(run.warmup * run.route.duration * 1e9);
            run.measuredEndNs = run.measuredStartNs + Math.round(run.measure * run.route.duration * 1e9);
            run.serverX = SERVER_POSE.x; run.serverY = SERVER_POSE.y; run.serverZ = SERVER_POSE.z;
            run.serverReady = true;
            BenchCam.LOG.info("Dynamic route {} run {} hash {} armed", run.route.id, run.id, run.route.hash);
        } catch (Throwable failure) {
            run.exception = failure.toString();
            run.reasons.add("PREPARE_FAILED");
            restoreServer(run, "FAILED");
        }
    }

    private static void serverTick(MinecraftServer server) {
        Run run = current;
        if (run == null || !run.running || run.server != server || !run.serverReady || run.restoring) return;
        long now = System.nanoTime();
        if (run.stopReason != null || now >= run.measuredEndNs) { restoreServer(run, run.stopReason == null ? "COMPLETED" : run.stopReason); return; }
        try {
            if (run.saved.player.isRemoved() || run.saved.player.level() != run.saved.level) {
                run.reasons.add("SERVER_PLAYER_LOST"); restoreServer(run, "FAILED"); return;
            }
            if (run.lastServerNs != 0) run.serverMaxGapNs = Math.max(run.serverMaxGapNs, now - run.lastServerNs);
            run.lastServerNs = now;
            run.serverSamples++;
            double elapsed = loopElapsed(run, now);
            run.route.path.sample(elapsed / run.route.duration, SERVER_POSE);
            // No per-tick teleport packets. LocalPlayer position transmission is suppressed during the route.
            run.saved.player.snapTo(SERVER_POSE.x, SERVER_POSE.y, SERVER_POSE.z, (float)SERVER_POSE.yaw, (float)SERVER_POSE.pitch);
            run.saved.player.setDeltaMovement(Vec3.ZERO);
            run.saved.player.connection.resetPosition();
            run.saved.level.getChunkSource().move(run.saved.player);
            run.saved.player.getInventory().setSelectedSlot(run.saved.selectedSlot);
            run.serverX = SERVER_POSE.x; run.serverY = SERVER_POSE.y; run.serverZ = SERVER_POSE.z;
            run.server.clockManager().setTotalTicks(run.saved.clock, Math.round(run.route.environment(elapsed, 1)));
            run.saved.level.setRainLevel(0); run.saved.level.setThunderLevel(0);
        } catch (Throwable failure) {
            run.exception = failure.toString(); run.reasons.add("SERVER_CONTROL_FAILED"); restoreServer(run, "FAILED");
        }
    }

    private static void clientTick(Minecraft mc) {
        Run run = current;
        if (run == null || !run.running || run.restoring) return;
        if (mc.level != run.clientLevel || mc.player == null || mc.gui.screen() != null || mc.isPaused()) {
            requestStop("CLIENT_CONTEXT_LOST"); return;
        }
        if (run.serverReady) {
            try { applyClientPlayer(mc, run, System.nanoTime()); }
            catch (Throwable failure) { run.exception = failure.toString(); requestStop("CLIENT_CONTROL_FAILED"); }
        }
    }

    /** Called before Camera.alignWithEntity, so culling, extraction, Iris and DH see this same pose. */
    public static boolean cameraPose(RouteMath.Pose result) {
        Run run = current;
        if (run == null || !run.running || !run.serverReady || run.restoring) return false;
        Minecraft mc = Minecraft.getInstance();
        if (mc.player == null || mc.level != run.clientLevel) return false;
        long now = System.nanoTime();
        try { applyClientPlayer(mc, run, now); }
        catch (Throwable failure) { run.exception = failure.toString(); requestStop("CLIENT_CONTROL_FAILED"); return false; }
        result.x = CLIENT_POSE.x; result.y = CLIENT_POSE.y + mc.player.getEyeHeight(); result.z = CLIENT_POSE.z;
        result.yaw = CLIENT_POSE.yaw; result.pitch = CLIENT_POSE.pitch;
        if (run.lastRenderNs != 0) run.frameMaxGapNs = Math.max(run.frameMaxGapNs, now - run.lastRenderNs);
        run.lastRenderNs = now; run.renderSamples++;
        if (now >= run.measuredStartNs && now < run.measuredEndNs) {
            if (run.firstMeasuredRenderNs == 0) { run.firstMeasuredRenderNs = now; run.irisTimerAtFirstMeasuredRender = irisTime(); }
            run.measuredRenderSamples++;
        } else if (now >= run.measuredEndNs && run.firstEndRenderNs == 0) { run.firstEndRenderNs = now; run.irisTimerAtFirstEndRender = irisTime(); }
        double dx = CLIENT_POSE.x - run.serverX, dy = CLIENT_POSE.y - run.serverY, dz = CLIENT_POSE.z - run.serverZ;
        double distance = Math.sqrt(dx * dx + dy * dy + dz * dz);
        run.maxServerDistance = Math.max(run.maxServerDistance, distance);
        // Preserve the run and raw frame tail. Mark a material chunk-center separation explicitly.
        if (now >= run.measuredStartNs && now < run.measuredEndNs) {
            run.maxMeasuredServerDistance = Math.max(run.maxMeasuredServerDistance, distance);
            if (distance > 16 && !run.desyncReported) { run.desyncReported = true; run.reasons.add("CONTROL_DESYNC_ONE_CHUNK"); }
        }
        return true;
    }

    private static void applyClientPlayer(Minecraft mc, Run run, long now) {
        double elapsed = loopElapsed(run, now);
        run.route.path.sample(elapsed / run.route.duration, CLIENT_POSE);
        mc.player.snapTo(CLIENT_POSE.x, CLIENT_POSE.y, CLIENT_POSE.z, (float)CLIENT_POSE.yaw, (float)CLIENT_POSE.pitch);
        mc.player.setDeltaMovement(Vec3.ZERO);
        mc.player.getInventory().setSelectedSlot(run.clientSelectedSlot);
        mc.level.setRainLevel((float)run.route.environment(elapsed, 2));
        mc.level.setThunderLevel((float)run.route.environment(elapsed, 3));
        run.clientClock.apply(Math.round(run.route.environment(elapsed, 1)));
    }

    private static double loopElapsed(Run run, long now) {
        if (now <= run.startNs) return 0;
        if (now >= run.measuredEndNs) return run.route.duration;
        return ((now - run.startNs) / 1e9) % run.route.duration;
    }

    private static void requestStop(String reason) {
        Run run = current;
        if (run == null || !run.running || run.restoring) return;
        run.stopReason = reason;
        if (!reason.equals("CANCELLED")) run.reasons.add(reason);
        run.server.execute(() -> restoreServer(run, reason));
    }

    private static void restoreServer(Run run, String reason) {
        if (run.restoring || !run.running) return;
        run.restoring = true;
        run.terminalReason = reason;
        BestEffortRestore restore = restoration(run, "SERVER");
        if (run.saved != null && run.serverMutated) {
            SavedServer saved = run.saved;
            restore.attempt("MODE", () -> saved.player.setGameMode(saved.mode));
            restore.attempt("ABILITIES", () -> {
                saved.player.getAbilities().flying = saved.flying;
                saved.player.onUpdateAbilities();
            });
            restore.attempt("POSE", () -> saved.player.connection.teleport(saved.x, saved.y, saved.z, saved.yaw, saved.pitch));
            restore.attempt("VELOCITY", () -> saved.player.setDeltaMovement(saved.velocity));
            restore.attempt("SLOT", () -> saved.player.getInventory().setSelectedSlot(saved.selectedSlot));
            restore.attempt("CLOCK", () -> saved.restoreClock(run.server));
            restore.attempt("WEATHER_TIMERS", () -> {
                WeatherData weather = run.server.getWeatherData();
                weather.setClearWeatherTime(saved.clear); weather.setRainTime(saved.rainTime); weather.setThunderTime(saved.thunderTime);
                weather.setRaining(saved.raining); weather.setThundering(saved.thundering);
            });
            restore.attempt("WEATHER_INTERPOLATION", () -> saved.weather.restore(saved.level));
            restore.attempt("WEATHER_RULE", () -> run.server.getGlobalGameRules().set(GameRules.ADVANCE_WEATHER, saved.advanceWeather, run.server));
            restore.attempt("INVENTORY_READBACK", () -> {
                boolean inventoryUnchanged = true;
                for (int i = 0; i < saved.inventory.length; i++) inventoryUnchanged &= ItemStack.matches(saved.inventory[i], saved.player.getInventory().getItem(i));
                if (!inventoryUnchanged) { run.reasons.add("INVENTORY_CHANGED"); throw new IllegalStateException("Inventory changed during route"); }
            });
            restore.attempt("STATE_READBACK", () -> {
                WeatherData weather = run.server.getWeatherData();
                if (saved.player.gameMode() != saved.mode || saved.player.getX() != saved.x || saved.player.getY() != saved.y || saved.player.getZ() != saved.z
                    || saved.player.getYRot() != saved.yaw || saved.player.getXRot() != saved.pitch
                    || saved.player.getAbilities().flying != saved.flying || !saved.player.getDeltaMovement().equals(saved.velocity)
                    || saved.player.getInventory().getSelectedSlot() != saved.selectedSlot
                    || !saved.clockState.equals(run.server.clockManager().packState().clocks().get(saved.clock))
                    || weather.getClearWeatherTime() != saved.clear || weather.getRainTime() != saved.rainTime || weather.getThunderTime() != saved.thunderTime
                    || weather.isRaining() != saved.raining || weather.isThundering() != saved.thundering
                    || !saved.weather.equals(new WeatherState(saved.level))
                    || run.server.getGlobalGameRules().get(GameRules.ADVANCE_WEATHER) != saved.advanceWeather)
                    throw new IllegalStateException("Server saved-state readback mismatch");
            });
        }
        run.serverRestored = restore.succeeded();
        Minecraft.getInstance().execute(() -> finishClient(run));
    }

    private static void finishClient(Run run) {
        Minecraft mc = Minecraft.getInstance();
        BestEffortRestore restore = restoration(run, "CLIENT");
        restore.attempt("CAMERA_OPTIONS", () -> {
            mc.options.setCameraType(run.cameraType); mc.options.smoothCamera = run.smoothCamera;
        });
        restore.attempt("HUD", () -> { if (mc.gui.hud.isHidden() != run.hudHidden) mc.gui.hud.toggle(); });
        restore.attempt("MOUSE", () -> {
            BenchCam.allowMouseGrab = run.mouseGrab;
            if (run.mouseGrab && mc.gui.screen() == null && mc.isWindowActive()) mc.mouseHandler.grabMouse();
        });
        restore.attempt("WEATHER", () -> {
            if (mc.level != run.clientLevel) throw new IllegalStateException("Client level unavailable for restore");
            run.clientWeather.restore(mc.level);
        });
        restore.attempt("CLOCK", () -> {
            if (mc.level != run.clientLevel) throw new IllegalStateException("Client level unavailable for clock restore");
            run.clientClock.restore();
        });
        restore.attempt("POSE", () -> {
            if (mc.player == null || !mc.player.getUUID().equals(run.playerId)) throw new IllegalStateException("Client player unavailable for pose restore");
            if (run.saved != null && run.serverMutated) mc.player.snapTo(run.saved.x, run.saved.y, run.saved.z, run.saved.yaw, run.saved.pitch);
            else mc.player.snapTo(run.clientX, run.clientY, run.clientZ, run.clientYaw, run.clientPitch);
        });
        restore.attempt("SLOT", () -> {
            if (mc.player == null || !mc.player.getUUID().equals(run.playerId)) throw new IllegalStateException("Client player unavailable for slot restore");
            mc.player.getInventory().setSelectedSlot(run.clientSelectedSlot);
        });
        restore.attempt("STATE_READBACK", () -> {
            if (mc.level != run.clientLevel || mc.player == null || !mc.player.getUUID().equals(run.playerId)
                || mc.options.getCameraType() != run.cameraType || mc.options.smoothCamera != run.smoothCamera
                || mc.gui.hud.isHidden() != run.hudHidden || BenchCam.allowMouseGrab != run.mouseGrab
                || !run.clientWeather.equals(new WeatherState(mc.level)) || !run.clientClock.matches()
                || mc.player.getInventory().getSelectedSlot() != run.clientSelectedSlot)
                throw new IllegalStateException("Client saved-state readback mismatch");
        });
        run.clientRestored = restore.succeeded();
        run.running = false;
        run.finishedNs = System.nanoTime();
        run.irisTimerAtFinish = irisTime();
        if (run.measuredRenderSamples == 0 && reasonCompleted(run)) run.reasons.add("NO_MEASURED_RENDER_SAMPLES");
        try {
            Path path = mc.gameDirectory.toPath().resolve("benchcam/dynamic-routes/" + run.id + ".json");
            Files.createDirectories(path.getParent());
            run.receiptPath = path.toAbsolutePath().toString();
            Files.writeString(path, JSON.toJson(status(run)) + "\n");
        } catch (Exception failure) { run.reasons.add("RECEIPT_WRITE_FAILED"); run.exception = failure.toString(); }
        BenchCam.LOG.info("Dynamic route {} finished {}, reasons {}", run.id, run.terminalReason, run.reasons);
    }

    private static BestEffortRestore restoration(Run run, String side) {
        return new BestEffortRestore((group, failure) -> {
            run.exception += (run.exception.isEmpty() ? "" : " | ") + side + "/" + group + ": " + failure;
            run.reasons.add(side + "_RESTORE_FAILED"); run.reasons.add(side + "_RESTORE_FAILED_" + group);
            BenchCam.LOG.error("Dynamic route {} restoration group {} failed", side, group, failure);
        });
    }

    private static boolean reasonCompleted(Run run) { return "COMPLETED".equals(run.terminalReason); }

    /** Optional installed-Iris API, resolved/read outside ordinary frame work. No new mod dependency. */
    private static double irisTime() {
        if (!irisTimerResolved) {
            irisTimerResolved = true;
            try {
                Class<?> type = Class.forName("net.irisshaders.iris.uniforms.SystemTimeUniforms");
                irisTimer = type.getField("TIMER").get(null);
                irisTimerRead = irisTimer.getClass().getMethod("getFrameTimeCounter");
            } catch (ReflectiveOperationException ignored) { irisTimerRead = null; }
        }
        if (irisTimerRead == null) return -1;
        try { double value = ((Number)irisTimerRead.invoke(irisTimer)).doubleValue(); return Double.isFinite(value) ? value : -1; }
        catch (ReflectiveOperationException ignored) { return -1; }
    }

    private static Map<String, Object> status(Run run) {
        long now = System.nanoTime();
        Map<String, Object> out = new HashMap<>();
        out.put("monotonic_ns", now); out.put("epoch_ms", System.currentTimeMillis());
        if (run == null) { out.put("running", false); out.put("phase", "idle"); return out; }
        String phase;
        if (!run.running) phase = !run.serverRestored || !run.clientRestored || !run.reasons.isEmpty() && !run.terminalReason.equals("CANCELLED") ? "failed" : reasonCompleted(run) ? "completed" : "cancelled";
        else if (run.restoring) phase = "restoring";
        else if (!run.serverReady) phase = "preparing";
        else if (now < run.startNs) phase = "armed";
        else if (now < run.startNs + Math.round(run.route.duration * 1e9)) phase = "streaming";
        else if (now < run.measuredStartNs) phase = "warmup";
        else phase = "measured";
        out.put("phase", phase); out.put("running", run.running); out.put("run_id", run.id);
        out.put("request_id", run.requestId);
        out.put("route_id", run.route.id); out.put("route_sha256", run.route.hash); out.put("duration_s", run.route.duration);
        out.put("warmup_loops", run.warmup); out.put("measured_loops", run.measure); out.put("arm_ms", run.armMs);
        out.put("speed_blocks_s", run.route.path.length / run.route.duration);
        out.put("planned_initial_pose", run.initialPose);
        out.put("planned_initial_time_ticks", Math.round(run.route.environment(0, 1)));
        out.put("planned_initial_weather", Map.of("rain", run.route.environment(0, 2), "thunder", run.route.environment(0, 3)));
        if (run.saved != null) {
            SavedServer saved = run.saved;
            out.put("saved_server_state", Map.of("pose", new double[]{saved.x, saved.y, saved.z, saved.yaw, saved.pitch},
                "game_mode", saved.mode.getName(), "selected_slot", saved.selectedSlot, "clock", saved.clockState,
                "weather_interpolation", saved.weather, "advance_weather", saved.advanceWeather,
                "weather_flags_timers", Map.of("raining", saved.raining, "thundering", saved.thundering,
                    "clear_weather_time", saved.clear, "rain_time", saved.rainTime, "thunder_time", saved.thunderTime)));
        }
        out.put("elapsed_s", run.startNs == 0 ? 0 : Math.max(0, ((run.running ? now : run.finishedNs) - run.startNs) / 1e9));
        out.put("loop_elapsed_s", run.startNs == 0 ? 0 : loopElapsed(run, now));
        out.put("loop_index", run.startNs == 0 ? -1 : Math.min(run.warmup + run.measure - 1, Math.max(0, (int)(((run.running ? now : run.finishedNs) - run.startNs) / (run.route.duration * 1e9)))));
        out.put("start_ns", run.startNs); out.put("measured_start_ns", run.measuredStartNs); out.put("measured_end_ns", run.measuredEndNs);
        out.put("measured_start_epoch_ms", run.measuredStartNs == 0 ? 0 : run.epochAtCreation + (run.measuredStartNs - run.nanoAtCreation) / 1_000_000L);
        out.put("measured_end_epoch_ms", run.measuredEndNs == 0 ? 0 : run.epochAtCreation + (run.measuredEndNs - run.nanoAtCreation) / 1_000_000L);
        out.put("first_measured_render_ns", run.firstMeasuredRenderNs); out.put("first_end_render_ns", run.firstEndRenderNs);
        out.put("server_samples", run.serverSamples); out.put("render_samples", run.renderSamples); out.put("measured_render_samples", run.measuredRenderSamples);
        out.put("frame_max_gap_ms", run.frameMaxGapNs / 1e6); out.put("server_max_gap_ms", run.serverMaxGapNs / 1e6);
        out.put("camera_server_max_distance", run.maxServerDistance);
        out.put("camera_server_measured_max_distance", run.maxMeasuredServerDistance);
        out.put("measured_workload_valid", run.reasons.isEmpty()); out.put("reason_codes", run.reasons);
        out.put("restore_result", Map.of("server", run.serverRestored, "client", run.clientRestored));
        out.put("exception", run.exception); out.put("receipt_path", run.receiptPath);
        out.put("iris_frame_time_counter_s", irisTime());
        out.put("iris_timer_at_request_s", run.irisTimerAtRequest);
        out.put("iris_timer_at_first_measured_render_s", run.irisTimerAtFirstMeasuredRender);
        out.put("iris_timer_at_first_end_render_s", run.irisTimerAtFirstEndRender);
        out.put("iris_timer_at_finish_s", run.irisTimerAtFinish);
        out.put("weather_scope", "client visual weather; server precipitation and lightning suppressed during route");
        out.put("celestial_lighting_scope", "native MC26.2 tick-sampled, partial-tick-interpolated SUN/MOON attributes; frame-clock targets do not bypass native attribute caches");
        out.put("gpu_profiler_status", GpuPassProfiler.status());
        return out;
    }

    private static final class Run {
        final String id = UUID.randomUUID().toString();
        final String requestId;
        final DynamicRoute route;
        final MinecraftServer server;
        final UUID playerId;
        final Level clientLevel;
        final WeatherState clientWeather;
        final ClientClockState clientClock;
        final CameraType cameraType;
        final boolean smoothCamera, hudHidden, mouseGrab;
        final int warmup, measure, armMs, clientSelectedSlot;
        final double clientX, clientY, clientZ;
        final float clientYaw, clientPitch;
        final double[] initialPose = new double[5];
        final long epochAtCreation = System.currentTimeMillis(), nanoAtCreation = System.nanoTime();
        final ConcurrentSkipListSet<String> reasons = new ConcurrentSkipListSet<>();
        volatile boolean running = true, serverReady, restoring, serverRestored, clientRestored, desyncReported, serverMutated;
        volatile long startNs, measuredStartNs, measuredEndNs, finishedNs, serverSamples, renderSamples, measuredRenderSamples,
            lastRenderNs, lastServerNs, frameMaxGapNs, serverMaxGapNs, firstMeasuredRenderNs, firstEndRenderNs;
        volatile double serverX, serverY, serverZ, maxServerDistance, maxMeasuredServerDistance;
        volatile double irisTimerAtRequest = -1, irisTimerAtFirstMeasuredRender = -1, irisTimerAtFirstEndRender = -1, irisTimerAtFinish = -1;
        volatile String stopReason, terminalReason = "", exception = "", receiptPath = "";
        volatile SavedServer saved;
        Run(DynamicRoute route, Minecraft mc, int warmup, int measure, int armMs, String requestId) throws Exception {
            this.route = route; this.warmup = warmup; this.measure = measure; this.armMs = armMs;
            this.requestId = requestId == null ? id : requestId;
            server = mc.getSingleplayerServer(); playerId = mc.player.getUUID(); clientLevel = mc.level;
            clientWeather = new WeatherState(mc.level); cameraType = mc.options.getCameraType(); smoothCamera = mc.options.smoothCamera;
            clientClock = new ClientClockState(mc);
            hudHidden = mc.gui.hud.isHidden(); mouseGrab = BenchCam.allowMouseGrab;
            clientX = mc.player.getX(); clientY = mc.player.getY(); clientZ = mc.player.getZ(); clientYaw = mc.player.getYRot(); clientPitch = mc.player.getXRot();
            clientSelectedSlot = mc.player.getInventory().getSelectedSlot();
            RouteMath.Pose pose = new RouteMath.Pose(); route.path.sample(0, pose);
            initialPose[0] = pose.x; initialPose[1] = pose.y; initialPose[2] = pose.z; initialPose[3] = pose.yaw; initialPose[4] = pose.pitch;
        }
    }

    /** Resolve version-specific reflection once, outside the frame path. Primitive setters allocate no route objects. */
    private static final class ClientClockState {
        final Object instance;
        final Field totalField, partialField, rateField;
        final long total;
        final float partial, rate;
        ClientClockState(Minecraft mc) throws Exception {
            Object manager = mc.level.clockManager();
            Method getInstance = manager.getClass().getDeclaredMethod("getInstance", Holder.class); getInstance.setAccessible(true);
            instance = getInstance.invoke(manager, mc.level.dimensionType().defaultClock().orElseThrow());
            totalField = instance.getClass().getDeclaredField("totalTicks"); totalField.setAccessible(true);
            partialField = instance.getClass().getDeclaredField("partialTick"); partialField.setAccessible(true);
            rateField = instance.getClass().getDeclaredField("rate"); rateField.setAccessible(true);
            total = totalField.getLong(instance); partial = partialField.getFloat(instance); rate = rateField.getFloat(instance);
        }
        void apply(long time) {
            try { totalField.setLong(instance, time); partialField.setFloat(instance, 0); rateField.setFloat(instance, 0); }
            catch (IllegalAccessException failure) { throw new IllegalStateException("Client route clock setter failed", failure); }
        }
        void restore() throws Exception { totalField.setLong(instance, total); partialField.setFloat(instance, partial); rateField.setFloat(instance, rate); }
        boolean matches() throws Exception { return totalField.getLong(instance) == total && partialField.getFloat(instance) == partial && rateField.getFloat(instance) == rate; }
    }

    private record WeatherState(float rain, float oldRain, float thunder, float oldThunder) {
        WeatherState(Level level) { this(((LevelWeatherAccessor)level).benchcam$getRain(), ((LevelWeatherAccessor)level).benchcam$getOldRain(),
            ((LevelWeatherAccessor)level).benchcam$getThunder(), ((LevelWeatherAccessor)level).benchcam$getOldThunder()); }
        void restore(Level level) {
            LevelWeatherAccessor access = (LevelWeatherAccessor)level;
            access.benchcam$setRain(rain); access.benchcam$setOldRain(oldRain); access.benchcam$setThunder(thunder); access.benchcam$setOldThunder(oldThunder);
        }
    }

    private static final class SavedServer {
        final ServerPlayer player;
        final ServerLevel level;
        final Holder<WorldClock> clock;
        final ClockState clockState;
        final GameType mode;
        final WeatherState weather;
        final boolean advanceWeather, raining, thundering, flying;
        final int clear, rainTime, thunderTime, selectedSlot;
        final double x, y, z;
        final float yaw, pitch;
        final Vec3 velocity;
        final ItemStack[] inventory;
        Object clockInstance;
        Method loadClock;
        SavedServer(MinecraftServer server, ServerPlayer player) {
            this.player = player; level = server.overworld(); clock = level.dimensionType().defaultClock().orElseThrow();
            clockState = server.clockManager().packState().clocks().get(clock); mode = player.gameMode(); weather = new WeatherState(level);
            advanceWeather = server.getGlobalGameRules().get(GameRules.ADVANCE_WEATHER);
            WeatherData data = server.getWeatherData(); clear = data.getClearWeatherTime(); rainTime = data.getRainTime(); thunderTime = data.getThunderTime();
            raining = data.isRaining(); thundering = data.isThundering(); flying = player.getAbilities().flying;
            x = player.getX(); y = player.getY(); z = player.getZ(); yaw = player.getYRot(); pitch = player.getXRot(); velocity = player.getDeltaMovement();
            selectedSlot = player.getInventory().getSelectedSlot(); inventory = new ItemStack[player.getInventory().getContainerSize()];
            for (int i = 0; i < inventory.length; i++) inventory[i] = player.getInventory().getItem(i).copy();
        }
        void resolveClockRestore(MinecraftServer server) throws Exception {
            // MC 26.2's public setters reset fractional time. The exact installed-source restore preserves it.
            Field field = server.clockManager().getClass().getDeclaredField("clocks"); field.setAccessible(true);
            clockInstance = ((Map<?, ?>)field.get(server.clockManager())).get(clock);
            loadClock = clockInstance.getClass().getDeclaredMethod("loadFrom", ClockState.class); loadClock.setAccessible(true);
        }
        void restoreClock(MinecraftServer server) throws Exception {
            loadClock.invoke(clockInstance, clockState);
            server.clockManager().setDirty();
            server.getPlayerList().broadcastAll(server.clockManager().createFullSyncPacket());
            for (ServerLevel dimension : server.getAllLevels()) dimension.environmentAttributes().invalidateTickCache();
        }
    }
}
