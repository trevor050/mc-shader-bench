package dev.afterglow.clientfixes;

import java.util.Locale;

/** Standalone regression check for the release's deliberately narrow pack scope. */
public final class QueuePolicyTest {
    public static void main(String[] args) {
        String[] accepted = {
            "ClaudeBenchRCMenuV2", "AfterglowGUIProbe", "AfterglowGUIStress",
            "Afterglow-preview-2026-09-26.zip", "Afterglow-preview-2026-09-26",
            "Afterglow-preview-2026-09-26.2.zip", "Afterglow-preview-2026-09-26.2"
        };
        for (String name : accepted) {
            require(QueuePolicy.matchesPack(name), "rejects supported name: " + name);
            require(QueuePolicy.matchesPack(name.toUpperCase(Locale.ROOT)), "case-sensitive name: " + name);
        }
        String[] rejected = {
            null, "", "Afterglow Lite", "Afterglow", "ClaudeBench", "ClaudeBenchmark",
            "AfterglowGUIProbe.zip", "AfterglowGUIStress-custom", "ClaudeBenchRCMenuV2.zip",
            "Afterglow-preview-2026-09-26.3.zip", "Afterglow-preview-2026-09-26.zip.bak",
            "Afterglow-preview-2026-09-26.2.zip-custom", " Afterglow-preview-2026-09-26.zip",
            "Afterglow-preview-2026-09-26.zip ", "Other-Afterglow-preview-2026-09-26.zip",
            "folder/Afterglow-preview-2026-09-26.zip", "OtherPack.zip"
        };
        for (String name : rejected) require(!QueuePolicy.matchesPack(name), "accepts unsupported name: " + name);
        require(QueuePolicy.boundedWaitMillis(Integer.MIN_VALUE) == 1, "lower timeout bound");
        require(QueuePolicy.boundedWaitMillis(Integer.MAX_VALUE) == 100, "upper timeout bound");
        require(QueuePolicy.boundedWaitMillis(30) == 30, "default timeout budget");
        require(QueuePolicy.submittedFrameIndex(3) == 2, "initial submitted fence");
        require(QueuePolicy.submittedFrameIndex(1_000) == 999, "later submitted fence");
        System.out.println("PASS: 14 supported/case checks, 17 rejected identity checks, timeout bounds and submitted-fence indices.");
    }

    private static void require(boolean condition, String failure) {
        if (!condition) throw new AssertionError(failure);
    }
}
