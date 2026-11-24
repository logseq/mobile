package com.logseq.logseq.runtime

import android.os.Process
import android.os.Trace
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher

/**
 * The one thread that calls into liblogseq_core.
 *
 * Every core entry point (LUI events, effect drain, host updates, RPC) runs
 * here, so the main thread only applies the resulting patches. One thread
 * also keeps the core's calls in a single FIFO order.
 */
internal object NativeCoreThread {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
            task.run()
        }, "logseq-core")
    }

    val dispatcher = executor.asCoroutineDispatcher()

    fun execute(task: () -> Unit) = executor.execute(task)
}

internal inline fun <T> traced(name: String, block: () -> T): T {
    Trace.beginSection(name)
    try {
        return block()
    } finally {
        Trace.endSection()
    }
}
