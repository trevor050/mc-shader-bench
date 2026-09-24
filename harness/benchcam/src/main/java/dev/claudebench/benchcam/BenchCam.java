package dev.claudebench.benchcam;

import com.mojang.blaze3d.platform.NativeImage;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Line-based command server on 127.0.0.1 for automated screenshot capture.
 * Every command gets exactly one reply line starting with "ok" or "err".
 */
public final class BenchCam implements ClientModInitializer {
	public static final Logger LOG = LoggerFactory.getLogger("benchcam");
	private static final int DEFAULT_PORT = 25599;

	/** Off by default so the unattended game never traps the OS cursor. Toggle with "mouse grab|free". */
	public static volatile boolean allowMouseGrab = Boolean.getBoolean("benchcam.allowMouseGrab");

	private record Waiter(BooleanSupplier done, long deadlineTick, CompletableFuture<String> result, String onTimeout) {}

	private final List<Waiter> waiters = new ArrayList<>();
	private long tick;

	@Override
	public void onInitializeClient() {
		ClientTickEvents.END_CLIENT_TICK.register(mc -> {
			if (tick == 0) {
				// The default AFK limiter drops to 30 fps whenever nobody touches the input, which is always, here.
				mc.options.inactivityFpsLimit().set(net.minecraft.client.InactivityFpsLimit.MINIMIZED);
			}
			tick++;
			// Click-to-play: a real click inside the focused game window (no menu open) means someone wants to
			// play, so hand them the mouse. Esc releases it as usual; the harness frees it again for captures.
			if (!allowMouseGrab && mc.level != null && mc.gui.screen() == null && mc.isWindowActive()
					&& org.lwjgl.glfw.GLFW.glfwGetMouseButton(mc.getWindow().handle(), org.lwjgl.glfw.GLFW.GLFW_MOUSE_BUTTON_LEFT) == org.lwjgl.glfw.GLFW.GLFW_PRESS) {
				allowMouseGrab = true;
				mc.mouseHandler.grabMouse();
			}
			Iterator<Waiter> it = waiters.iterator();
			while (it.hasNext()) {
				Waiter w = it.next();
				if (w.done.getAsBoolean()) {
					w.result.complete("ok");
					it.remove();
				} else if (tick >= w.deadlineTick) {
					w.result.complete(w.onTimeout);
					it.remove();
				}
			}
		});

		int port = Integer.getInteger("benchcam.port", DEFAULT_PORT);
		Thread server = new Thread(() -> serve(port), "BenchCam-Server");
		server.setDaemon(true);
		server.start();
	}

	private void serve(int port) {
		try (ServerSocket socket = new ServerSocket(port, 4, InetAddress.getLoopbackAddress())) {
			LOG.info("BenchCam listening on 127.0.0.1:{}", port);
			while (true) {
				Socket client = socket.accept();
				Thread t = new Thread(() -> handle(client), "BenchCam-Client");
				t.setDaemon(true);
				t.start();
			}
		} catch (IOException e) {
			LOG.error("BenchCam server failed", e);
		}
	}

