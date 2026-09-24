package dev.claudebench.benchcam;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.LinkOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayDeque;
import java.util.Locale;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GL11C;
import org.lwjgl.opengl.GL15C;
import org.lwjgl.opengl.GL33C;

/** Render-thread-only GL timer queries for Iris composite passes; disk output is off-thread. */
public final class GpuPassProfiler {
	private static final int MAX_QUERIES = 512;
	private static final int POLL_AFTER_FRAMES = 4;
	private static final String OUTPUT_DIR = "BenchCamGpuProfiles";
	private static final ArrayDeque<Integer> FREE = new ArrayDeque<>();
	private static final ArrayDeque<Pending> PENDING = new ArrayDeque<>();
	private static int allocatedQueries;
	private static long frame;
	private static int compositeDepth;
	private static String compositeStage;
	private static long compositeToken;
	private static int activeQuery;
	private static long activeToken;
	private static long nextToken;
	private static String activeStage;
	private static String activePass;
	private static Session session;
	private static boolean recording;
	private static long submitted;
	private static long received;
	private static long droppedQueries;
	private static long droppedRows;
	private static String captureFailure;
	private static boolean pollingBroken;
	private static boolean restartRequired;
	private static long unreleasedQueries;

	private record Pending(int query, long frame, String stage, String pass) {}

	private GpuPassProfiler() {}

