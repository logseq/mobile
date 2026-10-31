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
    @Test fun deferredUiWaitsForCoreStartedByEarlierUiWork() = runBlocking {
        val scheduler = NativeRuntimeScheduler()
        val firstRelease = CompletableDeferred<Unit>()
        val secondRelease = CompletableDeferred<Unit>()
        val delivered = mutableListOf<String>()
        var idle = 0
        scheduler.onIdle = { idle++ }
        var second: kotlinx.coroutines.Job? = null
        val first = launch(start = CoroutineStart.UNDISPATCHED) {
            scheduler.runCore { delivered.add("first core"); firstRelease.await() }
        }
        scheduler.runUi {
            delivered.add("first ui")
            second = launch(start = CoroutineStart.UNDISPATCHED) {
                scheduler.runCore { delivered.add("second core"); secondRelease.await() }
            }
        }
        scheduler.runUi { delivered.add("second ui") }
        firstRelease.complete(Unit)
        first.join()
        assertEquals(listOf("first core", "first ui", "second core"), delivered)
        assertEquals(0, idle)
        secondRelease.complete(Unit)
        second!!.join()
        assertEquals(listOf("first core", "first ui", "second core", "second ui"), delivered)
        assertEquals(1, idle)
    }

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
