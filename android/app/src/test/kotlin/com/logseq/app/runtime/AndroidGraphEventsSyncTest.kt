package com.logseq.app.runtime

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidGraphEventsSyncTest {
    @Test
    fun `foreground transport waits for paused session cleanup before reconnecting`(): Unit = runBlocking {
        withTimeout(2_000) {
            val events = mutableListOf<String>()
            val session = AndroidForegroundSyncSession(this)
            val connected = CompletableDeferred<Unit>()
            val closing = CompletableDeferred<Unit>()
            val releaseCleanup = CompletableDeferred<Unit>()
            try {
                session.update("graph", foreground = false) { events += "background connection" }
                yield()
                assertEquals(emptyList<String>(), events)

                session.update("graph", foreground = true) {
                    try {
                        events += "connected"
                        connected.complete(Unit)
                        awaitCancellation()
                    } finally {
                        withContext(NonCancellable) {
                            events += "closing"
                            closing.complete(Unit)
                            releaseCleanup.await()
                            events += "closed"
                        }
                    }
                }
                connected.await()
                session.update("graph", foreground = true) { events += "duplicate connection" }
                yield()
                assertEquals(listOf("connected"), events)

                session.update("graph", foreground = false) { events += "background connection" }
                closing.await()
                session.update("graph", foreground = true) { events += "superseded connection" }
                yield()
                session.update("graph", foreground = false) { events += "background connection" }
                session.update("graph", foreground = true) { events += "reconnected" }
                yield()
                assertEquals(listOf("connected", "closing"), events)

                releaseCleanup.complete(Unit)
                session.join()
                assertEquals(listOf("connected", "closing", "closed", "reconnected"), events)
            } finally {
                releaseCleanup.complete(Unit)
                session.cancel()
            }
        }
    }

    @Test
    fun `core retry command defers snapshot even without a local cursor`() = runBlocking {
        val actions = mutableListOf<String>()
        val sync = AndroidGraphEventsSync(
            callCore = { request ->
                actions += JSONObject(request).getJSONObject("params").getString("action")
                """{"ok":true,"result":{"syncTransport":{"generation":7,"graphId":"plain-1","snapshotRequired":true,"commands":[{"type":"retry","delayMs":2300}]}}}"""
            },
            applyResponse = {}, onChangesApplied = {},
            isCancelled = { false },
        )
        val outcome = sync.runSession(AndroidGraphEventsSync.Connection("plain-1", "http://localhost", "token"))
        assertEquals(listOf("beginSyncTransport"), actions)
        assertEquals(AndroidGraphEventsSync.SessionOutcome.Retry(2300L, null), outcome)
    }
}