	/** Accepts a basename only; file creation happens on the socket thread. */
	public static Session prepare(String filename) throws IOException {
		if (!filename.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,123}\\.csv"))
			throw new IOException("output must be a new CSV basename without a directory path");
		Path home = Path.of(System.getProperty("user.home")).toAbsolutePath().normalize();
		Path root = home.resolve(OUTPUT_DIR);
		if (root.toString().startsWith("\\\\")) throw new IOException("UNC capture roots are not allowed");
		// Reject a reparse-point escape in the home directory or an existing output root.
		for (Path candidate = home; candidate != null; candidate = candidate.getParent()) {
			if (Files.exists(candidate, LinkOption.NOFOLLOW_LINKS)
					&& !candidate.toRealPath(LinkOption.NOFOLLOW_LINKS).equals(candidate.toRealPath()))
				throw new IOException("capture root passes through a link or junction: " + candidate);
		}
		if (Files.exists(root, LinkOption.NOFOLLOW_LINKS)) {
			if (!root.toRealPath(LinkOption.NOFOLLOW_LINKS).equals(root.toRealPath()))
				throw new IOException("capture root is a link or junction");
		} else Files.createDirectory(root);
		Path absolute = root.resolve(filename).normalize();
		if (!absolute.getParent().equals(root)) throw new IOException("output path escaped capture root");
		BufferedWriter out = Files.newBufferedWriter(absolute, StandardCharsets.UTF_8,
			StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
		out.write("frame,stage,pass,gpu_ns");
		out.newLine();
		out.flush();
		return new Session(absolute, out);
	}

	public static String start(Session candidate) {
		if (restartRequired) {
			candidate.discard();
			return "err GPU query cleanup failed; restart the client before another capture";
		}
		if (recording || (session != null && !session.closed) || !PENDING.isEmpty() || activeQuery != 0 || compositeDepth != 0) {
			candidate.discard();
			return "err profiler already active or draining";
		}
		final int initialGlError;
		try {
			if (!GL.getCapabilities().OpenGL33) {
				candidate.discard();
				return "err OpenGL 3.3 timer queries unavailable";
			}
			initialGlError = GL11C.glGetError();
		} catch (RuntimeException e) {
			candidate.discard();
			return "err OpenGL context unavailable: " + e;
		}
		if (initialGlError != GL11C.GL_NO_ERROR) {
			candidate.discard();
			return String.format(Locale.ROOT, "err preexisting GL error 0x%04x", initialGlError);
		}
		session = candidate;
		recording = true;
		submitted = received = droppedQueries = droppedRows = 0;
		captureFailure = null;
		pollingBroken = false;
		candidate.startWriter();
		return "ok profiling output=" + candidate.path;
	}

	public static String stop() {
		if (!recording) return "err profiler not recording";
		recording = false;
		if (PENDING.isEmpty() && activeQuery == 0) {
			retireFreeQueries();
			session.closeWhenEmpty();
		}
		return "ok draining pending=" + PENDING.size() + " output=" + session.path;
	}

	public static String status() {
		String state = session == null ? "idle" : recording ? "recording" : session.closed ? "closed" : "draining";
		String error = session == null || session.error.get() == null ? "none" : session.error.get().replace(' ', '_');
		String failure = captureFailure == null ? "none" : captureFailure;
		return String.format(Locale.ROOT,
			"ok state=%s submitted=%d received=%d written=%d dropped_queries=%d dropped_rows=%d pending=%d failed_reason=%s restart_required=%s unreleased_queries=%d writer_error=%s output=%s",
			state, submitted, received, session == null ? 0 : session.written.get(), droppedQueries,
			droppedRows + (session == null ? 0 : session.abandonedRows.get()),
			PENDING.size(), failure, restartRequired, unreleasedQueries, error, session == null ? "none" : session.path);
	}

	public static void pushCompositeGroup(String name) {
		if (++compositeDepth == 1) compositeStage = name;
		else if (compositeDepth == 2) compositeToken = begin(compositeStage, name);
	}

	public static void popCompositeGroup() {
		if (compositeDepth == 2) {
			end(compositeToken);
			compositeToken = 0;
		}
		if (compositeDepth > 0) compositeDepth--;
		if (compositeDepth == 0) compositeStage = null;
	}

	/** Called by the method wrapper on both normal and exceptional exits. */
	public static void finishCompositeMethod(boolean completed) {
		if (completed && compositeDepth == 0 && compositeToken == 0) return;
		abort(compositeToken, completed ? "unbalanced_composite_group" : "composite_render_exception");
		compositeToken = 0;
		compositeDepth = 0;
		compositeStage = null;
	}

	public static long begin(String stage, String pass) {
		if (!recording) return 0;
		if (activeQuery != 0) {
			fail("overlapping_timer_query");
			return 0;
		}
		int current = currentElapsedQuery("before_begin_query");
		if (current < 0 || !recording) return 0;
		if (current != 0) {
			fail("foreign_timer_query_active");
			return 0;
		}
		int query;
		if (!FREE.isEmpty()) query = FREE.removeFirst();
		else if (allocatedQueries < MAX_QUERIES) {
			try { query = GL15C.glGenQueries(); }
			catch (RuntimeException e) {
				fail("gen_query_exception");
				BenchCam.LOG.error("Could not create GPU timer query", e);
				return 0;
			}
			allocatedQueries++;
			if (!glOkay("gen_query") || query == 0) {
				if (query != 0) deleteQuery(query);
				else {
					allocatedQueries--;
					fail("zero_query_id");
				}
				return 0;
			}
		} else {
			droppedQueries++;
			return 0;
		}
		if (!glOkay("before_begin_query")) {
			deleteQuery(query);
			return 0;
		}
		try {
			GL15C.glBeginQuery(GL33C.GL_TIME_ELAPSED, query);
		} catch (RuntimeException e) {
			deleteQuery(query);
			fail("begin_query_exception");
			return 0;
		}
		activeQuery = query;
		activeToken = ++nextToken;
		activeStage = stage;
		activePass = pass;
		return activeToken;
	}

	public static void end(long token) {
		if (token == 0) return;
		if (activeQuery == 0 || activeToken != token) {
			fail("timer_token_mismatch");
			return;
		}
		if (currentElapsedQuery("before_end_query") != activeQuery) {
			fail("timer_query_ownership_lost");
			deleteQuery(activeQuery);
			activeQuery = 0;
			activeToken = 0;
			activeStage = activePass = null;
			return;
		}
		try { GL15C.glEndQuery(GL33C.GL_TIME_ELAPSED); }
		catch (RuntimeException e) {
			fail("end_query_exception");
			BenchCam.LOG.error("Could not end GPU timer query", e);
			deleteQuery(activeQuery);
			activeQuery = 0;
			activeToken = 0;
			activeStage = activePass = null;
			return;
		}
		// Check after End, never while the timer interval is active. This also catches Begin errors.
		if (!glOkay("timer_interval")) {
			deleteQuery(activeQuery);
			activeQuery = 0;
			activeToken = 0;
			activeStage = activePass = null;
			return;
		}
		PENDING.addLast(new Pending(activeQuery, frame, activeStage, activePass));
		submitted++;
		activeQuery = 0;
		activeToken = 0;
		activeStage = activePass = null;
		if (!recording && PENDING.isEmpty()) session.closeWhenEmpty();
	}

	/** Ends only the query owned by this pass; a missing begin cannot close another pass. */
	public static void abort(long token, String reason) {
		if (token != 0 && activeQuery != 0 && activeToken == token) abortActiveQuery();
		fail(reason);
	}

	private static void abortActiveQuery() {
		try {
			if (currentElapsedQuery("before_abort_query") == activeQuery) {
				GL15C.glEndQuery(GL33C.GL_TIME_ELAPSED);
				glOkay("abort_end_query");
			} else fail("timer_query_ownership_lost");
			deleteQuery(activeQuery);
		} catch (RuntimeException e) {
			BenchCam.LOG.error("Could not end aborted GPU timer query", e);
			fail("abort_query_exception");
			deleteQuery(activeQuery);
		}
		activeQuery = 0;
		activeToken = 0;
		activeStage = activePass = null;
	}

	private static void fail(String reason) {
		if (session == null || (!recording && session.closed)) return;
		if (captureFailure == null) captureFailure = reason;
		recording = false;
		session.closeWhenEmpty();
	}

	private static boolean glOkay(String operation) {
		try {
			int error = GL11C.glGetError();
			if (error == GL11C.GL_NO_ERROR) return true;
			fail(String.format(Locale.ROOT, "gl_%s_0x%04x", operation, error));
			return false;
		} catch (RuntimeException e) {
			fail("gl_" + operation + "_exception");
			BenchCam.LOG.error("GPU profiler GL error check failed", e);
			return false;
		}
	}

	private static int currentElapsedQuery(String operation) {
		try {
			int query = GL15C.glGetQueryi(GL33C.GL_TIME_ELAPSED, GL15C.GL_CURRENT_QUERY);
			// Keep the ownership value even when a prior GL error invalidates the capture.
			// A matching query can still be ended safely to restore GL state.
			glOkay(operation);
			return query;
		} catch (RuntimeException e) {
			fail(operation + "_exception");
			BenchCam.LOG.error("Could not inspect current GPU timer query", e);
			return -1;
		}
	}

	private static void deleteQuery(int query) {
		if (restartRequired) {
			unreleasedQueries++;
			return;
		}
		boolean deleted = false;
		try {
			GL15C.glDeleteQueries(query);
			deleted = glOkay("delete_query");
		} catch (RuntimeException e) {
			fail("delete_query_exception");
			BenchCam.LOG.error("Could not delete GPU timer query", e);
		}
		if (deleted) allocatedQueries--;
		else {
			restartRequired = true;
			unreleasedQueries++;
		}
	}

	private static void retireFreeQueries() {
		while (!FREE.isEmpty()) deleteQuery(FREE.removeFirst());
	}

	/** Polls only old, available results; never calls GL_QUERY_RESULT on an unavailable query. */
	public static void poll() {
		frame++;
		if (pollingBroken) return;
		if (captureFailure != null) {
			cleanupAfterPollFailure();
			return;
		}
		try {
			pollResults();
			if (captureFailure != null || restartRequired) cleanupAfterPollFailure();
		} catch (RuntimeException e) {
			fail("query_poll_exception");
			BenchCam.LOG.error("GPU timer query polling failed", e);
			cleanupAfterPollFailure();
		}
	}

	/** Delete ended queries without waiting for their results. Failure requires a new GL context. */
	private static void cleanupAfterPollFailure() {
		if (activeQuery != 0) abortActiveQuery();
		while (!PENDING.isEmpty()) deleteQuery(PENDING.removeFirst().query);
		retireFreeQueries();
		compositeDepth = 0;
		compositeToken = 0;
		compositeStage = null;
		if (session != null) session.closeWhenEmpty();
		// A failed capture has no results left to poll. A later successful start resets this flag.
		pollingBroken = true;
	}

	private static void pollResults() {
		if (compositeDepth != 0) finishCompositeMethod(true);
		if (activeQuery != 0) {
			abortActiveQuery();
			fail("query_left_open_at_frame_end");
		}
		while (!PENDING.isEmpty()) {
			if (captureFailure != null || restartRequired) return;
			Pending sample = PENDING.peekFirst();
			if (frame - sample.frame < POLL_AFTER_FRAMES) break;
			int available = GL15C.glGetQueryObjecti(sample.query, GL15C.GL_QUERY_RESULT_AVAILABLE);
			if (!glOkay("query_available")) {
				PENDING.removeFirst();
				deleteQuery(sample.query);
				continue;
			}
			if (available == 0) break;
			long nanos = GL33C.glGetQueryObjecti64(sample.query, GL15C.GL_QUERY_RESULT);
			PENDING.removeFirst();
			if (!glOkay("query_result")) {
				deleteQuery(sample.query);
				continue;
			}
			FREE.addLast(sample.query);
			received++;
			if (captureFailure == null && !session.offer(sample.frame + "," + csv(sample.stage) + "," + csv(sample.pass) + "," + nanos)) droppedRows++;
		}
		if (!recording && session != null && PENDING.isEmpty() && activeQuery == 0) {
			retireFreeQueries();
			session.closeWhenEmpty();
		}
	}

	private static String csv(String value) {
		return "\"" + value.replace("\"", "\"\"") + "\"";
	}

	public static final class Session {
		private final Path path;
		private final BufferedWriter out;
		private final ArrayBlockingQueue<String> rows = new ArrayBlockingQueue<>(8192);
		private final AtomicLong written = new AtomicLong();
		private final AtomicLong abandonedRows = new AtomicLong();
		private final AtomicReference<String> error = new AtomicReference<>();
		private volatile boolean closing;
		private volatile boolean closed;
		private volatile boolean writerStarted;

		private Session(Path path, BufferedWriter out) { this.path = path; this.out = out; }

		private void startWriter() {
			writerStarted = true;
			Thread writer = new Thread(() -> {
				String inFlight = null;
				try (out) {
					while (!closing || !rows.isEmpty()) {
						inFlight = rows.poll(1, TimeUnit.SECONDS);
						if (inFlight != null) {
							out.write(inFlight);
							out.newLine();
							inFlight = null;
							if ((written.incrementAndGet() & 63) == 0) out.flush();
						} else out.flush();
					}
				} catch (Exception e) {
					error.set(e.toString());
					synchronized (this) {
						closed = true;
						abandonedRows.addAndGet(rows.size() + (inFlight == null ? 0 : 1));
						rows.clear();
					}
				}
				finally { closed = true; }
			}, "BenchCam-GpuProfiler-Writer");
			writer.setDaemon(true);
			writer.start();
		}

		private synchronized boolean offer(String row) { return !closed && rows.offer(row); }

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
