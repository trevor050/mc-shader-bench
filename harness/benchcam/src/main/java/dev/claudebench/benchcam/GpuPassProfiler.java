package dev.claudebench.benchcam;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayDeque;
import java.util.Locale;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GL15C;
import org.lwjgl.opengl.GL33C;

/** Render-thread-only GL timer queries for Iris composite passes; disk output is off-thread. */
public final class GpuPassProfiler {
	private static final int MAX_QUERIES = 512;
	private static final int POLL_AFTER_FRAMES = 4;
	private static final ArrayDeque<Integer> FREE = new ArrayDeque<>();
	private static final ArrayDeque<Pending> PENDING = new ArrayDeque<>();
	private static int allocatedQueries;
	private static long frame;
	private static int compositeDepth;
	private static String compositeStage;
	private static int activeQuery;
	private static String activeStage;
	private static String activePass;
	private static Session session;
	private static boolean recording;
	private static long submitted;
	private static long received;
	private static long droppedQueries;
	private static long droppedRows;

	private record Pending(int query, long frame, String stage, String pass) {}

	private GpuPassProfiler() {}

	/** File creation happens on the BenchCam socket thread, before any render-thread state changes. */
	public static Session prepare(Path path) throws IOException {
		Path absolute = path.toAbsolutePath().normalize();
		if (absolute.getParent() != null) Files.createDirectories(absolute.getParent());
		BufferedWriter out = Files.newBufferedWriter(absolute, StandardCharsets.UTF_8,
			StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
		out.write("frame,stage,pass,gpu_ns");
		out.newLine();
		out.flush();
		return new Session(absolute, out);
	}

	public static String start(Session candidate) {
		if (recording || (session != null && !session.closed)) {
			candidate.discard();
			return "err profiler already active or draining";
		}
		if (!GL.getCapabilities().OpenGL33) {
			candidate.discard();
			return "err OpenGL 3.3 timer queries unavailable";
		}
		session = candidate;
		recording = true;
		submitted = received = droppedQueries = droppedRows = 0;
		candidate.startWriter();
		return "ok profiling output=" + candidate.path;
	}

	public static String stop() {
		if (!recording) return "err profiler not recording";
		recording = false;
		if (PENDING.isEmpty() && activeQuery == 0) session.closeWhenEmpty();
		return "ok draining pending=" + PENDING.size() + " output=" + session.path;
	}

	public static String status() {
		String state = session == null ? "idle" : recording ? "recording" : session.closed ? "closed" : "draining";
		String error = session == null || session.error.get() == null ? "none" : session.error.get().replace(' ', '_');
		return String.format(Locale.ROOT,
			"ok state=%s submitted=%d received=%d written=%d dropped_queries=%d dropped_rows=%d pending=%d writer_error=%s output=%s",
			state, submitted, received, session == null ? 0 : session.written.get(), droppedQueries, droppedRows,
			PENDING.size(), error, session == null ? "none" : session.path);
	}

	public static void pushCompositeGroup(String name) {
		if (++compositeDepth == 1) compositeStage = name;
		else if (compositeDepth == 2) begin(compositeStage, name);
	}

	public static void popCompositeGroup() {
		if (compositeDepth == 2) end();
		if (compositeDepth > 0) compositeDepth--;
		if (compositeDepth == 0) compositeStage = null;
	}

	public static void begin(String stage, String pass) {
		if (!recording || activeQuery != 0) return;
		int query;
		if (!FREE.isEmpty()) query = FREE.removeFirst();
		else if (allocatedQueries < MAX_QUERIES) {
			query = GL15C.glGenQueries();
			allocatedQueries++;
		} else {
			droppedQueries++;
			return;
		}
		GL15C.glBeginQuery(GL33C.GL_TIME_ELAPSED, query);
		activeQuery = query;
		activeStage = stage;
		activePass = pass;
	}

	public static void end() {
		if (activeQuery == 0) return;
		GL15C.glEndQuery(GL33C.GL_TIME_ELAPSED);
		PENDING.addLast(new Pending(activeQuery, frame, activeStage, activePass));
		submitted++;
		activeQuery = 0;
		activeStage = activePass = null;
		if (!recording && PENDING.isEmpty()) session.closeWhenEmpty();
	}

	/** Polls only old, available results; never calls GL_QUERY_RESULT on an unavailable query. */
	public static void poll() {
		frame++;
		while (!PENDING.isEmpty()) {
			Pending sample = PENDING.peekFirst();
			if (frame - sample.frame < POLL_AFTER_FRAMES) break;
			if (GL15C.glGetQueryObjecti(sample.query, GL15C.GL_QUERY_RESULT_AVAILABLE) == 0) break;
			long nanos = GL33C.glGetQueryObjecti64(sample.query, GL15C.GL_QUERY_RESULT);
			PENDING.removeFirst();
			FREE.addLast(sample.query);
			received++;
			if (!session.offer(sample.frame + "," + csv(sample.stage) + "," + csv(sample.pass) + "," + nanos)) droppedRows++;
		}
		if (!recording && session != null && PENDING.isEmpty() && activeQuery == 0) session.closeWhenEmpty();
	}

	private static String csv(String value) {
		return "\"" + value.replace("\"", "\"\"") + "\"";
	}

	public static final class Session {
		private final Path path;
		private final BufferedWriter out;
		private final ArrayBlockingQueue<String> rows = new ArrayBlockingQueue<>(8192);
		private final AtomicLong written = new AtomicLong();
		private final AtomicReference<String> error = new AtomicReference<>();
		private volatile boolean closing;
		private volatile boolean closed;
		private volatile boolean writerStarted;

		private Session(Path path, BufferedWriter out) { this.path = path; this.out = out; }

		private void startWriter() {
			writerStarted = true;
			Thread writer = new Thread(() -> {
				try (out) {
					while (!closing || !rows.isEmpty()) {
						String row = rows.poll(1, TimeUnit.SECONDS);
						if (row != null) {
							out.write(row);
							out.newLine();
							if ((written.incrementAndGet() & 63) == 0) out.flush();
						} else out.flush();
					}
				} catch (Exception e) { error.set(e.toString()); }
				finally { closed = true; }
			}, "BenchCam-GpuProfiler-Writer");
			writer.setDaemon(true);
			writer.start();
		}

		private boolean offer(String row) { return !closed && rows.offer(row); }

		private void closeWhenEmpty() {
			closing = true;
			if (!writerStarted) {
				try { out.close(); } catch (IOException e) { error.set(e.toString()); }
				closed = true;
			}
		}

		private void discard() {
			closeWhenEmpty();
			try { Files.deleteIfExists(path); } catch (IOException e) { error.set(e.toString()); }
		}
	}
}
