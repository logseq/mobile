package com.logseq.logseq.runtime

import android.app.Activity
import android.os.Process
import android.os.SystemClock
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Cold-launch timing parity with the iOS `LOGSEQ_LAUNCH_METRIC` lines
 * emitted by `LogseqAppDelegate`. Elapsed values are anchored at the
 * real process start (`Process.getStartElapsedRealtime`, elapsedRealtime
 * clock) so they compare against `am start -W` TotalTime.
 *
 * Each stage is reported exactly once per process via [report]; later
 * occurrences are ignored.
 */
internal object AndroidLaunchMetrics {
    private val startedAtMs = Process.getStartElapsedRealtime()
    private val reported = ConcurrentHashMap.newKeySet<String>()

    /** Set by MainActivity so `journals_ui_ready` can call reportFullyDrawn. */
    var activity: Activity? = null

    fun report(name: String) {
        if (reported.add(name)) {
            val elapsed = SystemClock.elapsedRealtime() - startedAtMs
            println(
                String.format(
                    Locale.US,
                    "LOGSEQ_LAUNCH_METRIC %s_ms=%.3f",
                    name,
                    elapsed.toDouble(),
                ),
            )
            if (name == "journals_ui_ready") {
                activity?.reportFullyDrawn()
            }
        }
    }
}
