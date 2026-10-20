package com.logseq.app.runtime

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidGraphEventsSyncTest {
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
