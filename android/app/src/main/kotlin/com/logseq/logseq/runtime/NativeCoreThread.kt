package com.logseq.logseq.runtime

import android.os.Process
import android.os.Trace
import java.util.concurrent.PriorityBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher

/**
 * The one thread that calls into liblogseq_core.
 *
 * Every core entry point (LUI events, effect drain, host updates, RPC) runs
 * here, so the main thread only applies the resulting patches. Interaction
 * can pass queued maintenance work, with FIFO ordering within each priority.
 */
internal object NativeCoreThread {
    private class Work(val maintenance: Boolean, val order: Long, private val task: Runnable) : Runnable {
        override fun run() = task.run()
    }

    private val order = AtomicLong()
    private val queue = PriorityBlockingQueue<Runnable>(11,
        compareBy<Runnable> { (it as Work).maintenance }.thenBy { (it as Work).order })
    private val executor = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, queue) { task ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY)
            task.run()
        }, "logseq-core")
    }

    private fun dispatcher(maintenance: Boolean): CoroutineDispatcher = object : CoroutineDispatcher() {
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            executor.execute(Work(maintenance, order.getAndIncrement(), block))
        }
    }

    val dispatcher = dispatcher(maintenance = false)
    val maintenanceDispatcher = dispatcher(maintenance = true)

    fun execute(task: () -> Unit) = executor.execute(Work(false, order.getAndIncrement(), Runnable(task)))
}

internal inline fun <T> traced(name: String, block: () -> T): T {
    Trace.beginSection(name)
    try {
        return block()
    } finally {
        Trace.endSection()
    }
}
