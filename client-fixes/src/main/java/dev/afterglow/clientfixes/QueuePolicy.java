package dev.afterglow.clientfixes;

import java.util.Locale;
import java.util.Set;

/** Pure policy shared by the runtime guard and offline verification. */
public final class QueuePolicy {
    private static final Set<String> SUPPORTED_PACK_NAMES = Set.of(
        "claudebenchrcmenuv2",
        "afterglowguiprobe",
        "afterglowguistress",
        "afterglow-preview-2026-09-26",
        "afterglow-preview-2026-09-26.zip",
        "afterglow-preview-2026-09-26.2",
        "afterglow-preview-2026-09-26.2.zip"
    );

    private QueuePolicy() { }

    public static boolean matchesPack(String name) {
        if (name == null) return false;
        return SUPPORTED_PACK_NAMES.contains(name.toLowerCase(Locale.ROOT));
    }

    public static int boundedWaitMillis(int requested) {
        return Math.clamp(requested, 1, 100);
    }

    public static long submittedFrameIndex(long nextSubmitIndex) {
        return nextSubmitIndex - 1L;
    }
}