	private void handle(Socket client) {
		try (client;
			 BufferedReader in = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8));
			 PrintWriter out = new PrintWriter(client.getOutputStream(), true, StandardCharsets.UTF_8)) {
			String line;
			while ((line = in.readLine()) != null) {
				line = line.strip();
				if (line.isEmpty()) continue;
				String reply;
				try {
					reply = dispatch(line).get(10, TimeUnit.MINUTES);
				} catch (Exception e) {
					Throwable cause = e.getCause() != null ? e.getCause() : e;
					reply = "err " + cause;
				}
				out.println(reply.replace('\n', ' '));
			}
		} catch (IOException e) {
			LOG.debug("BenchCam client disconnected", e);
		}
	}

	private CompletableFuture<String> dispatch(String line) {
		int space = line.indexOf(' ');
		String verb = space < 0 ? line : line.substring(0, space);
		String arg = space < 0 ? "" : line.substring(space + 1).strip();
		Minecraft mc = Minecraft.getInstance();

		return switch (verb) {
			case "ping" -> CompletableFuture.completedFuture("ok pong");
			case "framestats" -> CompletableFuture.completedFuture(FrameTimeStats.summarizeRecent(arg));
			case "gpuprof" -> gpuProfileCommand(arg);
			case "status" -> onRenderThread(() -> {
				var p = mc.player;
				String pos = p == null ? "none" : String.format("%.2f %.2f %.2f %.1f %.1f", p.getX(), p.getY(), p.getZ(), p.getYRot(), p.getXRot());
				long time = mc.level == null ? -1 : mc.level.getOverworldClockTime();
				return "ok fps=" + mc.getFps() + " pos=" + pos + " time=" + time
					+ " screen=" + (mc.gui.screen() == null ? "none" : mc.gui.screen().getClass().getSimpleName())
					+ " chunks=" + (mc.level != null && mc.levelRenderer.hasRenderedAllSections());
			});
			case "cmd" -> onRenderThread(() -> {
				if (mc.player == null) return "err not in world";
				mc.player.connection.sendCommand(arg.startsWith("/") ? arg.substring(1) : arg);
				return "ok";
			});
			case "look" -> onRenderThread(() -> {
				if (mc.player == null) return "err not in world";
				String[] angles = arg.split("\\s+");
				if (angles.length != 2) return "err usage: look <yaw> <pitch>";
				float yaw = Float.parseFloat(angles[0]);
				float pitch = Float.parseFloat(angles[1]);
				if (!Float.isFinite(yaw) || !Float.isFinite(pitch) || pitch < -90.0f || pitch > 90.0f)
					return "err invalid camera angles";
				// Rotate the client camera without a server /tp or chunk reload.
				mc.player.setYRot(yaw);
				mc.player.setXRot(pitch);
				mc.player.yRotO = yaw;
				mc.player.xRotO = pitch;
				return "ok";
			});
			case "hud" -> onRenderThread(() -> {
				boolean wantHidden = arg.equals("off");
				if (mc.gui.hud.isHidden() != wantHidden) mc.gui.hud.toggle();
				return "ok";
			});
			case "closescreen" -> onRenderThread(() -> {
				mc.gui.setScreen(null);
				return "ok";
			});
			case "wait" -> waitTicks(Integer.parseInt(arg));
			case "waitchunks" -> {
				int timeout = arg.isEmpty() ? 600 : Integer.parseInt(arg);
				yield waitUntil(() -> mc.level != null && mc.levelRenderer.hasRenderedAllSections(), timeout, "ok timeout");
			}
			case "shot" -> screenshot(mc, Path.of(arg));
			case "reload" -> onRenderThread(BenchCam::reloadIris);
			case "mouse" -> onRenderThread(() -> {
				allowMouseGrab = arg.equals("grab");
				if (!allowMouseGrab) mc.mouseHandler.releaseMouse();
				return "ok";
			});
			case "window" -> onRenderThread(() -> {
				String[] xy = arg.split("\\s+");
				org.lwjgl.glfw.GLFW.glfwSetWindowPos(mc.getWindow().handle(), Integer.parseInt(xy[0]), Integer.parseInt(xy[1]));
				return "ok";
			});
			case "pack" -> onRenderThread(() -> setPack(arg));
			case "shaders" -> onRenderThread(() -> setShaders(arg.equals("on")));
			default -> CompletableFuture.completedFuture("err unknown command: " + verb);
		};
	}

	private static CompletableFuture<String> gpuProfileCommand(String arg) {
		if (arg.equals("stop")) return onRenderThread(GpuPassProfiler::stop);
		if (arg.equals("status")) return onRenderThread(GpuPassProfiler::status);
		if (!arg.startsWith("start ") || arg.substring(6).isBlank())
			return CompletableFuture.completedFuture("err usage: gpuprof start <new-name.csv>|stop|status");
		try {
			GpuPassProfiler.Session candidate = GpuPassProfiler.prepare(arg.substring(6).strip());
			return onRenderThread(() -> GpuPassProfiler.start(candidate));
		} catch (IOException | RuntimeException e) {
			return CompletableFuture.completedFuture("err " + e);
		}
	}

	private static CompletableFuture<String> onRenderThread(java.util.function.Supplier<String> task) {
		CompletableFuture<String> f = new CompletableFuture<>();
		Minecraft.getInstance().execute(() -> {
			try {
				f.complete(task.get());
			} catch (Throwable t) {
				f.complete("err " + t);
			}
		});
		return f;
	}

	private CompletableFuture<String> waitTicks(int ticks) {
		CompletableFuture<String> f = new CompletableFuture<>();
		Minecraft.getInstance().execute(() -> waiters.add(new Waiter(() -> false, tick + ticks, f, "ok")));
		return f;
	}

	private CompletableFuture<String> waitUntil(BooleanSupplier cond, int timeoutTicks, String onTimeout) {
		CompletableFuture<String> f = new CompletableFuture<>();
		Minecraft.getInstance().execute(() -> waiters.add(new Waiter(cond, tick + timeoutTicks, f, onTimeout)));
		return f;
	}

	private static CompletableFuture<String> screenshot(Minecraft mc, Path target) {
		CompletableFuture<String> f = new CompletableFuture<>();
		mc.execute(() -> {
			try {
				Screenshot.takeScreenshot(mc.gameRenderer.mainRenderTarget(), (NativeImage image) -> {
					try (image) {
						Files.createDirectories(target.toAbsolutePath().getParent());
						image.writeToFile(target);
						f.complete("ok " + target.toAbsolutePath());
					} catch (IOException e) {
						f.complete("err " + e);
					}
				});
			} catch (Throwable t) {
				f.complete("err " + t);
			}
		});
		return f;
	}

	private static String setShaders(boolean enabled) {
		try {
			Class<?> api = Class.forName("net.irisshaders.iris.api.v0.IrisApi");
			Object instance = api.getMethod("getInstance").invoke(null);
			Object config = api.getMethod("getConfig").invoke(instance);
			config.getClass().getMethod("setShadersEnabledAndApply", boolean.class).invoke(config, enabled);
			return "ok";
		} catch (ReflectiveOperationException e) {
			Throwable cause = e.getCause() != null ? e.getCause() : e;
			return "err " + cause;
		}
	}

	/** Switches the active shader pack by folder or zip name (for side-by-side comparisons with reference packs). */
	private static String setPack(String name) {
		try {
			Class<?> iris = Class.forName("net.irisshaders.iris.Iris");
			Object config = iris.getMethod("getIrisConfig").invoke(null);
			config.getClass().getMethod("setShaderPackName", String.class).invoke(config, name);
			// Iris re-reads its config file on reload, so persist the new selection first.
			config.getClass().getMethod("save").invoke(config);
			iris.getMethod("reload").invoke(null);
			return "ok";
		} catch (ReflectiveOperationException e) {
			Throwable cause = e.getCause() != null ? e.getCause() : e;
			return "err " + cause;
		}
	}

	private static String reloadIris() {
		try {
			Class<?> iris = Class.forName("net.irisshaders.iris.Iris");
			iris.getMethod("reload").invoke(null);
			return "ok";
		} catch (ReflectiveOperationException e) {
			Throwable cause = e.getCause() != null ? e.getCause() : e;
			return "err " + cause;
		}
	}
}
