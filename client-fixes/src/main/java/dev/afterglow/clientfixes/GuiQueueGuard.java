package dev.afterglow.clientfixes;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.command.v2.ClientCommandRegistrationCallback;
import net.fabricmc.fabric.api.client.command.v2.ClientCommands;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.network.chat.Component;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

/** Optional screen-only queue mitigation. Every access occurs on the client render thread. */
public final class GuiQueueGuard implements ClientModInitializer {
    private static final Logger LOG = LoggerFactory.getLogger("AfterglowClientFixes");
    private static final Gson JSON = new GsonBuilder().setPrettyPrinting().create();
    private static final Path CONFIG_PATH = FabricLoader.getInstance().getConfigDir().resolve("afterglow-client-fixes.json");
    private static Config config = new Config();
    private static Method packInUse;
    private static Method packName;
    private static boolean irisAvailable;
    private static boolean runtimeFailed;
    private static long engagedFrames;
    private static long completedFrames;
    private static long timedOutFrames;
    private static long totalWaitNs;
    private static long maxWaitNs;
    private static String lastPack = "none";
    private static String lastGate = "not initialized";

    public static final class Config {
        public boolean enabled = true;
        public int maxWaitMillis = 30;
    }

    @Override
    public void onInitializeClient() {
        loadConfig();
        if (FabricLoader.getInstance().isModLoaded("iris")) {
            try {
                Class<?> iris = Class.forName("net.irisshaders.iris.Iris");
                packInUse = iris.getMethod("isPackInUseQuick");
                packName = iris.getMethod("getCurrentPackName");
                irisAvailable = true;
            } catch (ReflectiveOperationException | LinkageError ex) {
                LOG.warn("Iris API unavailable; GUI queue mitigation will remain inactive", ex);
            }
        }
        ClientCommandRegistrationCallback.EVENT.register((dispatcher, registryAccess) -> dispatcher.register(
            ClientCommands.literal("afterglowfix")
                .then(ClientCommands.literal("status").executes(context -> {
                    context.getSource().sendFeedback(Component.literal(status()));
                    resetCounters();
                    return 1;
                }))
                .then(ClientCommands.literal("on").executes(context -> {
                    config.enabled = true;
                    saveConfig();
                    resetCounters();
                    context.getSource().sendFeedback(Component.literal("Afterglow GUI queue mitigation enabled; counters reset."));
                    return 1;
                }))
                .then(ClientCommands.literal("off").executes(context -> {
                    config.enabled = false;
                    saveConfig();
                    resetCounters();
                    context.getSource().sendFeedback(Component.literal("Afterglow GUI queue mitigation disabled; counters reset."));
                    return 1;
                }))
        ));
        LOG.info("GUI queue mitigation initialized: enabled={}, boundedWait={}ms, IrisAPI={}", config.enabled, config.maxWaitMillis, irisAvailable);
    }

    public static boolean shouldWait() {
        // Fast disabled/no-screen paths perform no Iris reflection and no GL operation.
        if (!config.enabled) { lastGate = "disabled"; return false; }
        if (runtimeFailed) { lastGate = "runtime failure"; return false; }
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.level == null || minecraft.gui.screen() == null) {
            lastGate = "no in-world screen";
            return false;
        }
        if (!irisAvailable) { lastGate = "Iris API unavailable"; return false; }
        try {
            if (!(Boolean) packInUse.invoke(null)) { lastGate = "shaders disabled"; return false; }
            lastPack = (String) packName.invoke(null);
            if (!QueuePolicy.matchesPack(lastPack)) { lastGate = "other shader pack"; return false; }
            lastGate = "active";
            return true;
        } catch (ReflectiveOperationException | LinkageError ex) {
            fail(ex);
            return false;
        }
    }

    public static long timeoutNs() {
        return config.maxWaitMillis * 1_000_000L;
    }

    public static void recordWait(long waitNs, boolean completed) {
        engagedFrames++;
        if (completed) completedFrames++; else timedOutFrames++;
        totalWaitNs += waitNs;
        maxWaitNs = Math.max(maxWaitNs, waitNs);
    }

    public static void fail(Throwable ex) {
        runtimeFailed = true;
        lastGate = "runtime failure";
        LOG.warn("GUI queue mitigation disabled for this session after a runtime failure", ex);
    }

    private static String status() {
        double meanMs = engagedFrames == 0 ? 0.0 : totalWaitNs / (double) engagedFrames / 1_000_000.0;
        return String.format(Locale.ROOT,
            "Afterglow GUI guard: enabled=%s gate=%s pack=%s budget=%dms engaged=%d completed=%d timeouts=%d meanWait=%.3fms maxWait=%.3fms; counters reset.",
            config.enabled, lastGate, lastPack, config.maxWaitMillis, engagedFrames, completedFrames,
            timedOutFrames, meanMs, maxWaitNs / 1_000_000.0);
    }

    private static void resetCounters() {
        engagedFrames = completedFrames = timedOutFrames = totalWaitNs = maxWaitNs = 0L;
    }

    private static void loadConfig() {
        if (Files.isRegularFile(CONFIG_PATH)) {
            try {
                Config loaded = JSON.fromJson(Files.readString(CONFIG_PATH), Config.class);
                if (loaded != null) config = loaded;
            } catch (IOException | RuntimeException ex) {
                // Do not overwrite an invalid existing file during startup.
                LOG.warn("Cannot read {}; using defaults for this session", CONFIG_PATH, ex);
            }
        }
        config.maxWaitMillis = QueuePolicy.boundedWaitMillis(config.maxWaitMillis);
    }

    private static void saveConfig() {
        try {
            Files.createDirectories(CONFIG_PATH.getParent());
            Files.writeString(CONFIG_PATH, JSON.toJson(config) + System.lineSeparator());
        } catch (IOException ex) {
            LOG.warn("Cannot save {}; runtime setting still changed", CONFIG_PATH, ex);
        }
    }
}
