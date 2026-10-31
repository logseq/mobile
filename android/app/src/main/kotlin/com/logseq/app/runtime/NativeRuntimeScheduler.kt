package com.logseq.app.runtime

import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

// Kotlin port of the former native_runtime_scheduler.dart.
//
// Core-bound work (async effect execution, RPC) serializes on `runCore`;
// UI-facing native calls (LUI event dispatches) go through `runUi` and
// are deferred while the core is busy so a patch produced mid-flight can
// never interleave with the runCore call the UI was racing.
internal class NativeRuntimeScheduler {
    var onIdle: (() -> Unit)? = null

    private val deferredUiCalls = ArrayDeque<() -> Unit>()
    private val coreMutex = Mutex()
    private val pendingCoreCalls = AtomicInteger(0)

    val isCoreBusy: Boolean get() = pendingCoreCalls.get() > 0

    suspend fun <T> runCore(operation: suspend () -> T): T {
        pendingCoreCalls.incrementAndGet()
        try {
            return coreMutex.withLock { operation() }
        } finally {
            if (pendingCoreCalls.decrementAndGet() == 0) {
                flushUiCalls()
                onIdle?.invoke()
            }
        }
    }

    fun runUi(operation: () -> Unit) {
        if (isCoreBusy) {
            deferredUiCalls.addLast(operation)
            return
        }
        operation()
    }

    private fun flushUiCalls() {
        while (deferredUiCalls.isNotEmpty()) {
            deferredUiCalls.removeFirst()()
        }
    }
}
