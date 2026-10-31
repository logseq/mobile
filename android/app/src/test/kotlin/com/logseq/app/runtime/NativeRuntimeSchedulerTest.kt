package com.logseq.app.runtime

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class NativeRuntimeSchedulerTest {
    @Test fun cancelledQueuedCallDoesNotStrandUiWork() = runBlocking {
        val scheduler = NativeRuntimeScheduler()
        val release = CompletableDeferred<Unit>()
        val active = launch(start = CoroutineStart.UNDISPATCHED) {
            scheduler.runCore { release.await() }
        }
        val cancelled = launch(start = CoroutineStart.UNDISPATCHED) {
            scheduler.runCore { error("Cancelled work must not execute") }
        }
        val delivered = mutableListOf<String>()
        scheduler.runUi { delivered.add("deferred") }
        cancelled.cancelAndJoin()
        release.complete(Unit)
        active.join()

        assertFalse(scheduler.isCoreBusy)
        scheduler.runCore { delivered.add("next core") }
        scheduler.runUi { delivered.add("next ui") }
        assertEquals(listOf("deferred", "next core", "next ui"), delivered)
    }
}
